#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mxx1.cn
<#
    Test-SetupExe.ps1 —— 安装器 exe 的回归测试

    覆盖：状态输出 / 卸载 / 安装 / 幂等 / 引擎文件字节一致性（含编码红线）/
          隐藏标志清除 / 扩展菜单开关 / 历史注册项清理 / Shell 实测可见性 /
          新命令（checkupdate 的可控路径、disclaimer 正文）。

    前提：当前会话需要有管理员权限（写 HKLM）；否则 exe 会弹 UAC。
    结束时会把现场恢复成"已正确安装"状态。
#>
[CmdletBinding()]
param(
    [string]$Exe = '',
    [string]$ProjectRoot = ''
)

# 在 param 默认值里读 $MyInvocation 拿不到（那时还没绑定），所以放在这里算
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $here }
if (-not $Exe) { $Exe = Join-Path $ProjectRoot 'bin\PermanentDeleteSetup.exe' }

$ErrorActionPreference = 'Continue'
$VerbKey = 'AllFilesystemObjects\shell\PermanentDelete'
$HideFlags = @('LegacyDisable', 'ProgrammaticAccessOnly', 'HideBasedOnVelocityId', 'ExtendedVerbs')

$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++ } else { $script:Fail++ }
    $flag = 'PASS'; if (-not $Ok) { $flag = 'FAIL' }
    Write-Host ("  [{0}] {1}{2}" -f $flag, $Name, $(if ($Detail) { "   ($Detail)" } else { '' }))
}

if (-not (Test-Path -LiteralPath $Exe)) { throw ('找不到 exe: ' + $Exe) }

# exe 是 GUI 子系统：PowerShell 的 & 调用既不等待也不捕获输出；
# 而 Start-Process -PassThru 不加 -Wait 时读不到 ExitCode（PS 5.1 的坑），
# 所以直接用 ProcessStartInfo。
function Invoke-Setup {
    param([string]$ArgLine, [int]$TimeoutSec = 180, [hashtable]$Env = $null)
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $Exe
    $si.Arguments = $ArgLine
    $si.UseShellExecute = $false
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $si.CreateNoWindow = $true
    # 需要在"不碰用户环境变量"的前提下临时改 env（更新检查那两个开关就是这么测的）
    if ($Env) { foreach ($k in $Env.Keys) { $si.EnvironmentVariables[$k] = [string]$Env[$k] } }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $si
    [void]$p.Start()
    # 输出必须**边跑边读**：管道缓冲区只有 4KB，`disclaimer` 那种几 KB 的输出如果
    # 等 WaitForExit 之后再读，子进程会卡在写管道上，双方互等到超时（实测踩过）。
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { } ; return @{ Code = 'TIMEOUT'; Out = ''; Err = '' } }
    $out = ''; $err = ''
    try { $out = $tOut.Result } catch { }
    try { $err = $tErr.Result } catch { }
    return @{ Code = $p.ExitCode; Out = $out; Err = $err }
}

function Get-StatusMap {
    $r = Invoke-Setup -ArgLine 'status'
    $map = @{}
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match '^([A-Za-z][A-Za-z0-9_]*)=(.*)$') { $map[$matches[1]] = $matches[2] }
    }
    $map['__exit'] = $r.Code
    return $map
}

function Get-VerbKey {
    return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Classes\' + $VerbKey)
}

function Clear-LogStart {
    $script:LogMark = 0
    $f = Join-Path $env:LOCALAPPDATA 'PermanentDelete\setup.log'
    if (Test-Path -LiteralPath $f) { $script:LogMark = @([System.IO.File]::ReadAllLines($f)).Count }
}
function Get-LogSince {
    $f = Join-Path $env:LOCALAPPDATA 'PermanentDelete\setup.log'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $l = [System.IO.File]::ReadAllLines($f, [System.Text.Encoding]::UTF8)
    if ($script:LogMark -ge $l.Count) { return '' }
    return ($l[$script:LogMark..($l.Count - 1)] -join "`r`n")
}

Write-Host ''
Write-Host '=========================================================='
Write-Host ' 安装器 exe 回归测试'
Write-Host '=========================================================='
Write-Host (' exe : ' + $Exe)
Write-Host (' 管理员: ' + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
Write-Host ''

# ---------------------------------------------------------------- T01
Write-Host 'T01 帮助'
$r = Invoke-Setup -ArgLine 'help'
Check 'T01 help 退出码 0' ($r.Code -eq 0) ('exit=' + $r.Code)
Check 'T01 帮助含 install/uninstall/status' (($r.Out -match 'install') -and ($r.Out -match 'uninstall') -and ($r.Out -match 'status'))

# ---------------------------------------------------------------- T02
Write-Host 'T02 状态输出可解析'
$m = Get-StatusMap
# status 的退出码本身是有语义的：0 = 已安装，1 = 未安装。
# 所以这里比对"退出码与 installed 是否自洽"，而不是写死 0 ——
# 干净机器（例如 CI runner）上开局就是未安装，写死 0 会误报。
$expectedStatusExit = 0
if ($m['installed'] -eq 'false') { $expectedStatusExit = 1 }
Check 'T02 status 退出码与安装状态自洽' ($m['__exit'] -eq $expectedStatusExit) ('exit=' + $m['__exit'] + ' installed=' + $m['installed'])
Check 'T02 含关键字段' ($m.ContainsKey('installed') -and $m.ContainsKey('engineDeployed') -and $m.ContainsKey('fileVisible') -and $m.ContainsKey('folderVisible') -and $m.ContainsKey('command'))
Check 'T02 未安装时不应有历史残留' ($m['staleKeys'] -eq '') ('staleKeys=' + $m['staleKeys'])

# ---------------------------------------------------------------- T03
Write-Host 'T03 卸载'
# 先确保处于"已安装"状态：干净机器上从没装过的话，下面的"卸载后引擎脚本保留"
# 根本无从验证（文件本来就不存在），CI 上就是这么挂的。
$pre = Invoke-Setup -ArgLine 'install --quiet --no-extended'
Check 'T03 前置安装成功（保证卸载有东西可卸）' ($pre.Code -eq 0) ('exit=' + $pre.Code)
Check 'T03 前置安装后引擎脚本已部署' (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'PermanentDelete.ps1'))

$r = Invoke-Setup -ArgLine 'uninstall --quiet'
Check 'T03 卸载退出码 0' ($r.Code -eq 0) ('exit=' + $r.Code + ' ' + $r.Err.Trim())
$k = Get-VerbKey
Check 'T03 注册表键已删除' ($null -eq $k)
$m = Get-StatusMap
Check 'T03 status 变为未安装' ($m['installed'] -eq 'false')
Check 'T03 Shell 实测菜单不可见' (($m['fileVisible'] -eq 'false') -and ($m['folderVisible'] -eq 'false'))
Check 'T03 引擎脚本默认保留' (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'PermanentDelete.ps1'))

# ---------------------------------------------------------------- T04
Write-Host 'T04 安装'
Clear-LogStart
$r = Invoke-Setup -ArgLine 'install --quiet --no-extended'   # 显式关掉「仅 Shift 显示」，让本套测试不受用户已保存的偏好影响
Check 'T04 安装退出码 0' ($r.Code -eq 0) ('exit=' + $r.Code + ' ' + $r.Err.Trim())
$k = Get-VerbKey
Check 'T04 注册表键存在' ($null -ne $k)
if ($k) {
    $cmd = $k.OpenSubKey('command').GetValue('')
    Check 'T04 菜单文字正确' ($k.GetValue('') -eq '永久删除（不进回收站）') ('text=' + $k.GetValue(''))
    Check 'T04 MultiSelectModel=Player' ($k.GetValue('MultiSelectModel') -eq 'Player')
    Check 'T04 command 指向 VBS 且用 %V' (($cmd -like '*launch_perm_delete.vbs*') -and ($cmd -like '*%V*')) ('cmd=' + $cmd)
    Check 'T04 无隐藏标志' (@($HideFlags | Where-Object { $k.GetValue($_) -ne $null }).Count -eq 0)
    $k.Close()
}
$m = Get-StatusMap
Check 'T04 安装后菜单可见（Shell 实测）' (($m['fileVisible'] -eq 'true') -and ($m['folderVisible'] -eq 'true'))
Check 'T04 没有遗留历史注册项' ($m['staleKeys'] -eq '')
Check 'T04 日志记录了安装' ((Get-LogSince) -match 'install')

# ---------------------------------------------------------------- T05
Write-Host 'T05 引擎文件与工程源文件字节一致（编码红线）'
$depPs1 = Join-Path $env:LOCALAPPDATA 'PermanentDelete.ps1'
$depVbs = Join-Path $env:LOCALAPPDATA 'launch_perm_delete.vbs'
$srcPs1 = Join-Path $ProjectRoot 'engine\PermanentDelete.ps1'
$srcVbs = Join-Path $ProjectRoot 'engine\launch_perm_delete.vbs'
Check 'T05 ps1 哈希与源一致' ((Get-FileHash $depPs1).Hash -eq (Get-FileHash $srcPs1).Hash)
Check 'T05 vbs 哈希与源一致' ((Get-FileHash $depVbs).Hash -eq (Get-FileHash $srcVbs).Hash)
$pb = [System.IO.File]::ReadAllBytes($depPs1)
Check 'T05 部署的 ps1 带 UTF-8 BOM' ($pb[0] -eq 0xEF -and $pb[1] -eq 0xBB -and $pb[2] -eq 0xBF)
$vb = [System.IO.File]::ReadAllBytes($depVbs)
Check 'T05 部署的 vbs 是纯 ASCII' ((($vb | Measure-Object -Maximum).Maximum) -lt 128)

# ---------------------------------------------------------------- T06
Write-Host 'T06 幂等：重复安装'
$r = Invoke-Setup -ArgLine 'install --quiet'
Check 'T06 重复安装仍退出码 0' ($r.Code -eq 0) ('exit=' + $r.Code)
$m = Get-StatusMap
Check 'T06 重复安装后仍可见' (($m['fileVisible'] -eq 'true') -and ($m['folderVisible'] -eq 'true'))
$k = Get-VerbKey
Check 'T06 键仍是干净的' (($null -ne $k) -and (@($HideFlags | Where-Object { $k.GetValue($_) -ne $null }).Count -eq 0))
if ($k) { $k.Close() }

# ---------------------------------------------------------------- T07
Write-Host 'T07 隐藏标志：被菜单管理工具藏起来后能自动修好'
$k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Classes\' + $VerbKey, $true)
$k.SetValue('LegacyDisable', '', [Microsoft.Win32.RegistryValueKind]::String)
$k.SetValue('ProgrammaticAccessOnly', '', [Microsoft.Win32.RegistryValueKind]::String)
$k.SetValue('HideBasedOnVelocityId', 6527944, [Microsoft.Win32.RegistryValueKind]::DWord)
$k.Close()
$m = Get-StatusMap
Check 'T07 status 能报出隐藏标志' ($m['hideFlags'] -match 'LegacyDisable')
Check 'T07 被隐藏时 Shell 实测不可见' (($m['fileVisible'] -eq 'false') -or ($m['folderVisible'] -eq 'false'))
Clear-LogStart
$r = Invoke-Setup -ArgLine 'install --quiet'
Check 'T07 修复后退出码 0' ($r.Code -eq 0) ('exit=' + $r.Code)
$k = Get-VerbKey
Check 'T07 隐藏标志已被清除' (@($HideFlags | Where-Object { $k.GetValue($_) -ne $null }).Count -eq 0)
if ($k) { $k.Close() }
Check 'T07 日志说明清除了什么' ((Get-LogSince) -match '清除隐藏标志')
$m = Get-StatusMap
Check 'T07 修复后恢复可见' (($m['fileVisible'] -eq 'true') -and ($m['folderVisible'] -eq 'true'))

# ---------------------------------------------------------------- T08
Write-Host 'T08 扩展菜单（仅 Shift 显示）开关'
# ★回归：勾了「仅 Shift 显示」之后，Shell 枚举必然看不到这一项（Shell.Application
#   没法模拟按 Shift）。旧版据此判定"安装有问题"，于是 GUI 里一勾这个选项，
#   『添加 / 修复』就红字报"未完全成功"，纯属误报。现在必须仍返回 0 并如实标注。
$r = Invoke-Setup -ArgLine 'install --quiet --extended'
Check 'T08 --extended 安装仍退出码 0（仅 Shift 显示不算故障）' ($r.Code -eq 0) ('exit=' + $r.Code)
$k = Get-VerbKey
Check 'T08 --extended 写入 Extended 值' ($null -ne $k.GetValue('Extended'))
if ($k) { $k.Close() }
$m = Get-StatusMap
Check 'T08 status 如实报告 extendedOnly=true' ($m['extendedOnly'] -eq 'true')
Check 'T08 仅 Shift 时枚举不到（fileVisible=false）' ($m['fileVisible'] -eq 'false')
Check 'T08 但标记为预期 visibleByDesign=true' ($m['visibleByDesign'] -eq 'true')

$r = Invoke-Setup -ArgLine 'install --quiet --no-extended'
Check 'T08 关掉扩展模式后退出码 0' ($r.Code -eq 0) ('exit=' + $r.Code)
$k = Get-VerbKey
Check 'T08 --no-extended 移除 Extended 值' ($null -eq $k.GetValue('Extended'))
if ($k) { $k.Close() }
$m = Get-StatusMap
Check 'T08 关掉后恢复为普通可见' (($m['fileVisible'] -eq 'true') -and ($m['visibleByDesign'] -eq 'false'))

# ---------------------------------------------------------------- T09
Write-Host 'T09 历史注册项自动清理（双击动词的元凶）'
foreach ($stale in @('*\shell\PermanentDelete', 'Directory\shell\PermanentDelete')) {
    $sk = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Classes\' + $stale)
    $sk.SetValue('', '旧版残留', [Microsoft.Win32.RegistryValueKind]::String)
    $ck = $sk.CreateSubKey('command')
    $ck.SetValue('', 'wscript.exe //nologo "C:\old.vbs" %1', [Microsoft.Win32.RegistryValueKind]::String)
    $ck.Close(); $sk.Close()
}
$m = Get-StatusMap
Check 'T09 status 报出历史注册项' ($m['staleKeys'] -match 'shell')
Clear-LogStart
$r = Invoke-Setup -ArgLine 'install --quiet'
$left = @('*\shell\PermanentDelete', 'Directory\shell\PermanentDelete') | Where-Object {
    $null -ne [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Classes\' + $_)
}
Check 'T09 历史注册项被清除' ($left.Count -eq 0) ($left -join ',')
Check 'T09 日志记录了清理' ((Get-LogSince) -match '清理历史注册项')

# ---------------------------------------------------------------- T10
Write-Host 'T10 卸载后菜单确实消失'
$r = Invoke-Setup -ArgLine 'uninstall --quiet'
Check 'T10 卸载退出码 0' ($r.Code -eq 0)
$m = Get-StatusMap
Check 'T10 菜单不可见' (($m['fileVisible'] -eq 'false') -and ($m['folderVisible'] -eq 'false'))

# ---------------------------------------------------------------- T11
Write-Host 'T11 恢复现场（重新安装成可用状态）'
$r = Invoke-Setup -ArgLine 'install --quiet'
$m = Get-StatusMap
Check 'T11 已恢复安装' ($m['installed'] -eq 'true')
Check 'T11 菜单可见' (($m['fileVisible'] -eq 'true') -and ($m['folderVisible'] -eq 'true'))

# ---------------------------------------------------------------- T12
Write-Host 'T12 新命令：更新检查（可控路径）与免责声明'
# ★这套检查**故意不碰外网**：CI 上匿名访问 GitHub 接口随时可能被限流，
#   真去比版本号会把 CI 变成"看运气"。这里只锁两条完全可控的路径：
#   关掉检查（不发任何请求）和接口不可达（指向本机死端口）。
$r = Invoke-Setup -ArgLine 'checkupdate' -Env @{ PERMDEL_NO_UPDATE = '1' }
Check 'T12 关掉更新检查时退出码 0（不联网）' ($r.Code -eq 0) ('exit=' + $r.Code)
Check 'T12 关掉时 update=disabled' ($r.Out -match '(?m)^update=disabled') ('out=' + ($r.Out -replace "`r?`n", ' '))
Check 'T12 关掉时仍带上当前版本号' ($r.Out -match '(?m)^current=\d+\.\d+\.\d+')

$r = Invoke-Setup -ArgLine 'checkupdate' -Env @{
    PERMDEL_UPDATE_URL      = 'http://127.0.0.1:9/releases'
    PERMDEL_UPDATE_TAGS_URL = 'http://127.0.0.1:9/tags'
    PERMDEL_UPDATE_TIMEOUT_MS = '1500'
}
Check 'T12 接口不可达时退出码 1' ($r.Code -eq 1) ('exit=' + $r.Code)
Check 'T12 接口不可达时 update=error' ($r.Out -match '(?m)^update=error') ('out=' + ($r.Out -replace "`r?`n", ' '))
Check 'T12 失败原因可读（纯 ASCII，便于脚本判断）' ($r.Out -match '(?m)^detail=(network-error|http-\d+|exception)')

$r = Invoke-Setup -ArgLine 'disclaimer'
Check 'T12 disclaimer 退出码 0' ($r.Code -eq 0) ('exit=' + $r.Code)
Check 'T12 disclaimer 有正文（不是空窗口）' ($r.Out.Length -gt 2000) ('len=' + $r.Out.Length)
Check 'T12 disclaimer 写清了许可证' ($r.Out -match 'GPL-3\.0-or-later')
Check 'T12 disclaimer 写清了注册表位置与提权' (($r.Out -match 'HKLM') -and ($r.Out -match 'AllFilesystemObjects'))
Check 'T12 disclaimer 写清了删除用的系统 API' ($r.Out -match 'SHFileOperation')
Check 'T12 disclaimer 写清了唯一的网络请求与隐私开关' (($r.Out -match 'api\.github\.com') -and ($r.Out -match 'PERMDEL_NO_UPDATE=1'))
Check 'T12 disclaimer 指向仓库里的正本' ($r.Out -match 'DISCLAIMER\.md')
$mdPath = Join-Path $ProjectRoot 'docs\DISCLAIMER.md'
Check 'T12 仓库里 docs\DISCLAIMER.md 存在且非空' ((Test-Path -LiteralPath $mdPath) -and ((Get-Item -LiteralPath $mdPath).Length -gt 2000))

$r = Invoke-Setup -ArgLine 'help'
Check 'T12 help 里能查到两个新命令' (($r.Out -match 'checkupdate') -and ($r.Out -match 'disclaimer'))

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '=========================================================='
$total = $script:Pass + $script:Fail
Write-Host (" 合计 {0} 项，通过 {1}，失败 {2}" -f $total, $script:Pass, $script:Fail)
Write-Host '=========================================================='
if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
