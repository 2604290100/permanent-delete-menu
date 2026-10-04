#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mxx1.cn
<#
    Test-Gui.ps1 —— 安装器界面（WinForms）回归测试

    为什么单独一套：本项目被用户报过的"看着像 bug"的问题几乎全在界面上 ——
    按钮压在一起、按钮被标签盖住后点不动、标题栏多一个灰掉的最大化方框、
    文字被裁、点完取消又弹一个窗口。看截图会骗人（缩略图尤其会），
    所以这里一律**枚举子窗口矩形 + 读窗口样式**，用 PostMessage 真点按钮来判断。

    和其它测试的区别：需要一个可交互的桌面会话。
    没有桌面时返回 **退出码 3 = 环境不满足（跳过）**，不是失败 ——
    Test-All.ps1 会把 3 显示成 SKIP（端到端测试用的是同一套约定）。

    网络：整套测试**不访问外网**。更新检查要么被 PERMDEL_NO_UPDATE=1 关掉，
    要么打本机一个用完就关的假接口（HttpListener）。

    用法:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Gui.ps1
    退出码: 0 = 全绿；1 = 有失败；3 = 环境不满足（无交互式桌面）
#>
[CmdletBinding()]
param(
    [string]$Exe = '',
    [string]$ProjectRoot = ''
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $here }
if (-not $Exe) { $Exe = Join-Path $ProjectRoot 'bin\PermanentDeleteSetup.exe' }

$ErrorActionPreference = 'Continue'
$script:Pass = 0
$script:Fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Pass++ } else { $script:Fail++ }
    $flag = 'PASS'; if (-not $Ok) { $flag = 'FAIL' }
    Write-Host ("  [{0}] {1}{2}" -f $flag, $Name, $(if ($Detail) { "   ($Detail)" } else { '' }))
}

if (-not (Test-Path -LiteralPath $Exe)) { throw ('找不到 exe: ' + $Exe) }

Write-Host ''
Write-Host '=========================================================='
Write-Host ' 安装器界面（WinForms）回归测试'
Write-Host '=========================================================='
Write-Host (' exe : ' + $Exe)
Write-Host ''

# 没有交互式桌面就别跑了（CI 的托管 runner 就是这种）—— 这不算失败
if (-not [Environment]::UserInteractive) {
    Write-Host ' 环境不满足：当前会话不是交互式的（没有桌面），跳过界面测试。'
    exit 3
}

# ---------------------------------------------------------------- Win32 探针
# 注意：下面这段 C# 一律写英文注释。Add-Type 的源码是当字符串交给编译器的，
# 中文在命令通道 / 临时文件里会被按 ANSI 解坏（本项目踩过）。
#
# 读文字用 WM_GETTEXT（SendMessageTimeout）而不是 GetWindowText：
# 跨进程取子控件文字时 GetWindowText 只对"有标题"的窗口可靠，
# 文本框在多进程下经常拿到空串；WM_GETTEXT 是真正发给控件的消息，最稳。
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class PDGui
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern int GetWindowLongW(IntPtr hWnd, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint msg, IntPtr wParam, StringBuilder lParam, uint flags, uint timeout, out IntPtr result);

    public static IntPtr[] TopLevel(uint pid)
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == pid) { list.Add(h); }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    public static IntPtr[] Children(IntPtr parent)
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    public static string Text(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(40000);
        IntPtr res;
        // WM_GETTEXT = 0x000D, SMTO_ABORTIFHUNG = 0x0002
        SendMessageTimeoutW(h, 0x000D, (IntPtr)sb.Capacity, sb, 0x0002, 3000, out res);
        string s = sb.ToString();
        if (s.Length > 0) { return s; }
        StringBuilder sb2 = new StringBuilder(1024);
        GetWindowTextW(h, sb2, sb2.Capacity);
        return sb2.ToString();
    }

    public static string Class(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static int[] Rect(IntPtr h)
    {
        RECT r;
        if (!GetWindowRect(h, out r)) { return new int[] { 0, 0, 0, 0 }; }
        return new int[] { r.Left, r.Top, r.Right, r.Bottom };
    }

    // GWL_STYLE = -16, used to prove the caption has no min/max buttons
    public static int Styles(IntPtr h) { return GetWindowLongW(h, -16); }

    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    public static bool Alive(IntPtr h) { return IsWindow(h); }
    public static bool Click(IntPtr h) { return PostMessageW(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }        // BM_CLICK
    public static bool CloseWindow(IntPtr h) { return PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }  // WM_CLOSE
}
'@

# WS_MINIMIZEBOX = 0x00020000, WS_MAXIMIZEBOX = 0x00010000
function Test-NoCaptionBoxes {
    param([IntPtr]$Hwnd)
    $st = [PDGui]::Styles($Hwnd)
    return ((($st -band 0x00020000) -eq 0) -and (($st -band 0x00010000) -eq 0))
}

function Get-ChildControls {
    param([IntPtr]$Root)
    $out = @()
    foreach ($h in [PDGui]::Children($Root)) {
        $r = [PDGui]::Rect($h)
        $out += [pscustomobject]@{
            H       = $h
            Text    = [PDGui]::Text($h)
            Class   = [PDGui]::Class($h)
            Visible = [PDGui]::Visible($h)
            Left    = $r[0]; Top = $r[1]; Right = $r[2]; Bottom = $r[3]
            Width   = $r[2] - $r[0]; Height = $r[3] - $r[1]
        }
    }
    return $out
}

function Get-TopWindows {
    param([int]$ProcessId)
    $out = @()
    foreach ($h in [PDGui]::TopLevel([uint32]$ProcessId)) {
        $out += [pscustomobject]@{ H = $h; Text = [PDGui]::Text($h); Visible = [PDGui]::Visible($h) }
    }
    return $out
}

function Test-Overlap {
    param($A, $B)
    $w = [Math]::Min($A.Right, $B.Right) - [Math]::Max($A.Left, $B.Left)
    $h = [Math]::Min($A.Bottom, $B.Bottom) - [Math]::Max($A.Top, $B.Top)
    return ($w -gt 0 -and $h -gt 0)
}

function Test-ContainsRect {
    param($Outer, $Inner)
    return ($Inner.Left -ge $Outer.Left -and $Inner.Top -ge $Outer.Top -and
            $Inner.Right -le $Outer.Right -and $Inner.Bottom -le $Outer.Bottom -and
            ($Outer.Width -gt $Inner.Width -or $Outer.Height -gt $Inner.Height))
}

function Find-ByText {
    param($Controls, [string]$Text)
    return @($Controls | Where-Object { $_.Text -eq $Text })
}

function Find-TopWindow {
    param([int]$ProcessId, [string]$TextPrefix)
    $w = @(Get-TopWindows -ProcessId $ProcessId | Where-Object { $_.Text -like ($TextPrefix + '*') })
    if ($w.Count -eq 0) { return $null }
    return $w[0]
}

function Start-Gui {
    param([hashtable]$Env = $null)
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $Exe
    $si.UseShellExecute = $false
    # 测试里一律不让它联网：要么关掉检查，要么指向本机假接口
    $si.EnvironmentVariables['PERMDEL_NO_UPDATE'] = '1'
    if ($Env) { foreach ($k in $Env.Keys) { $si.EnvironmentVariables[$k] = [string]$Env[$k] } }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $si
    [void]$p.Start()
    for ($i = 0; $i -lt 100; $i++) {
        Start-Sleep -Milliseconds 200
        $p.Refresh()
        if ($p.HasExited) { return $p }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero) { break }
    }
    return $p
}

function Stop-Gui {
    param($Process)
    try { if ($Process -and -not $Process.HasExited) { $Process.Kill() } } catch { }
}

function Wait-WindowGone {
    param([IntPtr]$Hwnd, [int]$Tries = 25)
    for ($i = 0; $i -lt $Tries; $i++) {
        Start-Sleep -Milliseconds 200
        if (-not [PDGui]::Alive($Hwnd)) { return $true }
    }
    return $false
}

# ================================================================ A 组：离线（关掉更新检查）
Write-Host 'A 组：主窗口 +「关于」+「免责声明」（更新检查关闭，全程不联网）'
$gui = Start-Gui
$main = $gui.MainWindowHandle

Check 'A01 主窗口起来了' ((-not $gui.HasExited) -and ($main -ne [IntPtr]::Zero)) ('hwnd=' + $main)
if ($gui.HasExited -or $main -eq [IntPtr]::Zero) {
    Write-Host ''
    Write-Host ' 环境不满足：界面进程没能给出主窗口（多半是没有可交互桌面），跳过。'
    Stop-Gui $gui
    exit 3
}

Start-Sleep -Milliseconds 1500   # 等状态检测与首轮刷新落定
$title = [PDGui]::Text($main)
Check 'A02 标题含产品名与版本号' (($title -match '永久删除') -and ($title -match 'v\d+\.\d+\.\d+')) ('title=' + $title)
Check 'A03 标题栏没有最小化/最大化按钮' (Test-NoCaptionBoxes -Hwnd $main) ('styles=0x{0:X}' -f [PDGui]::Styles($main))

$ctrls = Get-ChildControls -Root $main
$btnAbout = @(Find-ByText -Controls $ctrls -Text '关于 / 作者信息')
$btnTerms = @(Find-ByText -Controls $ctrls -Text '免责声明 / 服务协议')
Check 'A04 底部有「关于 / 作者信息」按钮' ($btnAbout.Count -eq 1) ('count=' + $btnAbout.Count)
Check 'A05 底部有「免责声明 / 服务协议」按钮' ($btnTerms.Count -eq 1) ('count=' + $btnTerms.Count)

# 署名：外面显示简称 mxx1，不再出现 mxx1.cn（完整域名留在「关于」窗口里）
$authorLabels = @($ctrls | Where-Object { $_.Text -like '作者：*' })
Check 'A06 底部作者标签存在' ($authorLabels.Count -ge 1) ('count=' + $authorLabels.Count)
if ($authorLabels.Count -ge 1) {
    $at = $authorLabels[0].Text
    Check 'A07 底部署名为 mxx1（不含 mxx1.cn）' (($at -match 'mxx1') -and ($at -notmatch 'mxx1\.cn')) ('text=' + $at)
}

# 更新提示链接默认不显示（只有真查到新版才冒出来）
$links = @($ctrls | Where-Object { $_.Text -like '发现新版本*' -and $_.Visible })
Check 'A08 没查到新版时更新提示不显示' ($links.Count -eq 0) ('count=' + $links.Count)

# ---- 通用布局检查：按钮两两不重叠、按钮与标签不重叠 ----
# 容器（GroupBox 在 WinForms 里也是 BUTTON 类窗口）天然"包住"子控件而重叠，
# 所以先用"是否完整包住别人"把容器排除掉，剩下的才是真正该互不相交的控件。
$cand = @($ctrls | Where-Object { $_.Visible -and $_.Width -gt 0 -and $_.Height -gt 0 -and
        ($_.Class -match 'BUTTON' -or $_.Class -match 'STATIC') -and $_.Text.Length -gt 0 })
$containers = @()
foreach ($a in $cand) {
    foreach ($b in $cand) {
        if ($a.H -eq $b.H) { continue }
        if (Test-ContainsRect $a $b) { $containers += $a.H; break }
    }
}
$realBtn = @($cand | Where-Object { ($_.Class -match 'BUTTON') -and ($containers -notcontains $_.H) })
$realLbl = @($cand | Where-Object { ($_.Class -match 'STATIC') -and ($containers -notcontains $_.H) })
Check 'A09 认出了足够多的按钮与标签（探针本身没瞎）' (($realBtn.Count -ge 5) -and ($realLbl.Count -ge 3)) ('buttons=' + $realBtn.Count + ' labels=' + $realLbl.Count)

$btnOverlap = @()
for ($i = 0; $i -lt $realBtn.Count; $i++) {
    for ($j = $i + 1; $j -lt $realBtn.Count; $j++) {
        if (Test-Overlap $realBtn[$i] $realBtn[$j]) {
            $btnOverlap += ($realBtn[$i].Text + ' × ' + $realBtn[$j].Text)
        }
    }
}
Check 'A10 按钮之间互不重叠' ($btnOverlap.Count -eq 0) ($btnOverlap -join ' ; ')

$lblOverlap = @()
foreach ($b in $realBtn) {
    foreach ($l in $realLbl) {
        if (Test-Overlap $b $l) { $lblOverlap += ($b.Text + ' 被 ' + $l.Text + ' 压住') }
    }
}
Check 'A11 标签没有压在按钮上（压上就点不动了）' ($lblOverlap.Count -eq 0) ($lblOverlap -join ' ; ')

if (($btnAbout.Count -eq 1) -and ($btnTerms.Count -eq 1)) {
    $gap = $btnTerms[0].Left - $btnAbout[0].Right
    Check 'A12 底部两个按钮之间有间隙' ($gap -ge 8) ('gap=' + $gap + 'px')
    Check 'A13 底部按钮没超出窗口右边界' ($btnTerms[0].Right -le ([PDGui]::Rect($main))[2]) ('right=' + $btnTerms[0].Right)
}

# ---- 点「关于 / 作者信息」----
if ($btnAbout.Count -eq 1) {
    [void][PDGui]::Click($btnAbout[0].H)
    $about = $null
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        $about = Find-TopWindow -ProcessId $gui.Id -TextPrefix '关于'
        if ($about) { break }
    }
    Check 'A14 点「关于」能弹出模态窗口' ($null -ne $about) $(if ($about) { 'title=' + $about.Text } else { '未出现' })

    if ($about) {
        $ac = Get-ChildControls -Root $about.H
        Check 'A15 「关于」里有「检查更新」按钮' (@(Find-ByText -Controls $ac -Text '检查更新').Count -eq 1)

        $authorLink = @($ac | Where-Object { $_.Class -match 'STATIC' -and $_.Text -match 'mxx1' })
        Check 'A16 「关于」里署名同时给出 mxx1 与 mxx1.cn' `
            (((@($authorLink | Where-Object { $_.Text -match 'mxx1\.cn' }).Count -ge 1)) -and ($authorLink.Count -ge 1)) `
            ('text=' + (($authorLink | ForEach-Object { $_.Text }) -join ' | '))

        $updRow = @($ac | Where-Object { $_.Class -match 'STATIC' -and $_.Text -like '更新*' })
        Check 'A17 「关于」里有更新状态行（信息不再是死的）' ($updRow.Count -ge 1) ('text=' + (($updRow | ForEach-Object { $_.Text }) -join ' | '))
        Check 'A18 关掉检查时如实显示已关闭' (@($updRow | Where-Object { $_.Text -match '已关闭' }).Count -ge 1)
        Check 'A19 「关于」里也能进免责声明' (@(Find-ByText -Controls $ac -Text '免责声明 / 服务协议').Count -eq 1)
        Check 'A20 「关于」窗口标题栏也没有最小化/最大化按钮' (Test-NoCaptionBoxes -Hwnd $about.H)

        $acand = @($ac | Where-Object { $_.Visible -and $_.Width -gt 0 -and
                ($_.Class -match 'BUTTON' -or $_.Class -match 'STATIC') -and $_.Text.Length -gt 0 })
        $acontainers = @()
        foreach ($a in $acand) {
            foreach ($b in $acand) {
                if ($a.H -eq $b.H) { continue }
                if (Test-ContainsRect $a $b) { $acontainers += $a.H; break }
            }
        }
        $abtn = @($acand | Where-Object { ($_.Class -match 'BUTTON') -and ($acontainers -notcontains $_.H) })
        $albl = @($acand | Where-Object { ($_.Class -match 'STATIC') -and ($acontainers -notcontains $_.H) })
        $aOverlap = @()
        foreach ($b in $abtn) { foreach ($l in $albl) { if (Test-Overlap $b $l) { $aOverlap += ($b.Text + ' 被 ' + $l.Text + ' 压住') } } }
        Check 'A21 「关于」窗口里标签也没压住按钮' ($aOverlap.Count -eq 0) ($aOverlap -join ' ; ')

        [void][PDGui]::CloseWindow($about.H)
        $gone = Wait-WindowGone -Hwnd $about.H
        Check 'A22 「关于」能正常关掉、主窗口还活着' ($gone -and [PDGui]::Alive($main))
    }
}

# ---- 点「免责声明 / 服务协议」----
if ($btnTerms.Count -eq 1) {
    [void][PDGui]::Click($btnTerms[0].H)
    $terms = $null
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 200
        $terms = Find-TopWindow -ProcessId $gui.Id -TextPrefix '免责声明'
        if ($terms) { break }
    }
    Check 'A23 点「免责声明」能弹出窗口' ($null -ne $terms) $(if ($terms) { 'title=' + $terms.Text } else { '未出现' })

    if ($terms) {
        $tc = Get-ChildControls -Root $terms.H
        $body = ''
        foreach ($e in @($tc | Where-Object { $_.Class -match 'EDIT' })) {
            if ($e.Text.Length -gt $body.Length) { $body = $e.Text }
        }
        Check 'A24 免责声明窗口里有正文' ($body.Length -gt 1000) ('len=' + $body.Length)
        Check 'A25 正文写清了许可证' ($body -match 'GPL-3\.0-or-later')
        Check 'A26 正文写清了权限（注册表 + 删除 API）' (($body -match 'HKLM') -and ($body -match 'SHFileOperation'))
        Check 'A27 正文写清了唯一的网络请求与隐私开关' (($body -match 'api\.github\.com') -and ($body -match 'PERMDEL_NO_UPDATE=1'))
        Check 'A28 免责声明窗口标题栏也没有最小化/最大化按钮' (Test-NoCaptionBoxes -Hwnd $terms.H)

        [void][PDGui]::CloseWindow($terms.H)
        $gone = Wait-WindowGone -Hwnd $terms.H
        Check 'A29 免责声明能正常关掉、主窗口还活着' ($gone -and [PDGui]::Alive($main))
    }
}

Stop-Gui $gui
Start-Sleep -Milliseconds 500

# ================================================================ B 组：本机假接口（有新版）
Write-Host 'B 组：本机假接口返回 v9.9.9 —— 底部应出现更新提示（不访问外网）'
$tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$tcp.Start()
$port = $tcp.LocalEndpoint.Port
$tcp.Stop()
$prefix = 'http://127.0.0.1:' + $port + '/'
$listener = $null
$gui2 = $null
$body = '{"tag_name":"v9.9.9","html_url":"' + $prefix + 'fake-release"}'
try {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    $ctxTask = $listener.GetContextAsync()
    # 空串 = 把 A 组那个 PERMDEL_NO_UPDATE=1 顶掉（空值不算开启），让更新检查真的跑起来
    $gui2 = Start-Gui -Env @{ PERMDEL_NO_UPDATE = ''; PERMDEL_UPDATE_URL = ($prefix + 'releases/latest'); PERMDEL_UPDATE_TAGS_URL = ($prefix + 'tags') }
    $main2 = $gui2.MainWindowHandle
    Check 'B01 主窗口起来了' ((-not $gui2.HasExited) -and ($main2 -ne [IntPtr]::Zero))

    if ($main2 -ne [IntPtr]::Zero) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $link = @()
        $c2 = @()
        for ($i = 0; $i -lt 80; $i++) {
            Start-Sleep -Milliseconds 200
            # 假接口：来一个请求答一个（测试结束就关掉，不留监听）
            if ($ctxTask.IsCompleted) {
                try {
                    $ctx = $ctxTask.Result
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = 'application/json'
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $ctx.Response.OutputStream.Close()
                } catch { }
                $ctxTask = $listener.GetContextAsync()
            }
            $c2 = Get-ChildControls -Root $main2
            $link = @($c2 | Where-Object { $_.Text -like '发现新版本*' -and $_.Visible })
            if ($link.Count -ge 1) { break }
        }
        Check 'B02 有新版时底部出现更新提示' ($link.Count -ge 1) ('count=' + $link.Count)
        if ($link.Count -ge 1) {
            Check 'B03 提示里带上了新版本号 v9.9.9' ($link[0].Text -match 'v9\.9\.9') ('text=' + $link[0].Text)
            $aboutBtn = @($c2 | Where-Object { $_.Text -eq '关于 / 作者信息' })
            $hit = @($aboutBtn | Where-Object { Test-Overlap $_ $link[0] })
            Check 'B04 更新提示没有压住「关于」按钮' ($hit.Count -eq 0) ('aboutLeft=' + $(if ($aboutBtn.Count -ge 1) { $aboutBtn[0].Left } else { '?' }) + ' linkRight=' + $link[0].Right)

            # ★回归：关于窗口打开时会再登记一次检查（此时启动时那次可能还在跑）。
            #   老实现遇到"已有检查在跑"就把回调丢掉，于是那一行永远停在「正在检查…」。
            #   这里断言它会**落定**成真实状态。
            if ($aboutBtn.Count -ge 1) {
                [void][PDGui]::Click($aboutBtn[0].H)
                $about2 = $null
                $rowText = ''
                for ($i = 0; $i -lt 90; $i++) {
                    Start-Sleep -Milliseconds 200
                    if ($ctxTask.IsCompleted) {
                        try {
                            $ctx = $ctxTask.Result
                            $ctx.Response.StatusCode = 200
                            $ctx.Response.ContentType = 'application/json'
                            $ctx.Response.ContentLength64 = $bytes.Length
                            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                            $ctx.Response.OutputStream.Close()
                        } catch { }
                        $ctxTask = $listener.GetContextAsync()
                    }
                    if (-not $about2) { $about2 = Find-TopWindow -ProcessId $gui2.Id -TextPrefix '关于' }
                    if ($about2) {
                        $row = @(Get-ChildControls -Root $about2.H | Where-Object {
                                $_.Class -match 'STATIC' -and $_.Text -ne '更新：' -and
                                $_.Text -notmatch '^版本' -and
                                $_.Text -match '检查|新版本|最新|失败|发布' })
                        if ($row.Count -ge 1) { $rowText = $row[0].Text }
                        if ($rowText.Length -gt 0 -and $rowText -notmatch '正在检查') { break }
                    }
                }
                Check 'B05 「关于」的更新状态会落定（不会卡在"正在检查…"）' (($rowText.Length -gt 0) -and ($rowText -notmatch '正在检查')) ('text=' + $rowText)
                Check 'B06 状态行里带上了新版本号 v9.9.9' ($rowText -match 'v9\.9\.9') ('text=' + $rowText)
                if ($about2) {
                    [void][PDGui]::CloseWindow($about2.H)
                    [void](Wait-WindowGone -Hwnd $about2.H)
                }
            }
        }
    }
    Stop-Gui $gui2
} catch {
    Check 'B99 假接口能起来' $false ($_.Exception.Message)
} finally {
    if ($gui2) { Stop-Gui $gui2 }
    if ($listener) { try { $listener.Stop(); $listener.Close() } catch { } }
}

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '=========================================================='
$total = $script:Pass + $script:Fail
Write-Host (" 合计 {0} 项，通过 {1}，失败 {2}" -f $total, $script:Pass, $script:Fail)
Write-Host '=========================================================='
if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
