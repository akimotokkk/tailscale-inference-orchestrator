<#
  ts-derp.ps1  v5
  Tailscale 直连 / DERP 中继 手动切换（含注册表自愈）

  用法:
    .\ts-derp.ps1 -Mode status     只读查看，不改动任何东西
    .\ts-derp.ps1 -Mode fix        只修复注册表，不重启服务
    .\ts-derp.ps1 -Mode on         强制走 DERP 中继
    .\ts-derp.ps1 -Mode off        恢复默认（允许直连）
    .\ts-derp.ps1 -Mode diag       导出全部诊断信息

  可选参数:
    -Peer <节点名>        默认 akimotokyoichi
    -WaitDirectSec <秒>   切回默认后等待直连的秒数；0=不等待；默认 60

  保存编码: UTF-8 with BOM
#>
#requires -version 5.1

param(
    [ValidateSet('status', 'fix', 'on', 'off', 'diag')]
    [string]$Mode = 'status',
    [string]$Peer = 'akimotokyoichi',
    [int]$WaitDirectSec = 60
)

# 关键: 必须是 Continue。
# 原生命令(tailscale/sc/taskkill)往 stderr 写内容时, 2>&1 进管道 + Stop 会抛
# NativeCommandError 终止错误, 导致脚本静默退出、窗口闪退。
$ErrorActionPreference = 'Continue'

$SvcName = 'Tailscale'
$SubKey  = 'SYSTEM\CurrentControlSet\Services\Tailscale'
$RegPath = 'HKLM:\' + $SubKey
$ValName = 'Environment'
$ValData = 'TS_DEBUG_ALWAYS_USE_DERP=true'

# ==================== 注册表读写（用 .NET API，避免 PowerShell 的类型歧义）====================

function Read-EnvRaw {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $false)
    if (-not $k) { return [pscustomobject]@{ Exists = $false; Kind = ''; Items = @() } }
    try {
        if ($k.GetValueNames() -contains $ValName) {
            $v = $k.GetValue($ValName, $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = $k.GetValueKind($ValName).ToString()
            $items = if ($v -is [array]) { @($v) } else { @([string]$v) }
            return [pscustomobject]@{ Exists = $true; Kind = $kind; Items = $items }
        }
        return [pscustomobject]@{ Exists = $false; Kind = ''; Items = @() }
    } finally { $k.Close() }
}

function Get-CleanList {
    # 把注册表内容规范化为干净的 "NAME=value" 列表。
    # 自愈: 把被空白粘连的多份字符串拆开, 去重。
    param($Raw)
    $set = New-Object 'System.Collections.Generic.List[string]'
    foreach ($it in @($Raw.Items)) {
        if ($null -eq $it) { continue }
        foreach ($p in ([string]$it -split '\s+')) {
            if ($p -match '^[^=]+=' -and -not $set.Contains($p)) { $set.Add($p) }
        }
    }
    return , @($set)
}

function Test-EnvCorrupted {
    param($Raw)
    if (-not $Raw.Exists) { return $false }
    if ($Raw.Kind -ne 'MultiString') { return $true }        # 类型不对
    foreach ($it in @($Raw.Items)) {
        if ([string]$it -match '\s') { return $true }        # 含空白 = 粘连
    }
    return $false
}

function Set-EnvList {
    # 空列表 = 整条删除
    param([string[]]$List)
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($SubKey, $true)
    if (-not $k) { throw '无法打开注册表项（需要管理员权限）' }
    try {
        $exists = ($k.GetValueNames() -contains $ValName)
        if ($List -and $List.Count -gt 0) {
            $k.SetValue($ValName, [string[]]$List,
                [Microsoft.Win32.RegistryValueKind]::MultiString)
        } elseif ($exists) {
            $k.DeleteValue($ValName, $false)
        }
    } finally { $k.Close() }
}

# ==================== 服务控制（只信 SCM 报告的 PID）====================

function Get-TsExe {
    $c = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = 'C:\Program Files\Tailscale\tailscale.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Get-SvcInfo {
    $raw = (& sc.exe queryex $SvcName 2>&1 | Out-String)
    $state = 'UNKNOWN'; $swpid = 0
    if ($raw -match '(?m)^\s*STATE\s*:\s*\d+\s+([A-Z_]+)') { $state = $Matches[1] }
    if ($raw -match '(?m)^\s*PID\s*:\s*(\d+)') { $swpid = [int]$Matches[1] }
    [pscustomobject]@{ State = $state; Pid = $swpid; Raw = $raw }
}

function Stop-TsService {
    param([int]$KillAfterSec = 12, [int]$TotalSec = 60)

    $i = Get-SvcInfo
    Write-Host ("  [服务] 初始状态={0}  PID={1}" -f $i.State, $i.Pid)
    if ($i.State -eq 'STOPPED') { Write-Host '  [服务] 已是 STOPPED。'; return $true }

    & sc.exe stop $SvcName 2>&1 | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $killed = $false

    while ($sw.Elapsed.TotalSeconds -lt $TotalSec) {
        $i = Get-SvcInfo

        if ($i.State -eq 'STOPPED') {
            Write-Host ("  [服务] 已 STOPPED，用时 {0:N1} 秒。" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
            return $true
        }

        if (-not $killed -and $sw.Elapsed.TotalSeconds -ge $KillAfterSec) {
            if ($i.Pid -gt 0) {
                Write-Host ("  [服务] 停留 {0}，按 PID 强杀 {1} ..." -f $i.State, $i.Pid) -ForegroundColor Yellow
                $kr = (& taskkill.exe /F /T /PID $i.Pid 2>&1 | Out-String).Trim()
                Write-Host ("  [服务] taskkill: {0}" -f ($kr -replace '\s+', ' '))
            } else {
                Write-Host '  [服务] PID=0（进程已退出），等待 SCM 状态收敛...' -ForegroundColor Yellow
            }
            $killed = $true
        }
        Start-Sleep -Milliseconds 500
    }

    $i = Get-SvcInfo
    if ($i.Pid -eq 0 -and $i.State -ne 'RUNNING') {
        Write-Host ("  [服务] 进程已消失（SCM 状态 {0}），继续尝试启动。" -f $i.State) -ForegroundColor Yellow
        return $true
    }
    Write-Host ("  [服务] 停止失败: 状态={0} PID={1}" -f $i.State, $i.Pid) -ForegroundColor Red
    Write-Host $i.Raw
    return $false
}

function Start-TsService {
    param([int]$SvcWaitSec = 40, [int]$ReadyWaitSec = 60)

    # STOP_PENDING 需要先收敛，否则 sc start 会失败
    if ((Get-SvcInfo).State -eq 'STOP_PENDING') {
        Write-Host '  [服务] 状态 STOP_PENDING，等待收敛...'
        $sw0 = [Diagnostics.Stopwatch]::StartNew()
        while ($sw0.Elapsed.TotalSeconds -lt 30) {
            if ((Get-SvcInfo).State -eq 'STOPPED') { break }
            Start-Sleep -Milliseconds 500
        }
    }

    $out = (& sc.exe start $SvcName 2>&1 | Out-String).Trim()
    Write-Host ("  [服务] sc start: {0}" -f ($out -replace '\s+', ' '))

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $SvcWaitSec) {
        if ((Get-SvcInfo).State -eq 'RUNNING') { break }
        Start-Sleep -Milliseconds 500
    }
    if ((Get-SvcInfo).State -ne 'RUNNING') {
        Write-Host '  [服务] 未进入 RUNNING。' -ForegroundColor Red
        return $false
    }
    Write-Host '  [服务] RUNNING，等待后端就绪...'

    $ts = Get-TsExe
    if (-not $ts) { return $true }

    $sw.Restart()
    while ($sw.Elapsed.TotalSeconds -lt $ReadyWaitSec) {
        $j = $null
        try { $j = (& $ts status --json 2>$null | Out-String) | ConvertFrom-Json } catch { }
        if ($j -and $j.BackendState -eq 'Running') {
            Write-Host ("  [服务] 后端就绪，用时 {0:N1} 秒。" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Host '  [服务] 后端就绪超时（服务本身已启动）。' -ForegroundColor Yellow
    return $true
}

# ==================== 路径解析 ====================

function Get-PeerPaths {
    param([string]$TsExe)
    $res = @()
    if (-not $TsExe) { return $res }
    $j = $null
    try { $j = (& $TsExe status --json 2>$null | Out-String) | ConvertFrom-Json } catch { return $res }
    if (-not $j -or -not $j.Peer) { return $res }

    foreach ($prop in $j.Peer.PSObject.Properties) {
        $n = $prop.Value
        $name = if ($n.HostName) { $n.HostName }
                elseif ($n.DNSName) { $n.DNSName -replace '\.$', '' }
                else { 'unknown' }
        # CurAddr 非空 = 直连；Relay 非空 = 中继
        if ($n.CurAddr)      { $kind = 'DIRECT';  $detail = $n.CurAddr }
        elseif ($n.Relay)    { $kind = 'RELAY';   $detail = $n.Relay }
        elseif ($n.Online)   { $kind = 'UNKNOWN'; $detail = '在线但无路径信息' }
        else                 { $kind = 'OFFLINE'; $detail = '' }
        $res += [pscustomobject]@{ Name = $name; Kind = $kind; Detail = $detail; Online = [bool]$n.Online }
    }
    return $res
}

function Wait-PeerDirect {
    param([string]$TsExe, [string]$PeerName, [int]$TimeoutSec = 60)
    if ($TimeoutSec -le 0) { return $false }

    Write-Host ("`n  [等待] 最多 {0} 秒，观察 {1} 是否建立直连..." -f $TimeoutSec, $PeerName)
    if ($TsExe) {
        # 主动探测可触发路径发现；stderr 也被安全捕获（EAP 已是 Continue）
        & $TsExe ping -c 2 $PeerName 2>&1 |
            ForEach-Object { Write-Host ('    ' + $_) }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = 0
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $n++
        $p = Get-PeerPaths -TsExe $TsExe | Where-Object { $_.Name -eq $PeerName }
        if ($p -and $p.Kind -eq 'DIRECT') {
            Write-Host ("  [等待] 已升级为直连: {0}  ({1:N0} 秒)" -f $p.Detail, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
            return $true
        }
        if ($n % 6 -eq 0) {
            $k = if ($p) { $p.Kind } else { '未知' }
            Write-Host ("  [等待] {0,3:N0} 秒: 仍为 {1}" -f $sw.Elapsed.TotalSeconds, $k)
        }
        Start-Sleep -Seconds 5
    }
    Write-Host ("  [等待] {0} 秒内未建立直连，保持中继（打洞未成功时属正常）。" -f $TimeoutSec) -ForegroundColor Yellow
    return $false
}

# ==================== 状态展示 ====================

function Show-State {
    param([string]$Title = '当前状态')

    $svc = Get-SvcInfo
    $raw = Read-EnvRaw
    $list = Get-CleanList -Raw $raw
    $corrupted = Test-EnvCorrupted -Raw $raw
    $isOn = ($list -contains $ValData)

    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    Write-Host ("服务状态:       {0}   (进程 PID {1})" -f $svc.State, $svc.Pid)

    if (-not $raw.Exists) {
        Write-Host '注册表项:       不存在（干净状态）'
    } elseif ($corrupted) {
        Write-Host ("注册表项:       存在，但内容畸形！类型={0} 项数={1}" -f $raw.Kind, $raw.Items.Count) -ForegroundColor Red
        foreach ($it in $raw.Items) { Write-Host ("                  [" + $it + "]") -ForegroundColor DarkRed }
    } else {
        Write-Host ("注册表项:       存在，类型={0} 项数={1}" -f $raw.Kind, $raw.Items.Count)
    }

    if ($isOn) {
        Write-Host '强制中继开关:   开启  ->  策略: 只用中继，不做直连' -ForegroundColor Yellow
    } else {
        Write-Host '强制中继开关:   关闭  ->  策略: 允许直连（打洞成功才走直连）' -ForegroundColor Green
    }

    if ($svc.State -ne 'RUNNING') {
        Write-Host '服务未运行，无法读取节点路径。' -ForegroundColor DarkGray
        return
    }
    $ts = Get-TsExe
    if (-not $ts) { Write-Host '找不到 tailscale.exe。' -ForegroundColor Red; return }

    $paths = Get-PeerPaths -TsExe $ts
    Write-Host "`n节点实际路径:"
    foreach ($p in $paths) {
        $color = switch ($p.Kind) {
            'DIRECT'  { 'Green' }
            'RELAY'   { 'Yellow' }
            'OFFLINE' { 'DarkGray' }
            default   { 'White' }
        }
        $sfx = if ($p.Kind -eq 'OFFLINE') { '' } else { '  (' + $p.Detail + ')' }
        Write-Host ("  {0,-16} {1,-8}{2}" -f $p.Name, $p.Kind, $sfx) -ForegroundColor $color
    }

    # 明确区分"开关"与"实际路径"两件事
    $t = $paths | Where-Object { $_.Name -eq $Peer }
    if ($t) {
        Write-Host ''
        if ($isOn -and $t.Kind -eq 'RELAY') {
            Write-Host '判定: 正常 —— 开关开启，路径为中继。' -ForegroundColor Green
        } elseif (-not $isOn -and $t.Kind -eq 'DIRECT') {
            Write-Host '判定: 正常 —— 开关关闭，已建立直连。' -ForegroundColor Green
        } elseif (-not $isOn -and $t.Kind -eq 'RELAY') {
            Write-Host ("判定: 开关关闭但对 {0} 走中继 —— 打洞未成功或尚未完成。" -f $Peer) -ForegroundColor Yellow
        } else {
            Write-Host '判定: 开关开启却显示直连，请贴出输出，属异常。' -ForegroundColor Red
        }
    }
}

# ==================== 主流程（try/finally 保证窗口不消失）====================

# 提权检查放在 try 之前，避免父进程也执行 finally
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '需要管理员权限，正在申请提权...' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Mode', $Mode, '-Peer', $Peer, '-WaitDirectSec', $WaitDirectSec
    )
    exit
}

try {
    if ($Mode -eq 'status') {
        Show-State
        exit 0
    }

    if ($Mode -eq 'diag') {
        Show-State '诊断'
        Write-Host "`n--- sc queryex 原始输出 ---"
        Write-Host (Get-SvcInfo).Raw
        Write-Host "`n--- 注册表项完整内容 ---"
        $raw = Read-EnvRaw
        Write-Host ("存在={0}  类型={1}" -f $raw.Exists, $raw.Kind)
        foreach ($it in $raw.Items) { Write-Host ('  [' + $it + ']') }
        $ts = Get-TsExe
        if ($ts) { Write-Host "`n--- tailscale status ---"; & $ts status }
        exit 0
    }

    # ---------- 计算目标配置 ----------
    $raw = Read-EnvRaw
    $list = Get-CleanList -Raw $raw
    $corrupted = Test-EnvCorrupted -Raw $raw
    $isOn = ($list -contains $ValData)
    $want = ($Mode -eq 'on')

    if ($Mode -eq 'fix') {
        if (-not $corrupted) {
            Write-Host '注册表内容正常，无需修复。' -ForegroundColor Green
            Show-State '当前状态'
            exit 0
        }
        Write-Host '检测到注册表畸形，正在规范化...' -ForegroundColor Cyan
        Set-EnvList -List @($list)
        Write-Host '已修复。'
        Show-State '修复后的状态'
        Write-Host "`n注意: 环境变量只在服务启动时读取，需重启服务或重启电脑才完全生效。" -ForegroundColor Yellow
        Write-Host '如需立即生效: .\ts-derp.ps1 -Mode off' -ForegroundColor Yellow
        exit 0
    }

    $desired = if ($want) { @($list + $ValData | Select-Object -Unique) }
               else { @($list | Where-Object { $_ -ne $ValData }) }

    $curStr = (@($list   | Sort-Object) -join "`n")
    $desStr = (@($desired | Sort-Object) -join "`n")
    $needWrite = $corrupted -or ($curStr -ne $desStr)

    if (-not $needWrite) {
        Write-Host ("开关已是目标状态（{0}），跳过重启。" -f $(if ($want) { '强制中继' } else { '默认' })) -ForegroundColor Green
    } else {
        Write-Host "[1/3] 规范化并写入注册表..." -ForegroundColor Cyan
        if ($corrupted) { Write-Host '      原内容畸形，已一并修正。' -ForegroundColor Yellow }
        Set-EnvList -List $desired
        $after = Read-EnvRaw
        $aL = Get-CleanList -Raw $after
        Write-Host ("      写入后: 存在={0} 类型={1} 项数={2}  开关={3}" -f `
            $after.Exists, $after.Kind, $after.Items.Count,
            $(if ($aL -contains $ValData) { '开' } else { '关' }))

        Write-Host "`n[2/3] 重启 Tailscale 服务（会短暂断开全部隧道）" -ForegroundColor Cyan
        if (-not (Stop-TsService)) {
            Write-Host "`n[中止] 服务无法停止，未执行启动。" -ForegroundColor Red
            Write-Host '注册表已改好，重启电脑后同样生效。' -ForegroundColor Yellow
            exit 1
        }
        Start-TsService | Out-Null
    }

    Write-Host "`n[3/3] 验证" -ForegroundColor Cyan
    $ts = Get-TsExe
    if ($ts) {
        if ($want) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 40) {
                $p = Get-PeerPaths -TsExe $ts | Where-Object { $_.Name -eq $Peer }
                if ($p -and $p.Kind -eq 'RELAY') { Write-Host '      已确认走中继。' -ForegroundColor Green; break }
                Start-Sleep -Seconds 2
            }
        } else {
            Wait-PeerDirect -TsExe $ts -PeerName $Peer -TimeoutSec $WaitDirectSec | Out-Null
        }
    }

    Show-State '最终状态'
    Write-Host ''
} catch {
    Write-Host "`n[异常] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
} finally {
    Read-Host '按回车键退出'
}