#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mxx1.cn
<#
    Test-E2E-ShellMenu.ps1 —— 端到端测试：走真实的 Shell 右键动词

    和 Test-PermanentDelete.ps1 不同，这里不直接调脚本，而是：
      1) 用 Shell.Application 枚举动词，确认"永久删除（不进回收站）"真的在菜单里；
      2) 用 FolderItemVerb.DoIt() 触发它 —— 这就是资源管理器点菜单时走的那条路
         （Shell 自己拼命令行、自己展开 %V、经 wscript 启动脚本）；
      3) 模拟"混合选中"：文件动词与文件夹动词几乎同时触发（Explorer 就是这么干的），
         验证是否只弹出一个确认框（看日志里的 CONFIRM 次数）。

    第 1 轮按 Esc 取消（不删东西）；第 2 轮用 Tab+空格 点"永久删除"验证真能删。
#>
[CmdletBinding()]
param(
    [switch]$SkipDeleteRound
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms

$LogPath = Join-Path $env:LOCALAPPDATA 'PermanentDelete\delete.log'
$Title   = '永久删除（不进回收站）'
$OkButtonText = '永久删除'

function Log-Mark {
    if (-not [System.IO.File]::Exists($LogPath)) { return 0 }
    return @([System.IO.File]::ReadAllLines($LogPath, [System.Text.Encoding]::UTF8)).Count
}
function Log-Since([int]$mark) {
    if (-not [System.IO.File]::Exists($LogPath)) { return '' }
    $l = [System.IO.File]::ReadAllLines($LogPath, [System.Text.Encoding]::UTF8)
    if ($mark -ge $l.Count) { return '' }
    return ($l[$mark..($l.Count - 1)] -join "`r`n")
}
function Find-DialogProcess {
    return @(Get-Process -Name powershell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq $Title })
}
function Shot([string]$file) {
    $vs  = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}
function Close-AnyDialog {
    # 用 WM_CLOSE 直接关窗：SendKeys 依赖焦点，而确认框是 TopMost，
    # AppActivate 经常抢不到前景，Esc 会丢 —— 那样"取消"就成了靠运气。
    $closed = 0
    foreach ($hwnd in (Get-DialogHandles)) {
        [void][PDWin]::PostMessageW($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        $closed++
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 800
    if ((Find-DialogProcess).Count -gt 0) {
        foreach ($p in (Find-DialogProcess)) { try { $p.Kill() } catch { } }
        return $true   # 只能靠杀进程收场
    }
    return $false
}

# ---- Win32 窗口工具（标题由参数传入：不要往 Add-Type 的 C# 源码里写中文，会被编码弄坏）----
if (-not ('PDWin' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class PDWin {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
  public static IntPtr FindButton(IntPtr parent, string textPart) {
    // 必须同时校验类名：窗体上"摘要标签"的文字里也含『永久删除』，
    // 只按文字匹配会把 BM_CLICK 打在 Label 上（点了没反应）。
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(parent, (h,l) => {
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      if (c.ToString().IndexOf("BUTTON", StringComparison.OrdinalIgnoreCase) < 0) return true;
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      if (t.ToString().IndexOf(textPart, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static List<IntPtr> FindVisible(string titlePart) {
    var r = new List<IntPtr>();
    EnumWindows((h,l) => {
      if (IsWindowVisible(h)) {
        var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
        if (t.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0) r.Add(h);
      }
      return true;
    }, IntPtr.Zero);
    return r;
  }
}
'@ -ErrorAction SilentlyContinue
}
function Get-DialogHandles {
    return @([PDWin]::FindVisible($Title))
}

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++ } else { $script:fail++ }
    $flag = 'PASS'; if (-not $ok) { $flag = 'FAIL' }
    Write-Host ("  [{0}] {1}{2}" -f $flag, $name, $(if ($detail) { "   ($detail)" } else { '' }))
}

# ---------------- 造场景（沿用用户那次的文件名） ----------------
$root = Join-Path $env:TEMP ('PDE2E_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
$sub  = Join-Path $root 'Vector Magic 1.15 中文版'
$shotDir = Join-Path $root 'shots'          # 截图写进测试自己的临时目录，不污染仓库、不依赖固定路径
[void][System.IO.Directory]::CreateDirectory($sub)
[void][System.IO.Directory]::CreateDirectory($shotDir)
[System.IO.File]::WriteAllText((Join-Path $sub 'inner.txt'), 'x')
$f1 = Join-Path $root '免责声明.txt';            [System.IO.File]::WriteAllText($f1, 'x')
$f2 = Join-Path $root '搜 索 更 多 工 具.png';    [System.IO.File]::WriteAllText($f2, 'x')
$f3 = Join-Path $root '素 材 资 源 网mxx1.url';   [System.IO.File]::WriteAllText($f3, 'x')

Write-Host ''
Write-Host '=========================================================='
Write-Host ' 端到端测试：真实 Shell 右键动词'
Write-Host '=========================================================='
Write-Host (" 测试目录 : {0}" -f $root)
Write-Host (" 日志     : {0}" -f $LogPath)
Write-Host ''

# ---------------- 1) 菜单可见性 ----------------
Write-Host '1) 菜单里是否有"永久删除（不进回收站）"'

# 先看当前是不是「仅 Shift 显示」：那种模式下 Shell.Application 的 Verbs()
# 列不出这一项（它没法模拟按住 Shift），本测试就无法通过 —— 这是环境不满足，
# 不是被测代码坏了，所以按"跳过"处理（退出码 3），而不是报失败。
$iniPath = Join-Path $env:LOCALAPPDATA 'PermanentDelete\setup.ini'
$extendedOnly = $false
if (Test-Path -LiteralPath $iniPath) {
    $ini = Get-Content -LiteralPath $iniPath -Encoding UTF8
    $extendedOnly = [bool](@($ini | Where-Object { $_ -match '^\s*ExtendedOnly\s*=\s*true' }).Count -gt 0)
}

$shell = New-Object -ComObject Shell.Application
$nsRoot = $shell.NameSpace($root)
$vf = @($nsRoot.ParseName('免责声明.txt').Verbs() | Where-Object { $_.Name -match '永久删除' })
$vd = @($nsRoot.ParseName('Vector Magic 1.15 中文版').Verbs() | Where-Object { $_.Name -match '永久删除' })
Check '文件右键菜单里可见'   ($vf.Count -ge 1) ("匹配数=" + $vf.Count)
Check '文件夹右键菜单里可见' ($vd.Count -ge 1) ("匹配数=" + $vd.Count)
if ($vf.Count -lt 1 -or $vd.Count -lt 1) {
    if ($extendedOnly) {
        Write-Host ''
        Write-Host '  跳过：当前设置为「仅 Shift 显示」，非 Shift 右键本来就不列出这一项。'
        Write-Host '  端到端测试需要菜单在普通右键里可见，请先执行：'
        Write-Host '      PermanentDeleteSetup.exe install --no-extended'
        Write-Host '  测完想恢复，再执行：'
        Write-Host '      PermanentDeleteSetup.exe install --extended'
        exit 3
    }
    Write-Host '  菜单项不可见（多半被右键菜单管理工具隐藏），后续测试无法进行。'
    Write-Host '  请重新运行 PermanentDeleteSetup.exe 点「添加 / 修复菜单」，或在菜单管理工具里恢复该项。'
    exit 1
}

# ---------------- 2) 取消轮：混合选中 → 只弹一个框 ----------------
Write-Host ''
Write-Host '2) 第 1 轮：文件动词 + 文件夹动词 同时触发（模拟混合选中），然后取消（WM_CLOSE）'
$mark = Log-Mark
$vf[0].DoIt()      # Shell 自己拼命令行启动脚本
$vd[0].DoIt()
Write-Host '   已触发两个动词，等待确认框…'

$dlg = @()
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    $dlg = Get-DialogHandles
    if ($dlg.Count -ge 1) { break }
    Start-Sleep -Milliseconds 250
}
Check '弹出了确认框' ($dlg.Count -ge 1) ("窗口数=" + $dlg.Count)
Check '只弹出一个确认框' ($dlg.Count -eq 1) ("窗口数=" + $dlg.Count)

$shot1 = Join-Path $shotDir 'e2e-dialog.png'
if ($dlg.Count -ge 1) {
    [void][PDWin]::SetForegroundWindow($dlg[0])
    Start-Sleep -Milliseconds 500
    Shot $shot1
    Write-Host ("   截图: " + $shot1)
    [void][PDWin]::PostMessageW($dlg[0], 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE = 取消
    Start-Sleep -Milliseconds 2000
}
$killed = Close-AnyDialog
$lines = Log-Since $mark
$confirms = ([regex]::Matches($lines, 'CONFIRM')).Count
Check '日志里只有一次确认（合并成功）' ($confirms -eq 1) ("CONFIRM 次数=" + $confirms)
Check '合并批次包含 2 项' ($lines -match 'BATCH n=2') (($lines -split "`r`n" | Where-Object { $_ -match 'BATCH' }) -join ' ')
Check '按取消后四个项目都还在' ((Test-Path -LiteralPath $sub) -and (Test-Path -LiteralPath $f1) -and (Test-Path -LiteralPath $f2) -and (Test-Path -LiteralPath $f3))
if ($killed) { Write-Host '   注意：确认框未能用 Esc 关闭，已强制结束进程（等同取消）' }

# ---------------- 3) 确认轮：真的点"永久删除" ----------------
if (-not $SkipDeleteRound) {
    Write-Host ''
    Write-Host '3) 第 2 轮：再次触发，用 Tab+空格 点"永久删除"'
    $mark = Log-Mark
    $vf[0].DoIt()
    $vd[0].DoIt()

    $dlg = @()
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $dlg = Get-DialogHandles
        if ($dlg.Count -ge 1) { break }
        Start-Sleep -Milliseconds 250
    }
    Check '再次弹出（且仅一个）确认框' ($dlg.Count -eq 1) ("窗口数=" + $dlg.Count)

    if ($dlg.Count -ge 1) {
        [void][PDWin]::SetForegroundWindow($dlg[0])
        Start-Sleep -Milliseconds 600
        Shot (Join-Path $shotDir 'e2e-dialog-focus.png')
        # 直接给"永久删除"按钮发 BM_CLICK：不依赖焦点与 Tab 顺序，确定性点击
        $btn = [PDWin]::FindButton($dlg[0], $OkButtonText)
        if ($btn -ne [IntPtr]::Zero) {
            [void][PDWin]::SendMessageW($btn, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
        } else {
            Write-Host '   没找到『永久删除』按钮，退回键盘方式'
            [System.Windows.Forms.SendKeys]::SendWait('{TAB}')
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait(' ')
        }
        Start-Sleep -Milliseconds 2500
    }
    $killed = Close-AnyDialog
    $lines = Log-Since $mark
    $deleted = (-not (Test-Path -LiteralPath $f1)) -and (-not (Test-Path -LiteralPath $sub))
    Check '点"永久删除"后文件被删'   (-not (Test-Path -LiteralPath $f1))
    Check '点"永久删除"后文件夹被删' (-not (Test-Path -LiteralPath $sub))
    Check '日志里只有一次确认'       (([regex]::Matches($lines, 'CONFIRM yes')).Count -eq 1) (($lines -split "`r`n" | Where-Object { $_ -match 'CONFIRM' }) -join ' ')
    if (-not $deleted) { Write-Host '   （若未删成功，可能是 Tab 焦点没落在"永久删除"按钮上，看 e2e-dialog-focus.png 即可确认）' }
}

# ---------------- 收尾 ----------------
if ((Find-DialogProcess).Count -gt 0) { [void](Close-AnyDialog) }
Write-Host ''
Write-Host '=========================================================='
Write-Host (" 端到端结果：通过 {0}，失败 {1}" -f $pass, $fail)
Write-Host '=========================================================='
Write-Host (" 测试目录: {0}" -f $root)
Write-Host ''
if ($fail -eq 0) { exit 0 } else { exit 1 }
