#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mxx1.cn
<#
    PermanentDelete.ps1  —— 右键菜单「永久删除（不进回收站）」主脚本

    设计要点
    ------------------------------------------------------------------
    1. 单实例合并：Explorer 对「文件 + 文件夹」混合选中会分别调用文件动词和
       文件夹动词，导致命令被执行多次、弹出多个确认框。本脚本用命名互斥体
       (Mutex) 选出一个主实例，其余实例只把自己的路径写进队列目录后退出；
       主实例在合并窗口内收集所有实例的路径，合并成一个批次，只弹一次确认框。
    2. 列表只显示一次、删除只做一次，嵌套路径（父目录 + 其子项）自动折叠，
       不会出现"父目录已删 → 子项报删除失败"。
    3. 删除引擎：优先用 .NET 原生递归删除（快）；失败或目录很大时改用
       自底向上遍历（清只读/隐藏/系统属性、支持超长路径 \\?\、软链接只删链接
       本身不递归进目标），并在删除过程中泵消息，避免窗口"无响应"。
    4. 安全：盘根 / UNC 共享根直接拒绝；确认框默认按钮是"取消"（回车 = 取消）。
    5. 日志：%LOCALAPPDATA%\PermanentDelete\delete.log

    仅测试用环境变量
    ------------------------------------------------------------------
    PERMDEL_AUTOCONFIRM = yes|no   跳过 UI，直接按此决定（自动化测试用）
    PERMDEL_MERGE_MS    = 整数      合并窗口毫秒（默认 700）
    PERMDEL_QUEUE       = 目录      队列目录覆盖
    PERMDEL_LOG         = 文件      日志文件覆盖
    PERMDEL_BIG_FILES   = 整数      大目录阈值（默认 1500）
    PERMDEL_MEASURE_MS          = 整数   自动统计的时间预算毫秒（默认 700，0 = 不限）
    PERMDEL_MEASURE_ITEM_LIMIT  = 整数   选中项超过它就直接不统计（默认 300，0 = 不限）
    PERMDEL_MEASURE_ENTRY_LIMIT = 整数   数到这么多条目就停手（默认 20000，0 = 不限）
    PERMDEL_MERGE_MAX_MS        = 整数   合并窗口硬上限（默认 8000）
    PERMDEL_MERGE_FEEDBACK_MS   = 整数   "正在汇总"窗口最早在多少毫秒后允许出现（默认 900）
    PERMDEL_POSTGRACE_MS        = 整数   一批处理完后的静默收尾宽限（默认 400，期间不弹任何窗口）
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # 右键菜单传来的路径（%V）。必须配合 PositionalBinding=$false：
    # 否则 PowerShell 会把第一个路径绑定到下一个位置参数 $ArgsFile 上，
    # 于是"只选中一个文件"时，第一个文件会被当成参数文件读掉并删除
    # —— 曾经因此绕过确认框直接删文件。
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths,

    # 命令行过长时由 VBS 走这条路（UTF-16 文本，每行一个路径）
    [string]$ArgsFile
)

$ErrorActionPreference = 'Stop'

#region ---------------- 配置 ----------------
$AppRoot  = Join-Path $env:LOCALAPPDATA 'PermanentDelete'
$QueueDir = if ($env:PERMDEL_QUEUE) { $env:PERMDEL_QUEUE } else { Join-Path $AppRoot 'queue' }
$LogFile  = if ($env:PERMDEL_LOG)   { $env:PERMDEL_LOG }   else { Join-Path $AppRoot 'delete.log' }

$MutexName        = 'Local\PermanentDelete.Agent'
# 自适应合并窗口：只要还有新实例带着路径进来，就继续等；连续 MergeWindowMs 没有新条目才收工。
# （Windows 对静态动词是"逐个选中项各调一次"，一次选中几十项会分几十次调用，
#   固定窗口只能兜住最早那一批，于是出现多个确认框 —— 所以必须自适应。）
$MergeWindowMs    = if ($env:PERMDEL_MERGE_MS)     { [int]$env:PERMDEL_MERGE_MS }     else { 700 }
$MergeMaxMs       = if ($env:PERMDEL_MERGE_MAX_MS) { [int]$env:PERMDEL_MERGE_MAX_MS } else { 8000 }
# "正在汇总选中的项目…"这个进度框什么时候才允许冒头：只有真的在等一批项目
# （已收到 2 项以上、且已经等了这么久还没到齐）时才弹。单次右键根本不需要它 ——
# 弹一下再消失，用户会以为程序出了故障。
$MergeFeedbackMs  = if ($env:PERMDEL_MERGE_FEEDBACK_MS) { [int]$env:PERMDEL_MERGE_FEEDBACK_MS } else { 900 }
# 一批处理完（用户在确认框上点了确定或取消）之后的"静默收尾宽限"：只等这么一小会儿
# 看看有没有新请求进来，期间**绝不显示任何窗口**。
$PostBatchGraceMs = if ($env:PERMDEL_POSTGRACE_MS) { [int]$env:PERMDEL_POSTGRACE_MS } else { 400 }
$BigFileThreshold = if ($env:PERMDEL_BIG_FILES) { [int]$env:PERMDEL_BIG_FILES } else { 1500 }
$QueueStaleSec    = 60

# ---- 统计（"共多少个文件、合计多大"）的预算与上限 ----
# 这一段直接决定"右键之后多久能看到确认框"，所以三条都要卡死：
#   1) 时间预算：自动统计最多花这么多毫秒，超了就报"≥"并停手；
#   2) 顶层项目数上限：选中项本身就多到爆（例如框选几千项）时，直接**一次都不扫**；
#   3) 条目数上限：一个大目录里文件成千上万时，数到这么多就停。
# 命中任何一条 → 确认框里的数字标成"≥"，并在框上出现『统计实际大小』按钮，
# 用户想精确数字时自己点（那时才做完整统计，期间有进度与停止）。
$MeasureBudgetMs    = if ($env:PERMDEL_MEASURE_MS)         { [int]$env:PERMDEL_MEASURE_MS }         else { 700 }
$MeasureItemLimit   = if ($env:PERMDEL_MEASURE_ITEM_LIMIT) { [int]$env:PERMDEL_MEASURE_ITEM_LIMIT } else { 300 }
$MeasureEntryLimit  = if ($env:PERMDEL_MEASURE_ENTRY_LIMIT){ [int]$env:PERMDEL_MEASURE_ENTRY_LIMIT} else { 20000 }
$DisplayLimit     = 500
$LogMaxBytes      = 2097152

$AutoAnswer = $env:PERMDEL_AUTOCONFIRM
$UseUI      = -not $AutoAnswer

$script:PDStats = @{}
$script:PDProg  = $null
$script:PDClock = $null
$script:PDMeasureCancel = $false       # 『统计实际大小』进行中：用户按了停止
$script:PDWantClose     = $false       # 统计期间用户按了取消 → 统计停下来后直接关框
$script:PDMeasuring     = $false       # 是否正在做完整统计（决定取消按钮的语义）
#endregion

#region ---------------- 日志 ----------------
function Write-PDLog {
    param([string]$Message)
    try {
        $dir = [System.IO.Path]::GetDirectoryName($LogFile)
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
        if ([System.IO.File]::Exists($LogFile)) {
            if ((New-Object System.IO.FileInfo $LogFile).Length -gt $LogMaxBytes) {
                $bak = $LogFile + '.1'
                if ([System.IO.File]::Exists($bak)) { [System.IO.File]::Delete($bak) }
                [System.IO.File]::Move($LogFile, $bak)
            }
        }
        $line = '{0}|{1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($LogFile, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

#endregion

#region ---------------- 路径规整 ----------------
function Get-SafePathList {
    param([string[]]$Raw)

    $kept     = New-Object System.Collections.Generic.List[string]
    $rejected = New-Object System.Collections.Generic.List[string]
    $seen     = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($r in $Raw) {
        if ([string]::IsNullOrEmpty($r)) { continue }
        $p = $r.Trim()

        # 去掉可能存在的一层引号
        if ($p.Length -ge 2 -and $p[0] -eq '"' -and $p[$p.Length - 1] -eq '"') {
            $p = $p.Substring(1, $p.Length - 2).Trim()
        }
        if ($p.Length -eq 0) { continue }

        # 去掉结尾分隔符（'C:\' 也会变成 'C:'，随后被盘根规则拒绝）
        while ($p.Length -gt 3 -and ($p[$p.Length - 1] -eq '\' -or $p[$p.Length - 1] -eq '/')) {
            $p = $p.Substring(0, $p.Length - 1)
        }

        # 只做字符串级规整：超长路径调用 Path::GetFullPath 在 PS 5.1 上会抛 PathTooLongException
        $rooted = $false
        try { $rooted = [System.IO.Path]::IsPathRooted($p) } catch { $rooted = $false }
        if (-not $rooted) { $rejected.Add($r.Trim()); continue }

        $full = $p
        if ($p -match '(^|\\)\.\.?(\\|$)') {          # 含 . / .. 才需要真正规整
            try { $full = [System.IO.Path]::GetFullPath($p) } catch { $rejected.Add($p); continue }
        }
        $full = $full.TrimEnd('\')

        if ($full -match '^[A-Za-z]:$') { $rejected.Add($full + '\'); continue }              # 盘根
        if ($full -match '^\\\\[^\\]+\\[^\\]+$') { $rejected.Add($full + '\'); continue }     # UNC 共享根
        if ($full.Length -lt 3) { $rejected.Add($p); continue }

        if ($seen.Add($full)) { $kept.Add($full) }
    }

    New-Object psobject -Property @{ Kept = $kept.ToArray(); Rejected = $rejected.ToArray() }
}

# 超长路径用 \\?\ 前缀交给 Unicode API（PowerShell 5.1 的 .NET 默认不支持 >260）
function Get-LongPath {
    param([string]$Path)
    if ($Path.Length -lt 240) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Test-PDExists {
    param([string]$Path)
    if (-not $Path) { return $false }
    try {
        $ext = Get-LongPath $Path
        return ([System.IO.File]::Exists($ext) -or [System.IO.Directory]::Exists($ext))
    } catch { return $false }
}

# Shell 通过动词调用时，%V 有可能不加引号，含空格的路径会被空格拆成多个参数。
# 例：C:\a\Vector Magic 1.15 中文版  →  C:\a\Vector | Magic | 1.15 | 中文版
# 这里只在"拼回来确实是一个存在的路径"时才合并，绝不凭空猜测。
function Merge-PDSplitArgs {
    param([string[]]$Raw)
    if (-not $Raw -or $Raw.Count -eq 0) { return @() }
    $out    = New-Object System.Collections.Generic.List[string]
    $merged = 0
    $n      = $Raw.Count
    $i      = 0
    while ($i -lt $n) {
        $cand = $Raw[$i]
        $next = $i + 1
        if (-not (Test-PDExists $cand)) {
            $acc   = $cand
            $limit = [Math]::Min($n, $i + 16)
            for ($j = $i + 1; $j -lt $limit; $j++) {
                $acc = $acc + ' ' + $Raw[$j]
                if (Test-PDExists $acc) { $cand = $acc; $next = $j + 1; $merged++; break }
            }
        }
        $out.Add($cand)
        $i = $next
    }
    if ($merged -gt 0) { Write-PDLog ("REJOIN merged=" + $merged + " raw=" + $n) }
    return $out.ToArray()
}

# 纯字符串取父目录 / 文件名：不用 .NET 路径 API，避免超长路径抛异常
function Get-PDParent {    param([string]$Path)
    $p = $Path.TrimEnd('\')
    $i = $p.LastIndexOf('\')
    if ($i -lt 0) { return $null }
    if ($i -eq 0) { return $null }
    return $p.Substring(0, $i)
}

function Get-PDName {
    param([string]$Path)
    $p = $Path.TrimEnd('\')
    $i = $p.LastIndexOf('\')
    if ($i -lt 0) { return $p }
    return $p.Substring($i + 1)
}

function Get-TopLevelPaths {
    param([string[]]$Items)
    $set  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($i in $Items) { [void]$set.Add($i) }

    $tops = New-Object System.Collections.Generic.List[string]
    foreach ($i in $Items) {
        $isChild = $false
        $parent  = Get-PDParent $i
        while ($parent) {
            if ($set.Contains($parent)) { $isChild = $true; break }
            $up = Get-PDParent $parent
            if (-not $up -or $up -eq $parent) { break }
            $parent = $up
        }
        if (-not $isChild) { $tops.Add($i) }
    }
    return $tops.ToArray()
}

#endregion

#region ---------------- 队列（跨实例合并） ----------------
function Add-PDQueueEntry {
    param([string[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return }
    if (-not [System.IO.Directory]::Exists($QueueDir)) { [void][System.IO.Directory]::CreateDirectory($QueueDir) }
    $id  = [Guid]::NewGuid().ToString('N')
    $tmp = Join-Path $QueueDir ($id + '.tmp')
    $dst = Join-Path $QueueDir ($id + '.arg')
    [System.IO.File]::WriteAllLines($tmp, [string[]]$Items, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Move($tmp, $dst)
}

function Clear-PDQueue {
    # 只有"刚抢到互斥体"的主实例可以调用：能抢到互斥体 ⇒ 当前没有活着的实例
    # ⇒ 队列里剩下的全是上一个已死实例的残留，直接清掉（绝不重放历史路径）。
    if (-not [System.IO.Directory]::Exists($QueueDir)) { return }
    foreach ($f in [System.IO.Directory]::GetFiles($QueueDir)) {
        try { [System.IO.File]::Delete($f) } catch { }
    }
}

function Wait-PDMergeWindow {
    <#
        自适应合并窗口：等"再也没有新实例进来"为止。
        - 起始等待 MergeWindowMs；每发现一个新的 .arg 条目，就把截止时间顺延 MergeWindowMs
        - 硬上限 MergeMaxMs，避免异常情况下无限等待
        - 只有"一次多选、项目还在陆续到达"（已收到 2 项以上 + 已等过 MergeFeedbackMs）
          才弹"正在汇总"的进度框；单次右键一律不弹窗，直接就出确认框
        - -Silent：一个窗口都不许弹（确认框关掉之后的收尾宽限用它 —— 用户刚点完取消，
          桌面上再跳一个空窗口是最讨嫌的）
        返回：{ Waited = 毫秒, Entries = 窗口结束时的条目数 }
    #>
    param([int]$BaseMs, [int]$MaxMs, [switch]$Silent)

    $sw       = [System.Diagnostics.Stopwatch]::StartNew()
    $deadline = $sw.ElapsedMilliseconds + $BaseMs
    $seen     = 0
    $uiShown  = $false
    if ([System.IO.Directory]::Exists($QueueDir)) {
        $seen = @([System.IO.Directory]::GetFiles($QueueDir, '*.arg')).Count
    }

    while ($true) {
        Start-Sleep -Milliseconds 100
        $cur = 0
        if ([System.IO.Directory]::Exists($QueueDir)) {
            $cur = @([System.IO.Directory]::GetFiles($QueueDir, '*.arg')).Count
        }
        $now = $sw.ElapsedMilliseconds
        if ($cur -gt $seen) {
            $seen     = $cur
            $deadline = $now + $BaseMs          # 有新请求进来 → 顺延
        }
        if (-not $Silent -and -not $uiShown -and $UseUI -and $seen -gt 1 -and $now -gt $MergeFeedbackMs) {
            Show-PDProgress -Total 0 -Text ('正在汇总选中的项目… 已收到 ' + $seen + ' 项')
            $uiShown = $true
            Write-PDLog ("MERGEUI shown seen=" + $seen + " at=" + $now + "ms")
        }
        if ($uiShown) { Step-PDProgress -Text ('正在汇总选中的项目… 已收到 ' + $seen + ' 项') }
        if ($now -ge $MaxMs) { break }
        if ($now -ge $deadline) { break }
    }

    if ($uiShown) { Hide-PDProgress }
    return @{ Waited = $sw.ElapsedMilliseconds; Entries = $seen }
}

function Read-PDQueueEntries {
    # 注意：这里刻意不看文件时间戳。确认框可能被用户开着好几分钟，
    # 期间新右键入队的条目时间戳会很旧，但它属于"活着的本主实例"，必须采纳。
    # 真正要防的残留由 Clear-PDQueue 在启动时处理。
    $all = New-Object System.Collections.Generic.List[string]
    if (-not [System.IO.Directory]::Exists($QueueDir)) { return @() }
    $now = Get-Date
    foreach ($f in [System.IO.Directory]::GetFiles($QueueDir)) {
        $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
        $age = 9999
        try { $age = ($now - [System.IO.File]::GetLastWriteTime($f)).TotalSeconds } catch { }
        try {
            if ($ext -eq '.arg') {
                foreach ($l in [System.IO.File]::ReadAllLines($f, [System.Text.Encoding]::UTF8)) {
                    if ($l -and $l.Trim()) { $all.Add($l.Trim()) }
                }
                [System.IO.File]::Delete($f)
            } elseif ($age -gt $QueueStaleSec) {
                [System.IO.File]::Delete($f)   # 写了一半就被杀掉的半成品
            }
        } catch { }
    }
    return $all.ToArray()
}

#endregion

#region ---------------- UI ----------------
function Get-PDFont {
    param([int]$Size = 9, [switch]$Monospace)
    $names = if ($Monospace) { @('Consolas', 'Courier New') } else { @('Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI') }
    foreach ($n in $names) {
        try {
            $f = New-Object System.Drawing.Font($n, $Size)
            if ($f.Name -eq $n) { return $f }
        } catch { }
    }
    return (New-Object System.Drawing.Font('Microsoft Sans Serif', $Size))
}

function Initialize-PDWinForms {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
}

# ---------------- 窗体可见性（关键）----------------
# 本进程是 VBS 用 WScript.Shell.Run(cmd, 0, False) 启动的，也就是以 SW_HIDE 创建进程
# （为了不闪黑窗口）。这种进程里 WinForms 的 Form.ShowDialog() 窗口会"继承隐藏"，
# 结果是：进程在模态循环里等，但用户看不到任何窗口 —— 表现为"右键没反应"。
# MessageBox 是系统对话框，不受影响（所以旧版本用 MessageBox 时是好的）。
# 对策：显示后显式 ShowWindow(SW_SHOW)，并用计时器看门狗复核；仍然不可见就退回 MessageBox。
if (-not ('PD.Win' -as [type])) {
    try {
        Add-Type -Namespace PD -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
    } catch { }
}

function Test-PDWinVisible {
    param($Handle)
    try {
        if (-not $Handle -or $Handle -eq [IntPtr]::Zero) { return $false }
        return [PD.Win]::IsWindowVisible([IntPtr]$Handle)
    } catch { return $false }
}

function Force-PDShowWindow {
    param($Form)
    try {
        $h = $Form.Handle
        if ($h -eq [IntPtr]::Zero) { return }
        if (-not [PD.Win]::IsWindowVisible($h)) {
            [void][PD.Win]::ShowWindow($h, 5)   # SW_SHOW
            [void][PD.Win]::ShowWindow($h, 9)   # SW_RESTORE
        }
        [void][PD.Win]::SetForegroundWindow($h)
    } catch { }
}

# 通用「摘要 + 可滚动列表」对话框；-Confirm 时返回用户是否点了确认
function Show-PDListDialog {
    param(
        [string]$Title,
        [string]$Summary,
        [string]$Warning,
        [string[]]$Items,
        [switch]$Confirm,
        [string]$OkText = '永久删除',
        [scriptblock]$MeasureAction = $null,     # 有则显示『统计实际大小』按钮；点它返回新的摘要文本
        [string]$MeasureButtonText = '统计实际大小(&M)'
    )

    if (-not $UseUI) {
        Write-PDLog ('DIALOG|' + $Title + '|' + ($Summary -replace '\r?\n', ' / '))
        return ($AutoAnswer -eq 'yes')
    }

    try {
        Initialize-PDWinForms

        $form = New-Object System.Windows.Forms.Form
        $form.Text            = $Title
        $form.ClientSize      = New-Object System.Drawing.Size(660, 470)
        $form.StartPosition   = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MinimizeBox     = $false
        $form.MaximizeBox     = $false
        $form.ShowInTaskbar   = $true
        $form.TopMost         = $true
        $form.Font            = Get-PDFont 9

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text     = $Summary
        $lbl.Location = New-Object System.Drawing.Point(14, 12)
        $lbl.Size     = New-Object System.Drawing.Size(632, 56)
        $form.Controls.Add($lbl)

        if ($Warning) {
            $lw = New-Object System.Windows.Forms.Label
            $lw.Text      = $Warning
            $lw.ForeColor = [System.Drawing.Color]::FromArgb(192, 0, 0)
            $lw.Location  = New-Object System.Drawing.Point(14, 66)
            $lw.Size      = New-Object System.Drawing.Size(632, 22)
            $form.Controls.Add($lw)
        }

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Multiline  = $true
        $txt.ReadOnly   = $true
        $txt.WordWrap   = $false
        $txt.ScrollBars = 'Both'
        $txt.BackColor  = [System.Drawing.Color]::White
        $txt.Location   = New-Object System.Drawing.Point(14, 92)
        $txt.Size       = New-Object System.Drawing.Size(632, 326)
        $txt.Font       = Get-PDFont 9 -Monospace
        $txt.Text       = ($Items -join "`r`n")
        $form.Controls.Add($txt)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text   = if ($Confirm) { '取消(&C)' } else { '关闭(&C)' }
        $btnCancel.Size   = New-Object System.Drawing.Size(130, 32)
        $btnCancel.Location = New-Object System.Drawing.Point(516, 428)
        $form.Controls.Add($btnCancel)
        $form.CancelButton = $btnCancel
        $form.AcceptButton = $btnCancel        # 回车 = 取消（安全默认）
        # 关键：这一句必须在 AcceptButton 赋值之后。表单给按钮设 DialogResult 时
        # 可能被改掉，若取消按钮自己带 OK 语义，"点取消"就变成"确认删除"——不可接受。
        # 所以这里强制 None，关框与否一律由下面 Add_Click 里的逻辑决定。
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::None

        $btnOk = $null
        if ($Confirm) {
            $btnOk = New-Object System.Windows.Forms.Button
            $btnOk.Text       = $OkText
            $btnOk.Size       = New-Object System.Drawing.Size(130, 32)
            $btnOk.Location   = New-Object System.Drawing.Point(376, 428)
            $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Controls.Add($btnOk)
        } else {
            $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }

        # 『统计实际大小』：只在自动统计没数全（Capped）时才由调用方传进来。
        # 点一下才做完整统计，期间泵消息保持窗口响应，并可以中途停止。
        $btnMeasure = $null
        if ($MeasureAction) {
            $script:PDMeasuring = $false
            $btnMeasure = New-Object System.Windows.Forms.Button
            $btnMeasure.Text     = $MeasureButtonText
            $btnMeasure.Size     = New-Object System.Drawing.Size(150, 32)
            $btnMeasure.Location = New-Object System.Drawing.Point(14, 428)
            $form.Controls.Add($btnMeasure)

            $btnMeasure.Add_Click({
                if ($script:PDMeasuring) { return }
                $script:PDMeasuring     = $true
                $script:PDMeasureCancel = $false
                $script:PDWantClose     = $false
                $btnMeasure.Enabled = $false
                if ($btnOk) { $btnOk.Enabled = $false }     # 统计期间不许确认
                $btnCancel.Text = '停止统计(&C)'
                $lbl.Text = '正在统计实际数量与大小…（大目录可能要几秒，可点『停止统计』）'
                $form.Refresh()
                [System.Windows.Forms.Application]::DoEvents()

                # 泵：让"统计中"的窗口保持响应；窗口被关掉也当作停止
                $pump = {
                    param($files, $dirs)
                    [System.Windows.Forms.Application]::DoEvents()
                    $lbl.Text = '正在统计实际数量与大小…  已数到 ' + $files + ' 个文件、' + $dirs + ' 个子文件夹'
                    if ($form.IsDisposed -or -not $form.Visible) { $script:PDMeasureCancel = $true }
                }

                $newSummary = $null
                try { $newSummary = & $MeasureAction $pump } catch { }

                if ($form.IsDisposed) { return }
                if ($script:PDWantClose) { $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $form.Close(); return }
                if ($newSummary) { $lbl.Text = $newSummary }
                if ($script:PDMeasureCancel -and -not $newSummary) { $lbl.Text = '统计已停止（显示的是未完整统计的结果）' }
                $script:PDMeasuring = $false
                $btnMeasure.Enabled = $true
                $btnMeasure.Text    = '重新统计(&M)'
                if ($btnOk) { $btnOk.Enabled = $true }
                $btnCancel.Text = if ($Confirm) { '取消(&C)' } else { '关闭(&C)' }
                $form.Refresh()
            })
        }

        # 取消按钮：正常情况直接关框；正在统计时先请求停止，统计退出后再关
        $btnCancel.Add_Click({
            if ($script:PDMeasuring) {
                $script:PDMeasureCancel = $true
                $script:PDWantClose     = $true
                return
            }
            if ($Confirm) { $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel }
            $form.Close()
        })

        $form.Add_Shown({ $btnCancel.Focus() })
        $form.Add_HandleCreated({ Force-PDShowWindow -Form $form })

        # 看门狗：每 200ms 复核窗口是否真的可见；1.6 秒还不可见就放弃自绘窗体，
        # 退回系统 MessageBox（它不受 SW_HIDE 影响），绝不留下"看不见的模态框"。
        $script:PDForceTicks = 0
        $script:PDFallback   = $false
        $watch = New-Object System.Windows.Forms.Timer
        $watch.Interval = 200
        $watch.Add_Tick({
            try {
                if (Test-PDWinVisible -Handle $form.Handle) {
                    Force-PDShowWindow -Form $form
                    $watch.Stop()
                    return
                }
                Force-PDShowWindow -Form $form
                $script:PDForceTicks++
                if ($script:PDForceTicks -ge 8) {
                    $script:PDFallback = $true
                    $watch.Stop()
                    $form.Close()
                }
            } catch { }
        })
        $watch.Start()
        $r = $form.ShowDialog()
        $watch.Stop()
        $watch.Dispose()
        $form.Dispose()

        if ($script:PDFallback) {
            Write-PDLog 'UI-FALLBACK|窗体不可见，改用 MessageBox'
            $lines = @($Items)
            if ($lines.Count -gt 12) {
                $lines = @($lines[0..11]) + @('…… 其余 ' + ($Items.Count - 12) + ' 项未列出（详见日志）')
            }
            $body = $Summary + "`r`n`r`n" + $Warning + "`r`n`r`n" + ($lines -join "`r`n")
            if (-not $Confirm) {
                [void][System.Windows.Forms.MessageBox]::Show($body, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return $false
            }
            $mr = [System.Windows.Forms.MessageBox]::Show($body, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            return ($mr -eq [System.Windows.Forms.DialogResult]::Yes)
        }

        return ($r -eq [System.Windows.Forms.DialogResult]::OK)
    } catch {
        Write-PDLog ('UI-FAIL|' + $_.Exception.Message)
        # 兜底：用 WScript.Shell 弹窗，默认取消（更安全）
        try {
            $sh   = New-Object -ComObject WScript.Shell
            $body = $Summary + "`n`n" + $Warning
            if (-not $Confirm) {
                [void]$sh.Popup($body, 0, $Title, 48)
                return $false
            }
            # 4=是/否 48=警告图标 256=默认第二个按钮(否) —— 破坏性操作默认取消
            $r = $sh.Popup($body, 0, $Title, 308)
            return ($r -eq 6)
        } catch { return $false }
    }
}

function Show-PDSimpleMessage {
    param([string]$Text, [string]$Title = '永久删除')
    if (-not $UseUI) { Write-PDLog ('MSG|' + ($Text -replace '\r?\n', ' / ')); return }
    try {
        Initialize-PDWinForms
        [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    } catch {
        try {
            $sh = New-Object -ComObject WScript.Shell
            [void]$sh.Popup($Text, 0, $Title, 48)
        } catch { }
    }
}

function Show-PDProgress {
    param([int]$Total = 0, [string]$Text = '正在删除…')
    if (-not $UseUI -or $script:PDProg) { return }
    try {
        Initialize-PDWinForms
        $f = New-Object System.Windows.Forms.Form
        $f.Text            = '永久删除'
        $f.ClientSize      = New-Object System.Drawing.Size(440, 96)
        $f.StartPosition   = 'CenterScreen'
        $f.FormBorderStyle = 'FixedToolWindow'
        $f.ControlBox      = $false
        $f.ShowInTaskbar   = $false
        $f.TopMost         = $true
        $f.Font            = Get-PDFont 9

        $l = New-Object System.Windows.Forms.Label
        $l.Location = New-Object System.Drawing.Point(12, 10)
        $l.Size     = New-Object System.Drawing.Size(416, 36)
        $l.Text     = $Text
        $f.Controls.Add($l)

        $b = New-Object System.Windows.Forms.ProgressBar
        $b.Location = New-Object System.Drawing.Point(12, 52)
        $b.Size     = New-Object System.Drawing.Size(416, 18)
        $b.Style    = 'Marquee'
        $b.MarqueeAnimationSpeed = 30
        $f.Controls.Add($b)

        $f.Add_HandleCreated({ Force-PDShowWindow -Form $f })
        $f.Show()
        Force-PDShowWindow -Form $f          # 同 SW_HIDE 问题：非模态窗体也要显式显示
        [System.Windows.Forms.Application]::DoEvents()
        $script:PDProg = @{ Form = $f; Label = $l; Total = $Total }
    } catch {
        $script:PDProg = $null
    }
}

function Step-PDProgress {
    param([string]$Text, [int]$Done = -1)
    if (-not $script:PDProg) { return }
    try {
        if ($Text) { $script:PDProg.Label.Text = $Text }
        elseif ($Done -ge 0) { $script:PDProg.Label.Text = "正在删除… $Done / $($script:PDProg.Total)" }
        $script:PDProg.Form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

function Hide-PDProgress {
    if ($script:PDProg) {
        try { $script:PDProg.Form.Close(); $script:PDProg.Form.Dispose() } catch { }
        $script:PDProg = $null
    }
}

# 删除过程中的消息泵：慢到 1.2 秒还没删完就自动把进度框弹出来
function Pump-PD {
    param([string]$Text)
    if (-not $UseUI) { return }
    if (-not $script:PDProg) {
        if (-not $script:PDClock) { return }
        if ($script:PDClock.ElapsedMilliseconds -lt 1200) { return }
        Show-PDProgress -Total 0 -Text '正在删除…'
        if (-not $script:PDProg) { return }
    }
    Step-PDProgress -Text $Text
}

#endregion

#region ---------------- 统计 ----------------
function Format-PDSize {
    param([long]$Bytes)
    if ($Bytes -ge 1073741824) { return ('{0:N2} GB' -f ($Bytes / 1073741824)) }
    if ($Bytes -ge 1048576)    { return ('{0:N2} MB' -f ($Bytes / 1048576)) }
    if ($Bytes -ge 1024)       { return ('{0:N1} KB' -f ($Bytes / 1024)) }
    return "$Bytes B"
}

# 统计数量与体积。**默认是"快速统计"**：有时间预算、顶层项数上限、条目数上限，
# 命中任何一个就停手并标 Capped —— 目的是让确认框尽快出现（大目录一次都不扫）。
# 需要精确数字时，由确认框上的『统计实际大小』按钮用 BudgetMs=0 / 上限=0 再算一遍。
function Measure-PDPaths {
    param(
        [string[]]$Items,
        [int]$BudgetMs = 700,
        [int]$ItemLimit = 0,          # 顶层项目数超过它就直接不扫；0 = 不限
        [int]$EntryLimit = 0,         # 扫到的文件+文件夹总数超过它就停；0 = 不限
        [scriptblock]$Pump = $null    # 每扫一小批调用一次，让"统计中"的窗口保持响应
    )

    $script:PDStats = @{}
    $totals = @{ Files = 0; Dirs = 0; Bytes = [long]0; Capped = $false; Reason = 'ok' }
    $clock  = [System.Diagnostics.Stopwatch]::StartNew()

    # 顶层项数就超限：连目录都不进，直接给每一项挂一个"未统计"的桩，
    # 这样删除阶段仍会走更稳的分片删除（与预算耗尽时的行为一致）。
    if ($ItemLimit -gt 0 -and $Items.Count -gt $ItemLimit) {
        foreach ($item in $Items) {
            $script:PDStats[$item] = @{ Files = 0; Dirs = 0; Bytes = [long]0; Capped = $true }
        }
        $totals.Capped = $true
        $totals.Reason = 'items'
        return $totals
    }

    foreach ($item in $Items) {
        $s = @{ Files = 0; Dirs = 0; Bytes = [long]0; Capped = $false }
        $itemExt   = Get-LongPath $item
        $isRootLink = $false
        try { $isRootLink = (([System.IO.File]::GetAttributes($itemExt)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } catch { }

        if ($isRootLink) {
            # 软链接/联接点本身：只算 1 项，不进目标目录统计（也不会去动目标数据）
            $s.Dirs = 1
        } elseif ([System.IO.Directory]::Exists($itemExt)) {
            $stack = New-Object 'System.Collections.Generic.Stack[string]'
            $stack.Push($item)
            $sincePump = 0
            while ($stack.Count -gt 0) {
                if ($BudgetMs -gt 0 -and $clock.ElapsedMilliseconds -gt $BudgetMs) {
                    $s.Capped = $true; $totals.Reason = 'budget'; break
                }
                $cur = $stack.Pop()
                $di  = $null
                try { $di = New-Object System.IO.DirectoryInfo (Get-LongPath $cur) } catch { continue }
                try {
                    foreach ($f in $di.EnumerateFiles()) {
                        $s.Files++
                        try { $s.Bytes += $f.Length } catch { }
                        if ($EntryLimit -gt 0 -and ($s.Files + $s.Dirs) -ge $EntryLimit) {
                            $s.Capped = $true; $totals.Reason = 'entries'; break
                        }
                    }
                } catch { }
                if ($s.Capped) { break }
                try {
                    foreach ($d in $di.EnumerateDirectories()) {
                        $s.Dirs++
                        $isLink = $false
                        try { $isLink = (($d.Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } catch { $isLink = $true }
                        if (-not $isLink) { $stack.Push($d.FullName) }
                        if ($EntryLimit -gt 0 -and ($s.Files + $s.Dirs) -ge $EntryLimit) {
                            $s.Capped = $true; $totals.Reason = 'entries'; break
                        }
                    }
                } catch { }
                if ($s.Capped) { break }

                # 长时间统计时保持窗口响应，并允许用户中途停止
                $sincePump++
                if ($Pump -and ($sincePump % 64) -eq 0) {
                    try { & $Pump $s.Files $s.Dirs } catch { }
                    if ($script:PDMeasureCancel) { $s.Capped = $true; $totals.Reason = 'cancelled'; break }
                }
            }
        } elseif ([System.IO.File]::Exists($itemExt)) {
            $s.Files = 1
            try { $s.Bytes = (New-Object System.IO.FileInfo $itemExt).Length } catch { }
        }

        $script:PDStats[$item] = $s
        $totals.Files += $s.Files
        $totals.Dirs  += $s.Dirs
        $totals.Bytes += $s.Bytes
        if ($s.Capped) { $totals.Capped = $true }
        if ($totals.Reason -eq 'cancelled') { break }
    }

    return $totals
}

# 把统计结果拼成给人看的一句话；Capped 时用"≥"并且说明可以点按钮精确统计
function Format-PDStatLine {
    param($Stat, [string]$Scope = '其中共')
    if (-not $Stat) { return '' }
    $approx = if ($Stat.Capped) { '≥' } else { '约' }
    $line = "$Scope $approx $($Stat.Files) 个文件、$($Stat.Dirs) 个子文件夹，合计 $approx $(Format-PDSize $Stat.Bytes)"
    if ($Stat.Capped) { $line = $line + '（未完整统计，可点『统计实际大小』）' }
    return $line
}

# 确认框顶部那段摘要（"即将永久删除 N 个项目 …… 合计多大"）
function Format-PDBatchSummary {
    param([string[]]$Live, $Stat, [int]$MissingCount = 0)

    $selFiles = 0
    $selDirs  = 0
    foreach ($lp in $Live) {
        if ([System.IO.Directory]::Exists((Get-LongPath $lp))) { $selDirs++ } else { $selFiles++ }
    }
    $selText = "$selFiles 个文件"
    if ($selDirs -gt 0) { $selText = "$selFiles 个文件 + $selDirs 个文件夹" }

    $text = "即将永久删除 $($Live.Count) 个项目（$selText）`r`n" + (Format-PDStatLine -Stat $Stat)
    if ($MissingCount -gt 0) { $text += "`r`n（其中 $MissingCount 项已不存在，将被跳过）" }
    return $text
}

#endregion

#region ---------------- 删除引擎 ----------------
function Remove-PDTree {
    <#
        兜底删除：自底向上遍历
        - 先清掉只读/隐藏/系统属性（原生递归删除遇到只读文件会直接失败）
        - 软链接/联接点只删链接本身，不递归进目标（防止误删指向的真实数据）
        - 支持超长路径
        - 过程中泵消息，窗口不会"无响应"
    #>
    param([string]$Root)

    $dirs = New-Object System.Collections.Generic.List[string]
    $errs = New-Object System.Collections.Generic.List[string]
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    $n = 0

    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $dirs.Add($cur)
        $dx  = Get-LongPath $cur
        try {
            $di = New-Object System.IO.DirectoryInfo $dx
            $files = @()
            try { $files = @($di.GetFiles()) } catch { $errs.Add("$cur :: 枚举失败 $($_.Exception.Message)") }
            foreach ($f in $files) {
                $fx = Get-LongPath $f.FullName
                try {
                    if ((($f.Attributes) -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                        [System.IO.File]::SetAttributes($fx, [System.IO.FileAttributes]::Normal)
                    }
                    [System.IO.File]::Delete($fx)
                } catch {
                    try {
                        [System.IO.File]::SetAttributes($fx, [System.IO.FileAttributes]::Normal)
                        [System.IO.File]::Delete($fx)
                    } catch { $errs.Add("$($f.FullName) :: $($_.Exception.Message)") }
                }
                $n++
                if (($n % 64) -eq 0) { Pump-PD -Text ('正在删除… ' + $f.Name) }
            }

            $subs = @()
            try { $subs = @($di.GetDirectories()) } catch { }
            foreach ($d in $subs) {
                $dxs    = Get-LongPath $d.FullName
                $isLink = $true
                try { $isLink = (($d.Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } catch { }
                if ($isLink) {
                    try { [System.IO.Directory]::Delete($dxs, $false) }
                    catch { $errs.Add("$($d.FullName) :: $($_.Exception.Message)") }
                } else {
                    $stack.Push($d.FullName)
                }
            }
        } catch {
            $errs.Add("$cur :: $($_.Exception.Message)")
        }
    }

    # 逆序 = 子目录一定排在父目录前面
    $arr = $dirs.ToArray()
    [Array]::Reverse($arr)
    foreach ($d in $arr) {
        $dx = Get-LongPath $d
        try {
            $a = [System.IO.File]::GetAttributes($dx)
            if (($a -band ([System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System)) -ne 0) {
                [System.IO.File]::SetAttributes($dx, [System.IO.FileAttributes]::Normal)
            }
        } catch { }
        try { [System.IO.Directory]::Delete($dx, $false) }
        catch { $errs.Add("$d :: $($_.Exception.Message)") }
        Pump-PD -Text ('正在删除… ' + (Get-PDName $d))
    }

    if ($errs.Count -gt 0) { throw ($errs -join ' ; ') }
}

# 大目录：逐个直接子项用原生递归删除（快），两次删除之间泵消息
function Remove-PDSharded {
    param([string]$Root)

    $dx = Get-LongPath $Root
    $di = New-Object System.IO.DirectoryInfo $dx
    $kids = @($di.GetFileSystemInfos())

    foreach ($k in $kids) {
        $kx      = Get-LongPath $k.FullName
        $isDir   = $k -is [System.IO.DirectoryInfo]
        $isLink  = $true
        try { $isLink = (($k.Attributes) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } catch { }

        if ($isLink) {
            if ($isDir) { [System.IO.Directory]::Delete($kx, $false) } else { [System.IO.File]::Delete($kx) }
        } elseif ($isDir) {
            try { [System.IO.Directory]::Delete($kx, $true) }
            catch { Remove-PDTree -Root $k.FullName }
        } else {
            try { [System.IO.File]::Delete($kx) }
            catch {
                [System.IO.File]::SetAttributes($kx, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($kx)
            }
        }
        Pump-PD -Text ('正在删除… ' + $k.Name)
    }

    [System.IO.Directory]::Delete($dx, $false)
}

function Remove-PDItem {
    param([string]$Path)

    $ext = Get-LongPath $Path
    try {
        # ---- 文件 ----
        if ([System.IO.File]::Exists($ext)) {
            try { [System.IO.File]::Delete($ext); return $null }
            catch {
                [System.IO.File]::SetAttributes($ext, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($ext)
                return $null
            }
        }

        if (-not [System.IO.Directory]::Exists($ext)) { return 'NE_MISSING' }

        # ---- 软链接 / 联接点：只删链接，绝不递归 ----
        $isLink = $false
        try { $isLink = (([System.IO.File]::GetAttributes($ext)) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } catch { }
        if ($isLink) {
            [System.IO.Directory]::Delete($ext, $false)
            return $null
        }

        # ---- 目录 ----
        $st  = $script:PDStats[$Path]
        $big = $false
        if ($st) { $big = ($st.Files -gt $BigFileThreshold) -or $st.Capped -or ($st.Bytes -gt 2147483648) }

        if ($big) {
            try { Remove-PDSharded -Root $Path; return $null }
            catch { $first = $_.Exception.Message }
            try { Remove-PDTree -Root $Path; return $null }
            catch { return ('sharded=[' + $first + '] tree=[' + $_.Exception.Message + ']') }
        }

        try { [System.IO.Directory]::Delete($ext, $true); return $null }
        catch { $first = $_.Exception.Message }
        try { Remove-PDTree -Root $Path; return $null }
        catch { return ('fast=[' + $first + '] tree=[' + $_.Exception.Message + ']') }
    } catch {
        return $_.Exception.Message
    }
}

#endregion

#region ---------------- 批处理 ----------------
function Invoke-PDBatch {
    param([string[]]$Targets)

    # 1) 折叠嵌套项
    $tops   = @(Get-TopLevelPaths -Items $Targets)
    $nested = $Targets.Count - $tops.Count
    if ($nested -gt 0) { Write-PDLog "NESTED collapsed=$nested" }

    # 2) 区分存在 / 已不存在
    $live    = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($p in $tops) {
        if ([System.IO.Directory]::Exists((Get-LongPath $p)) -or [System.IO.File]::Exists((Get-LongPath $p))) { $live.Add($p) }
        else { $missing.Add($p) }
    }

    if ($live.Count -eq 0) {
        Write-PDLog 'NOOP|全部路径已不存在'
        Show-PDSimpleMessage -Text ('选中的 ' + $tops.Count + ' 个项目都已不存在，无需删除。') -Title '永久删除'
        return
    }

    # 3) 快速统计（有时间预算 + 项数/条目数上限，绝不为了数字把确认框拖住）
    $stat = Measure-PDPaths -Items $live.ToArray() -BudgetMs $MeasureBudgetMs `
                            -ItemLimit $MeasureItemLimit -EntryLimit $MeasureEntryLimit
    if ($stat.Capped) {
        Write-PDLog ("MEASURE capped reason=" + $stat.Reason + " files=" + $stat.Files + " dirs=" + $stat.Dirs + " budget=" + $MeasureBudgetMs + "ms")
    }

    # 4) 确认（一个批次只弹一次）
    $shown = if ($live.Count -gt $DisplayLimit) { $live.ToArray()[0..($DisplayLimit - 1)] } else { $live.ToArray() }
    $list  = New-Object System.Collections.Generic.List[string]
    foreach ($s in $shown) { $list.Add($s) }
    if ($live.Count -gt $DisplayLimit) { $list.Add("…… 其余 " + ($live.Count - $DisplayLimit) + " 项未列出") }

    $summary = Format-PDBatchSummary -Live $live.ToArray() -Stat $stat -MissingCount $missing.Count

    # 自动统计没数全时，框上给一个『统计实际大小』按钮：点它才做完整统计
    $measureAction = $null
    if ($stat.Capped) {
        $measureAction = {
            param($pump)
            $full = Measure-PDPaths -Items $live.ToArray() -BudgetMs 0 -ItemLimit 0 -EntryLimit 0 -Pump $pump
            if ($script:PDMeasureCancel) { $full.Capped = $true }   # 中途停止：只报已数到的部分
            Write-PDLog ("MEASURE full files=" + $full.Files + " dirs=" + $full.Dirs + " bytes=" + $full.Bytes + " cancelled=" + $script:PDMeasureCancel)
            return (Format-PDBatchSummary -Live $live.ToArray() -Stat $full -MissingCount 0)
        }
    }

    $ok = Show-PDListDialog -Title '永久删除（不进回收站）' -Summary $summary -Warning '此操作不经过回收站，删除后无法恢复！' -Items $list.ToArray() -Confirm -OkText '永久删除' -MeasureAction $measureAction
    $answer = 'no'
    if ($ok) { $answer = 'yes' }
    Write-PDLog ("CONFIRM " + $answer + " n=" + $live.Count + " files=" + $stat.Files + " bytes=" + $stat.Bytes)
    if (-not $ok) { return }

    # 5) 删除
    $errors   = New-Object System.Collections.Generic.List[string]
    $elapsedMs = 0
    $script:PDClock = [System.Diagnostics.Stopwatch]::StartNew()
    if ($UseUI -and ($live.Count -gt 20 -or $stat.Files -gt 300 -or $stat.Bytes -gt 209715200)) {
        Show-PDProgress -Total $live.Count -Text '正在删除…'
    }
    try {
        for ($i = 0; $i -lt $live.Count; $i++) {
            $p = $live[$i]
            if ($script:PDProg) { Step-PDProgress -Done ($i + 1) }
            $err = Remove-PDItem -Path $p
            if ($err -eq 'NE_MISSING') {
                Write-PDLog "SKIP-MISSING $p"
            } elseif ($err) {
                $errors.Add("$p`r`n    → $err")
                Write-PDLog "FAILED $p :: $err"
            } else {
                Write-PDLog "DELETED $p"
            }
            Pump-PD -Text ('正在删除… ' + ($i + 1) + ' / ' + $live.Count)
        }
        if ($script:PDClock) { $elapsedMs = $script:PDClock.ElapsedMilliseconds }
    } finally {
        Hide-PDProgress
        $script:PDClock = $null
    }

    if ($errors.Count -gt 0) {
        Write-PDLog ("DONE|failed=" + $errors.Count + " skipped=" + $missing.Count + " elapsed=" + $elapsedMs + "ms")
        Show-PDListDialog -Title '永久删除 — 部分失败' -Summary ("有 " + $errors.Count + " 项删除失败，其余已删除。`r`n详细日志：" + $LogFile) -Warning '失败原因通常是被占用、权限不足或正在被程序使用。' -Items $errors.ToArray()
        exit 1
    }
    Write-PDLog ("DONE|ok=" + $live.Count + " elapsed=" + $elapsedMs + "ms")
}

#endregion

#region ---------------- 主流程 ----------------
try {
    # 命令行过长时由 VBS 通过文件传参。
    # 只接受我们自己生成的 %TEMP%\permdelete_args_*.pdl；其它任何东西都不读也不删，
    # 绝不把用户选中的普通文件当成参数文件（这正是之前"单文件不弹框直接删"的根因）。
    if ($ArgsFile) {
        $afName  = Get-PDName $ArgsFile
        $afDir   = Get-PDParent $ArgsFile
        $tempDir = $env:TEMP
        if ($tempDir) { $tempDir = $tempDir.TrimEnd('\') }
        $okFile  = ($afName -like 'permdelete_args_*.pdl') -and $afDir -and $tempDir -and ($afDir.TrimEnd('\') -ieq $tempDir)
        if ($okFile -and [System.IO.File]::Exists($ArgsFile)) {
            try {
                $lines = [System.IO.File]::ReadAllLines($ArgsFile, [System.Text.Encoding]::Unicode)
                if ($lines.Count -gt 0) { $Paths = @($lines) }
                Write-PDLog ("ARGSFILE read=" + $lines.Count)
            } catch { Write-PDLog ('ARGSFILE read-fail ' + $_.Exception.Message) }
            try { [System.IO.File]::Delete($ArgsFile) } catch { }
        } else {
            Write-PDLog ('ARGSFILE ignored=' + $ArgsFile)
        }
    }

    # Shell 可能把含空格的路径按空格拆成多个参数，先尝试拼回真实存在的路径
    $Paths = @(Merge-PDSplitArgs -Raw @($Paths))

    $norm  = Get-SafePathList -Raw @($Paths)
    $mine  = @($norm.Kept)
    $rej   = @($norm.Rejected)

    foreach ($r in $rej) { Write-PDLog "REJECT $r" }

    if ($mine.Count -eq 0) {
        $rawDump = (@($Paths) | Where-Object { $_ }) -join ' | '
        if ($rawDump.Length -gt 400) { $rawDump = $rawDump.Substring(0, 400) + '…' }
        Write-PDLog ('NOOP|无有效路径|rawargc=' + @($Paths).Count + '|raw=' + $rawDump)
        if ($rej.Count -gt 0) {
            Show-PDSimpleMessage -Text ("没有可删除的有效路径（已拒绝 " + $rej.Count + " 项：盘根、共享根或无效路径）。") -Title '永久删除'
        }
        exit 0
    }

    Write-PDLog ("START n=" + $mine.Count)

    # 单实例选主：只有主实例弹框，其余把自己的路径塞进队列就退出
    $mutex     = New-Object System.Threading.Mutex($false, $MutexName)
    $isPrimary = $false
    try { $isPrimary = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $isPrimary = $true }

    if (-not $isPrimary) {
        Add-PDQueueEntry -Items $mine
        Write-PDLog ("HANDOFF n=" + $mine.Count)
        exit 0
    }

    # 我是主实例：先把上一个已死实例的残留清掉，再写自己的条目。
    # 这样"队列里出现的条目"必然属于当前这个活实例，可以无条件采纳（不看时间戳）。
    Clear-PDQueue

    Write-PDLog ("PRIMARY window=" + $MergeWindowMs + "ms max=" + $MergeMaxMs + "ms n=" + $mine.Count)

    try {
        $round = 0
        while ($true) {
            $round++
            if ($round -eq 1) {
                Add-PDQueueEntry -Items $mine     # 先入队，再等合并窗口
                # 自适应窗口：Shell 把一次多选拆成很多次调用时，等它们到齐再弹框
                $win = Wait-PDMergeWindow -BaseMs $MergeWindowMs -MaxMs $MergeMaxMs
            } else {
                # 上一批已经处理完（用户在确认框上点了确定或取消）。
                # 这里只做一小段**静默**收尾等待，绝不弹窗口：老实现会把整个合并窗口
                # 再走一遍（而且在 300ms 处冒出"正在汇总选中的项目…"），于是用户刚点完
                # 取消，桌面上又跳出一个框 —— 用户明确反馈过这个。
                $win = Wait-PDMergeWindow -BaseMs $PostBatchGraceMs -MaxMs $PostBatchGraceMs -Silent
            }
            Write-PDLog ("WINDOW round=" + $round + " waited=" + $win.Waited + "ms entries=" + $win.Entries)

            $batch = @(Read-PDQueueEntries)
            if ($batch.Count -eq 0) { break }     # 弹框期间没有新请求 → 收工

            $bn   = Get-SafePathList -Raw $batch
            $bt   = @($bn.Kept)
            if ($bt.Count -eq 0) { continue }

            Write-PDLog ("BATCH n=" + $bt.Count + " raw=" + $batch.Count)
            Invoke-PDBatch -Targets $bt
        }
    } finally {
        try { [void]$mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
    }

    exit 0
} catch {
    Write-PDLog ('FATAL|' + $_.Exception.Message + '|' + $_.ScriptStackTrace)
    Show-PDSimpleMessage -Text ("永久删除脚本出错：`r`n" + $_.Exception.Message + "`r`n`r`n日志：" + $LogFile) -Title '永久删除 — 错误'
    exit 1
}
#endregion
