#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mxx1.cn
<#
    Test-PermanentDelete.ps1 —— 自动化回归测试

    被测对象是「部署后」的脚本，且用 powershell.exe 5.1 启动（和右键菜单实际走
    的路径一致）。测试用 PERMDEL_AUTOCONFIRM 跳过 UI，全部在 %TEMP% 沙箱里进行。

    运行：
        powershell -NoProfile -ExecutionPolicy Bypass -File Test-PermanentDelete.ps1
#>
[CmdletBinding()]
param(
    [string]$Script = (Join-Path $env:LOCALAPPDATA 'PermanentDelete.ps1'),
    [string]$Vbs    = (Join-Path $env:LOCALAPPDATA 'launch_perm_delete.vbs')
)

$ErrorActionPreference = 'Stop'
$PS51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WScript = Join-Path $env:SystemRoot 'System32\wscript.exe'

if (-not (Test-Path -LiteralPath $Script)) { throw "找不到被测脚本: $Script" }
if (-not (Test-Path -LiteralPath $Vbs))    { throw "找不到 VBS: $Vbs" }

$Root  = Join-Path $env:TEMP ('PDTest_' + ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
$LogPath = Join-Path $Root 'test.log'
$Queue = Join-Path $Root 'queue'
[void][System.IO.Directory]::CreateDirectory($Root)
[void][System.IO.Directory]::CreateDirectory($Queue)

$env:PERMDEL_LOG          = $LogPath
$env:PERMDEL_QUEUE        = $Queue
$env:PERMDEL_AUTOCONFIRM  = 'yes'
$env:PERMDEL_MERGE_MS     = '900'
$env:PERMDEL_BIG_FILES    = '1500'

$script:Results = New-Object System.Collections.Generic.List[object]
$script:TagNo = 0

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Ok = $Ok; Name = $Name; Detail = $Detail })
    $flag = 'PASS'
    if (-not $Ok) { $flag = 'FAIL' }
    Write-Host ("  [{0}] {1}{2}" -f $flag, $Name, $(if ($Detail) { "   ($Detail)" } else { '' }))
}

function Quote-Arg {
    param([string]$A)
    $s = $A
    if ($s.EndsWith('\')) { $s = $s + '\' }   # 尾反斜杠会吞掉闭合引号
    return '"' + $s + '"'
}

function Test-PDMutexFree {
    # 抢得到互斥体 ⇒ 没有活着的脚本实例（被放弃的互斥体也算空闲）
    $m = New-Object System.Threading.Mutex($false, 'Local\PermanentDelete.Agent')
    $got = $false
    try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if ($got) { try { [void]$m.ReleaseMutex() } catch { } }
    $m.Dispose()
    return $got
}

function Wait-PDIdle {
    # VBS 是异步启动 powershell 的，上一轮用例的进程可能还活着并持有互斥体，
    # 会让下一个用例变成"次要实例"而被合并 —— 必须等它彻底退出。
    Start-Sleep -Milliseconds 700
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if (Test-PDMutexFree) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Reset-State {
    $script:TagNo++
    [void](Wait-PDIdle)
    if ([System.IO.Directory]::Exists($Queue)) {
        foreach ($f in [System.IO.Directory]::GetFiles($Queue)) { try { [System.IO.File]::Delete($f) } catch { } }
    }
    # 日志累积不删，只记下当前行数作为本次用例的切片起点（失败时能留下证据）
    $script:LogMark = 0
    if ([System.IO.File]::Exists($LogPath)) {
        $script:LogMark = @([System.IO.File]::ReadAllLines($LogPath)).Count
    }
    $env:PERMDEL_MERGE_MS  = '900'
    $env:PERMDEL_MERGE_MAX_MS = '8000'
    $env:PERMDEL_BIG_FILES = '1500'
    $env:PERMDEL_AUTOCONFIRM = 'yes'
    $env:PERMDEL_ARGSFILE_THRESHOLD = ''
    # 统计上限也要复位，否则会串到下一个用例（空字符串 = 用引擎默认值）
    $env:PERMDEL_MEASURE_MS = ''
    $env:PERMDEL_MEASURE_ITEM_LIMIT = ''
    $env:PERMDEL_MEASURE_ENTRY_LIMIT = ''
}

function New-Dir {
    param([string]$Name)
    $p = Join-Path $Root $Name
    [void][System.IO.Directory]::CreateDirectory($p)
    return $p
}

function Read-LogText {
    if (-not [System.IO.File]::Exists($LogPath)) { return '' }
    $lines = [System.IO.File]::ReadAllLines($LogPath, [System.Text.Encoding]::UTF8)
    if ($script:LogMark -ge $lines.Count) { return '' }
    return ($lines[$script:LogMark..($lines.Count - 1)] -join "`r`n")
}

function Start-PD {
    param([string[]]$Targets, [switch]$ViaVbs, [string]$Tag = 'a', [int]$ExpectSeconds = 90)
    if ($ViaVbs) {
        $file = $WScript
        $argLine = '//nologo ' + (Quote-Arg $Vbs)
    } else {
        $file = $PS51
        $argLine = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -File ' + (Quote-Arg $Script)
    }
    foreach ($t in $Targets) { $argLine += ' ' + (Quote-Arg $t) }

    # 注意：PS 5.1 的 Start-Process -PassThru -Redirect* 返回的 Process 读不到 ExitCode，
    # 必须直接用 ProcessStartInfo 启动。
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName               = $file
    $si.Arguments              = $argLine
    $si.UseShellExecute        = $false
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError  = $true
    $si.CreateNoWindow         = $true
    $si.WindowStyle            = [System.Diagnostics.ProcessWindowStyle]::Hidden

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $si
    [void]$p.Start()
    # 必须**边跑边读**：管道缓冲区只有 4KB，等 WaitForExit 之后再读的话，
    # 只要被测脚本输出超过这个量，双方就会互等到超时（安装器测试里实测踩过）。
    return @{ Proc = $p; ExpectSeconds = $ExpectSeconds;
              OutTask = $p.StandardOutput.ReadToEndAsync(); ErrTask = $p.StandardError.ReadToEndAsync();
              Stdout = ''; Stderr = '' }
}

function Wait-PD {
    param($Handle)
    $p = $Handle.Proc
    if (-not $p.WaitForExit($Handle.ExpectSeconds * 1000)) {
        try { $p.Kill() } catch { }
        return 'TIMEOUT'
    }
    [void]$p.WaitForExit()
    try { $Handle.Stdout = $Handle.OutTask.Result } catch { }
    try { $Handle.Stderr = $Handle.ErrTask.Result } catch { }
    return $p.ExitCode
}

function Run-PD {
    param([string[]]$Targets, [switch]$ViaVbs, [int]$ExpectSeconds = 90)
    $script:TagNo++
    $h = Start-PD -Targets $Targets -ViaVbs:$ViaVbs -Tag ([string]$script:TagNo) -ExpectSeconds $ExpectSeconds
    $code = Wait-PD -Handle $h
    return @{ Code = $code; Stderr = $h.Stderr; Stdout = $h.Stdout }
}

function Wait-Gone {
    param([string]$Path, [int]$Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Test-Path -LiteralPath $Path) -and ((Get-Date) -lt $deadline)) { Start-Sleep -Milliseconds 150 }
    return -not (Test-Path -LiteralPath $Path)
}

Write-Host ''
Write-Host '=========================================================='
Write-Host ' PermanentDelete 回归测试'
Write-Host '=========================================================='
Write-Host (" 被测脚本 : {0}" -f $Script)
Write-Host (" VBS      : {0}" -f $Vbs)
Write-Host (" 沙箱     : {0}" -f $Root)
Write-Host ''

# ---------------------------------------------------------------- T01  ★致命回归
Write-Host 'T01 ★单个文件（必须走确认框，且不能被当成参数文件）'
Reset-State
$d  = New-Dir 't01'
$f1 = Join-Path $d 'a.txt'
[System.IO.File]::WriteAllText($f1, 'x')
$r = Run-PD @($f1)
$logText = Read-LogText
Check 'T01 文件已删除' (-not (Test-Path -LiteralPath $f1))
Check 'T01 经过确认框（CONFIRM yes n=1）' ($logText -match 'CONFIRM yes n=1')
Check 'T01 没有被当成参数文件' (-not ($logText -match 'ARGSFILE read'))
Check 'T01 只弹一次确认' (([regex]::Matches($logText, 'CONFIRM yes')).Count -eq 1)
Check 'T01 退出码 0' ($r.Code -eq 0) ("exit=" + $r.Code)

# ---------------------------------------------------------------- T02
Write-Host 'T02 三个文件'
Reset-State
$d = New-Dir 't02'
$fs = @()
1..3 | ForEach-Object { $p = Join-Path $d ("f$_.txt"); [System.IO.File]::WriteAllText($p, 'x'); $fs += $p }
$r = Run-PD $fs
$logText = Read-LogText
Check 'T02 三个文件已删除' (@($fs | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0)
Check 'T02 只弹一次确认' (([regex]::Matches($logText, 'CONFIRM yes')).Count -eq 1)

# ---------------------------------------------------------------- T03  ★核心回归
Write-Host 'T03 ★混合选中（文件 + 文件夹，Explorer 会调用两次）'
Reset-State
$d    = New-Dir 't03'
$sub  = Join-Path $d 'Vector Magic 1.15 中文版'
[void][System.IO.Directory]::CreateDirectory($sub)
[System.IO.File]::WriteAllText((Join-Path $sub 'inner.txt'), 'x')
$files = @()
foreach ($n in @('免责声明.txt', '搜 索 更 多 工 具.png', '素 材 资 源 网mxx1.url')) {
    $p = Join-Path $d $n
    [System.IO.File]::WriteAllText($p, 'x')
    $files += $p
}
$env:PERMDEL_MERGE_MS = '1500'
# 模拟 Explorer：两个进程同时启动，一个带文件列表，一个带文件夹
$h1 = Start-PD -Targets $files -Tag 't03a'
$h2 = Start-PD -Targets @($sub) -Tag 't03b'
$c1 = Wait-PD -Handle $h1
$c2 = Wait-PD -Handle $h2
$logText = Read-LogText
$confirms = ([regex]::Matches($logText, 'CONFIRM yes')).Count
Check 'T03 只弹一次确认框（回归修复）' ($confirms -eq 1) ("CONFIRM=$confirms")
Check 'T03 批次数为 1' (([regex]::Matches($logText, 'BATCH n=')).Count -eq 1)
Check 'T03 三个文件已删除' (@($files | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0)
Check 'T03 文件夹已删除' (-not (Test-Path -LiteralPath $sub))
Check 'T03 出现 HANDOFF' ($logText -match 'HANDOFF n=')
Check 'T03 两个进程都正常退出' (($c1 -eq 0) -and ($c2 -eq 0)) ("c1=$c1 c2=$c2")

# ---------------------------------------------------------------- T04
Write-Host 'T04 只读文件（原生递归删除会失败，走兜底遍历）'
Reset-State
$d   = New-Dir 't04'
$sub = Join-Path $d 'sub'
[void][System.IO.Directory]::CreateDirectory($sub)
$ro  = Join-Path $d 'readonly.txt'
$ro2 = Join-Path $sub 'readonly2.txt'
[System.IO.File]::WriteAllText($ro, 'x')
[System.IO.File]::WriteAllText($ro2, 'x')
(Get-Item -LiteralPath $ro).Attributes  = [System.IO.FileAttributes]::ReadOnly
(Get-Item -LiteralPath $ro2).Attributes = [System.IO.FileAttributes]::ReadOnly
$r = Run-PD @($d)
$logText = Read-LogText
Check 'T04 含只读文件的目录已删除' (-not (Test-Path -LiteralPath $d))
Check 'T04 无失败记录' (-not ($logText -match 'FAILED'))

# ---------------------------------------------------------------- T05
Write-Host 'T05 嵌套选中（父目录 + 内部文件）'
Reset-State
$d   = New-Dir 't05'
$sub = Join-Path $d 'inner'
[void][System.IO.Directory]::CreateDirectory($sub)
$f   = Join-Path $sub 'x.txt'
[System.IO.File]::WriteAllText($f, 'x')
$r = Run-PD @($d, $f)
$logText = Read-LogText
Check 'T05 目录已删除' (-not (Test-Path -LiteralPath $d))
Check 'T05 折叠了嵌套项' ($logText -match 'NESTED collapsed=1')
Check 'T05 无失败记录' (-not ($logText -match 'FAILED'))

# ---------------------------------------------------------------- T06
Write-Host 'T06 带空格/中文的路径 + 尾部反斜杠（走真实 VBS 链路）'
Reset-State
$d    = New-Dir 't06'
$sub  = Join-Path $d '目录 带 空格'
[void][System.IO.Directory]::CreateDirectory($sub)
[System.IO.File]::WriteAllText((Join-Path $sub '内 部 文 件.txt'), 'x')
$r = Run-PD @($sub, ($sub + '\')) -ViaVbs        # 故意传一个尾部带反斜杠的
$gone = Wait-Gone -Path $sub -Seconds 40
Start-Sleep -Milliseconds 400
$logText = Read-LogText
Check 'T06 VBS 链路删除成功' $gone
Check 'T06 VBS 退出码 0' ($r.Code -eq 0) ("exit=" + $r.Code)
# 命令行很短，必须走直接参数分支；一旦这里变成 ARGSFILE，说明 VBS 的阈值被破坏了
Check 'T06 走直接命令行分支（未用 ArgsFile）' (-not ($logText -match 'ARGSFILE'))

# ---------------------------------------------------------------- T07
Write-Host 'T07 超长路径（> 260 字符）'
Reset-State
$base = New-Dir 't07'
$deep = $base
1..9 | ForEach-Object { $deep = $deep + '\' + 'segment_abcdefghijklmno' }   # 每级 23 字符
$deepExt = '\\?\' + $deep
[void][System.IO.Directory]::CreateDirectory($deepExt)
[System.IO.File]::WriteAllText($deepExt + '\deep_file.txt', 'x')
$len = $deep.Length
$r = Run-PD @($deep)
Check 'T07 超长路径目录已删除' (-not [System.IO.Directory]::Exists($deepExt)) ("len=$len")
Check 'T07 退出码 0' ($r.Code -eq 0)

# ---------------------------------------------------------------- T08  ★安全
Write-Host 'T08 ★联接点安全（只删链接，不碰目标数据）'
Reset-State
$target = New-Dir 't08_target'
[System.IO.File]::WriteAllText((Join-Path $target 'keep.txt'), 'precious')
$holder = New-Dir 't08_holder'
$link   = Join-Path $holder 'link'
$mk     = & cmd.exe /c "mklink /J `"$link`" `"$target`"" 2>&1
Check 'T08 联接点创建成功' (Test-Path -LiteralPath $link) ($mk -join ' ')
$r = Run-PD @($link)
$logText = Read-LogText
Check 'T08 联接点已删除' (-not (Test-Path -LiteralPath $link))
Check 'T08 目标目录仍在' (Test-Path -LiteralPath $target)
Check 'T08 目标数据仍在' (Test-Path -LiteralPath (Join-Path $target 'keep.txt'))
Check 'T08 无失败记录' (-not ($logText -match 'FAILED'))

# ---------------------------------------------------------------- T09
Write-Host 'T09 盘根保护'
Reset-State
$r = Run-PD @('C:\')
$logText = Read-LogText
Check 'T09 盘根被拒绝' ($logText -match 'REJECT C:\\')
Check 'T09 没有弹确认框' (-not ($logText -match 'CONFIRM'))
Check 'T09 退出码 0' ($r.Code -eq 0)

# ---------------------------------------------------------------- T10
Write-Host 'T10 用户点取消'
Reset-State
$d = New-Dir 't10'
$f = Join-Path $d 'keep_me.txt'
[System.IO.File]::WriteAllText($f, 'x')
$env:PERMDEL_AUTOCONFIRM = 'no'
$r = Run-PD @($f)
$logText = Read-LogText
Check 'T10 取消后文件仍在' (Test-Path -LiteralPath $f)
Check 'T10 记录了取消' ($logText -match 'CONFIRM no')

# ---------------------------------------------------------------- T11
Write-Host 'T11 路径不存在'
Reset-State
$missing = Join-Path $Root ('not_here_' + [Guid]::NewGuid().ToString('N'))
$r = Run-PD @($missing)
$logText = Read-LogText
Check 'T11 不崩溃且退出码 0' ($r.Code -eq 0) ("exit=" + $r.Code)
Check 'T11 记录 NOOP' ($logText -match 'NOOP')

# ---------------------------------------------------------------- T12
Write-Host 'T12 大目录分支（分片删除 + 消息泵）'
Reset-State
$env:PERMDEL_BIG_FILES = '5'
$d = New-Dir 't12'
1..12 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $d ("big$_.txt")), ('x' * 1024)) }
$sub = Join-Path $d 'subs'
[void][System.IO.Directory]::CreateDirectory($sub)
1..3 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $sub ("s$_.txt")), 'x') }
$r = Run-PD @($d)
$logText = Read-LogText
Check 'T12 大目录已删除' (-not (Test-Path -LiteralPath $d))
Check 'T12 无失败记录' (-not ($logText -match 'FAILED'))

# ---------------------------------------------------------------- T13  ★安全
Write-Host 'T13 ★启动时清理残留队列（绝不重放历史路径）'
Reset-State
$victim  = Join-Path $Root 'victim_stale.txt'
$decoy   = Join-Path $Root 'decoy.txt'
[System.IO.File]::WriteAllText($victim, 'x')
[System.IO.File]::WriteAllText($decoy, 'x')
$stale = Join-Path $Queue ([Guid]::NewGuid().ToString('N') + '.arg')
[System.IO.File]::WriteAllLines($stale, @($victim), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::SetLastWriteTime($stale, (Get-Date).AddMinutes(-10))
$r = Run-PD @($decoy)
$logText = Read-LogText
Check 'T13 目标文件已删除' (-not (Test-Path -LiteralPath $decoy))
Check 'T13 陈旧路径未被误删' (Test-Path -LiteralPath $victim)
Check 'T13 日志里没有出现陈旧路径' (-not ($logText -match [regex]::Escape($victim)))

# ---------------------------------------------------------------- T14  ★致命回归
Write-Host 'T14 ★单个文件 + 取消（绝不能绕过确认就删）'
Reset-State
$d = New-Dir 't14'
$f = Join-Path $d 'must_survive.txt'
[System.IO.File]::WriteAllText($f, 'x')
$env:PERMDEL_AUTOCONFIRM = 'no'
$r = Run-PD @($f)
$logText = Read-LogText
Check 'T14 取消后文件仍在' (Test-Path -LiteralPath $f)
Check 'T14 记录了 CONFIRM no n=1' ($logText -match 'CONFIRM no n=1')

# ---------------------------------------------------------------- T15  ★致命回归
Write-Host 'T15 ★伪造的 permdelete_args_*.pdl 不能被当成参数文件'
Reset-State
$d      = New-Dir 't15'
$victim = Join-Path $Root 't15_victim.txt'
[System.IO.File]::WriteAllText($victim, 'x')
$fake   = Join-Path $d 'permdelete_args_fake.pdl'
[System.IO.File]::WriteAllLines($fake, @($victim), (New-Object System.Text.UTF8Encoding($false)))
$r = Run-PD @($fake)
$logText = Read-LogText
Check 'T15 伪造文件被当成普通路径删除' (-not (Test-Path -LiteralPath $fake))
Check 'T15 未被当作参数文件读取' (-not ($logText -match 'ARGSFILE read'))
Check 'T15 文件里写的路径没有被删' (Test-Path -LiteralPath $victim)

# ---------------------------------------------------------------- T16
Write-Host 'T16 命令行超长 → VBS 走 -ArgsFile（.pdl）链路'
Reset-State
$d = New-Dir 't16'
$many = @()
foreach ($i in 1..3) {
    $p = Join-Path $d ("参数文件链路 测试 $i.txt")
    [System.IO.File]::WriteAllText($p, 'x')
    $many += $p
}
$env:PERMDEL_ARGSFILE_THRESHOLD = '200'      # 强制 VBS 走文件传参分支
$r = Run-PD $many -ViaVbs
$null = Wait-Gone -Path $many[0] -Seconds 40
Start-Sleep -Milliseconds 400
$logText = Read-LogText
Check 'T16 三个文件已删除' (@($many | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0)
Check 'T16 走的是 ARGSFILE 分支' ($logText -match 'ARGSFILE read=3')
Check 'T16 VBS 退出码 0' ($r.Code -eq 0) ("exit=" + $r.Code)
$env:PERMDEL_ARGSFILE_THRESHOLD = ''

# ---------------------------------------------------------------- T17  ★回归
Write-Host 'T17 ★确认框开着期间新入队的请求必须被采纳（不看时间戳）'
Reset-State
$d  = New-Dir 't17'
$fA = Join-Path $d 'first.txt'
$fB = Join-Path $d 'queued_later.txt'
[System.IO.File]::WriteAllText($fA, 'x')
[System.IO.File]::WriteAllText($fB, 'x')
$env:PERMDEL_MERGE_MS = '4000'          # 拉长窗口，模拟"用户在确认框上停留"
$h = Start-PD -Targets @($fA) -Tag 't17' -ExpectSeconds 60
# 等主实例完成"清残留 + 写入自己的条目"后再注入，避免注入被启动清理吃掉（时序竞态）
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    if (@(Get-ChildItem -LiteralPath $Queue -Filter '*.arg' -ErrorAction SilentlyContinue).Count -ge 1) { break }
    Start-Sleep -Milliseconds 100
}
$entry = Join-Path $Queue ([Guid]::NewGuid().ToString('N') + '.arg')
[System.IO.File]::WriteAllLines($entry, @($fB), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::SetLastWriteTime($entry, (Get-Date).AddMinutes(-30))   # 故意做成"很旧"
$code = Wait-PD -Handle $h
Start-Sleep -Milliseconds 500
$logText = Read-LogText
Check 'T17 后入队的文件也被删除' (-not (Test-Path -LiteralPath $fB))
Check 'T17 先入队的文件也被删除' (-not (Test-Path -LiteralPath $fA))
Check 'T17 合并成一个批次' (([regex]::Matches($logText, 'CONFIRM yes')).Count -eq 1)
Check 'T17 退出码 0' ($code -eq 0) ("exit=" + $code)

# ---------------------------------------------------------------- T18  ★回归
Write-Host 'T18 ★Shell 逐个调用（间隔到达）必须合并成一个确认框'
Reset-State
$env:PERMDEL_MERGE_MS     = '8000'    # 静默期必须明显大于「下一次进程冷启动」的耗时
$env:PERMDEL_MERGE_MAX_MS = '20000'   # （高负载下 Start-PD 冷启动可达 3s，窗口太小会被判成两批）
$d  = New-Dir 't18'
$fa = Join-Path $d 'a.txt'
$fb = Join-Path $d 'b.txt'
$fc = Join-Path $d 'c.txt'
[System.IO.File]::WriteAllText($fa, 'x')
[System.IO.File]::WriteAllText($fb, 'x')
[System.IO.File]::WriteAllText($fc, 'x')

$h1 = Start-PD -Targets @($fa) -Tag 't18a' -ExpectSeconds 90
# 等主实例把自己的条目写进队列
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    if (@(Get-ChildItem -LiteralPath $Queue -Filter '*.arg' -ErrorAction SilentlyContinue).Count -ge 1) { break }
    Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 200
$h2 = Start-PD -Targets @($fb) -Tag 't18b' -ExpectSeconds 90
Start-Sleep -Milliseconds 200
$h3 = Start-PD -Targets @($fc) -Tag 't18c' -ExpectSeconds 90
$null = Wait-PD -Handle $h1
$null = Wait-PD -Handle $h2
$null = Wait-PD -Handle $h3
$logText  = Read-LogText
$batches  = ([regex]::Matches($logText, 'BATCH n=')).Count
$confirms = ([regex]::Matches($logText, 'CONFIRM yes')).Count
Check 'T18 三个文件都删掉了' (@(@($fa, $fb, $fc) | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0)
Check 'T18 只形成一个批次' ($batches -eq 1) ("BATCH 次数=" + $batches)
Check 'T18 只弹一次确认框' ($confirms -eq 1) ("CONFIRM 次数=" + $confirms)
Check 'T18 批次含 3 项' ($logText -match 'BATCH n=3')

# ---------------------------------------------------------------- T19  ★回归
# 大选择绝不允许"先把整棵树扫一遍再弹框" —— 那正是"右键半天不出确认框"的元凶。
Write-Host 'T19 ★选中项太多时直接不统计（确认框立刻出现，数字标成"≥"）'
Reset-State
$env:PERMDEL_MEASURE_ITEM_LIMIT = '1'      # 2 个目标 > 上限 1 → 一次都不该扫
$d  = New-Dir 't19'
$f1 = Join-Path $d 'a.txt'; [System.IO.File]::WriteAllText($f1, 'x')
$f2 = Join-Path $d 'b.txt'; [System.IO.File]::WriteAllText($f2, 'x')
$h1 = Start-PD -Targets @($f1, $f2) -Tag 't19' -ExpectSeconds 90
$null = Wait-PD -Handle $h1
$logText = Read-LogText
Check 'T19 日志标明因项数超限而未统计' ($logText -match 'MEASURE capped reason=items') '（没有这行说明仍在扫描）'
Check 'T19 确认框里的数字标成 ≥' ($logText -match '≥ 0 个文件') '（应为 ≥ 0：没扫就报 0）'
Check 'T19 确认框提示可点按钮精确统计' ($logText -match '未完整统计')
Check 'T19 两个文件仍被正常删除' ((@(@($f1, $f2) | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0))

# ---------------------------------------------------------------- T20  ★回归
Write-Host 'T20 ★目录里文件太多时统计到上限就停手'
Reset-State
$env:PERMDEL_MEASURE_ENTRY_LIMIT = '5'     # 扫到 5 个条目就停
$d   = New-Dir 't20'
$sub = Join-Path $d 'big'
[void][System.IO.Directory]::CreateDirectory($sub)
for ($i = 1; $i -le 20; $i++) { [System.IO.File]::WriteAllText((Join-Path $sub ("f$i.txt")), 'x') }
$h1 = Start-PD -Targets @($sub) -Tag 't20' -ExpectSeconds 90
$null = Wait-PD -Handle $h1
$logText = Read-LogText
Check 'T20 日志标明因条目数超限而停手' ($logText -match 'MEASURE capped reason=entries')
Check 'T20 统计确实停在上限附近（不是数完 20 个）' ($logText -match '≥ 5 个文件')
Check 'T20 大目录仍被完整删除' (-not (Test-Path -LiteralPath $sub))

# ---------------------------------------------------------------- T21  ★回归
Write-Host 'T21 ★小选择仍然给精确数字（不能因为上面的改动把常规体验搞坏）'
Reset-State
$d  = New-Dir 't21'
$f1 = Join-Path $d 'only.txt'; [System.IO.File]::WriteAllText($f1, 'hello')
$h1 = Start-PD -Targets @($f1) -Tag 't21' -ExpectSeconds 90
$null = Wait-PD -Handle $h1
$logText = Read-LogText
Check 'T21 没有出现 capped' (-not ($logText -match 'MEASURE capped'))
Check 'T21 数字是精确的"约"' ($logText -match '约 1 个文件')
Check 'T21 不提示"未完整统计"' (-not ($logText -match '未完整统计'))
Check 'T21 文件被删除' (-not (Test-Path -LiteralPath $f1))

# ---------------------------------------------------------------- T22  ★回归
# 用户反馈：右键弹框 → 点取消 → 桌面上又冒出一个"正在汇总选中的项目…"的窗口。
# 根因是主循环处理完一批之后又走了一遍完整的合并窗口（还在 300ms 处弹窗）。
# 现在第二批只做一小段静默宽限，一个窗口都不许弹。
Write-Host 'T22 ★确认框关掉之后不许再等一整轮合并窗口（否则会再冒一个汇总框）'
Reset-State
$env:PERMDEL_MERGE_MS = '3000'          # 拉长第一轮，好区分"第一轮"和"收尾宽限"
$d  = New-Dir 't22'
$f1 = Join-Path $d 'a.txt'; [System.IO.File]::WriteAllText($f1, 'x')
$h1 = Start-PD -Targets @($f1) -Tag 't22' -ExpectSeconds 90
$null = Wait-PD -Handle $h1
$logText = Read-LogText
Check 'T22 第一轮走的是正常合并窗口' ($logText -match 'WINDOW round=1 waited=[3-9]\d{3}ms')
$m2 = [regex]::Match($logText, 'WINDOW round=2 waited=(\d+)ms')
Check 'T22 第二轮只做静默短宽限（<1000ms）' ($m2.Success -and [int]$m2.Groups[1].Value -lt 1000) $m2.Value
$rounds = ([regex]::Matches($logText, 'WINDOW round=')).Count
Check 'T22 只有两轮，不会来回空转' ($rounds -eq 2) ("round 次数=" + $rounds)
Check 'T22 文件被删除' (-not (Test-Path -LiteralPath $f1))
$env:PERMDEL_MERGE_MS = ''

# ---------------------------------------------------------------- 汇总
$fail = @($script:Results | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host '=========================================================='
Write-Host (" 合计 {0} 项，通过 {1}，失败 {2}" -f $script:Results.Count, ($script:Results.Count - $fail.Count), $fail.Count)
if ($fail.Count -gt 0) {
    Write-Host ' 失败列表：'
    foreach ($f in $fail) { Write-Host ("   - {0} {1}" -f $f.Name, $f.Detail) }
}
Write-Host '=========================================================='
Write-Host (" 临时目录: {0}" -f $Root)
Write-Host (" 完整日志: {0}" -f $LogPath)
Write-Host ''

if ($fail.Count -eq 0) { exit 0 } else { exit 1 }
