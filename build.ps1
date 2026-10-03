#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 2604290100
<#
    build.ps1 —— 一键编译 PermanentDeleteSetup.exe

    不需要 .NET SDK：用系统自带的 csc.exe（.NET Framework 4.x 附带，Win10 一定有）。
    引擎脚本（PermanentDelete.ps1 / launch_perm_delete.vbs）以资源形式内嵌进 exe，
    产物是单个自包含 exe，不依赖旁边的任何文件。

    用法:
        powershell -ExecutionPolicy Bypass -File build.ps1
        powershell -ExecutionPolicy Bypass -File build.ps1 -Package   # 额外打一个发布 zip

    注意：本文件必须保存为 UTF-8 带 BOM（PowerShell 5.1 否则按 GBK 读中文会出错）。
#>
[CmdletBinding()]
param(
    [switch]$Package,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$binDir = Join-Path $root 'bin'
$out = Join-Path $binDir 'PermanentDeleteSetup.exe'

# ---- 定位配套 skill（源码可能已移到工作区的 .dsh\skills\ 下） ----
# 查找顺序：项目内自带的 skill\ → 环境变量覆盖 → 父目录工作区 .dsh\skills\ → 用户级安装
$skillName = 'permanent-delete-menu'
$skillCandidates = @(
    (Join-Path $root ('skill\' + $skillName)),
    $env:PERMDEL_SKILL_DIR,
    (Join-Path (Split-Path -Parent $root) ('.dsh\skills\' + $skillName)),
    (Join-Path $env:USERPROFILE ('.dsh\skills\' + $skillName))
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'SKILL.md')) }
$skillSrc = $skillCandidates | Select-Object -First 1
if ($skillSrc) {
    Write-Host ('配套 skill: ' + $skillSrc)
} else {
    Write-Host '配套 skill: 未找到（打包 zip 里将不含 skill，编译不受影响）'
}

if ($Clean -and (Test-Path $binDir)) { Remove-Item $binDir -Recurse -Force }

# ---- 找编译器 ----
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { throw '找不到 csc.exe（需要 .NET Framework 4.x）' }

# ---- 前置检查：引擎脚本的两条编码红线 ----
$ps1 = Join-Path $root 'engine\PermanentDelete.ps1'
$vbs = Join-Path $root 'engine\launch_perm_delete.vbs'
if (-not (Test-Path $ps1)) { throw ('缺少引擎脚本: ' + $ps1) }
if (-not (Test-Path $vbs)) { throw ('缺少引擎脚本: ' + $vbs) }

$b = [System.IO.File]::ReadAllBytes($ps1)
if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
    Write-Warning 'PermanentDelete.ps1 没有 UTF-8 BOM —— PS 5.1 会把中文按 GBK 读错，正在补上'
    [System.IO.File]::WriteAllText($ps1, [System.IO.File]::ReadAllText($ps1, [System.Text.Encoding]::UTF8), (New-Object System.Text.UTF8Encoding($true)))
}
$vb = [System.IO.File]::ReadAllBytes($vbs)
$maxByte = ($vb | Measure-Object -Maximum).Maximum
if ($maxByte -gt 127) {
    throw ('launch_perm_delete.vbs 含非 ASCII 字节（最大 ' + $maxByte + '）—— wscript 按 ANSI 读取会把中文注释解错、甚至吞掉换行。请改成纯 ASCII。')
}

# ---- 前置检查：C# 源码也要有 BOM（csc 对无 BOM 文件按 ANSI 解码，中文会花）----
# 注意：很多编辑器/补丁工具保存 UTF-8 时会**丢掉 BOM**，所以这里统一自动补回，
# 测试脚本也一样（PS 5.1 对无 BOM 的 .ps1 按 GBK 读中文 → 直接语法错误，不是静默失败）。
foreach ($f in @(Get-ChildItem (Join-Path $root 'src\*.cs')) + @(Get-ChildItem (Join-Path $root 'tests\*.ps1') -ErrorAction SilentlyContinue)) {
    $cb = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not ($cb.Length -ge 3 -and $cb[0] -eq 0xEF -and $cb[1] -eq 0xBB -and $cb[2] -eq 0xBF)) {
        [System.IO.File]::WriteAllText($f.FullName, [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8), (New-Object System.Text.UTF8Encoding($true)))
        Write-Host ('  补回 BOM: ' + $f.Name)
    }
}

# ---- 编译 ----
[void][System.IO.Directory]::CreateDirectory($binDir)
$sources = @(Get-ChildItem (Join-Path $root 'src\*.cs') | ForEach-Object { $_.FullName })
$cscArgs = @(
    '/nologo'
    '/target:winexe'
    '/platform:anycpu'
    '/langversion:5'
    '/optimize+'
    '/warn:4'
    ('/out:' + $out)
    ('/win32icon:' + (Join-Path $root 'assets\app.ico'))
    ('/win32manifest:' + (Join-Path $root 'assets\app.manifest'))
    ('/resource:' + $ps1 + ',PermanentDelete.ps1')
    ('/resource:' + $vbs + ',launch_perm_delete.vbs')
    '/reference:System.dll'
    '/reference:System.Core.dll'
    '/reference:System.Drawing.dll'
    '/reference:System.Windows.Forms.dll'
    '/reference:Microsoft.CSharp.dll'
)

Write-Host ('编译器: ' + $csc)
& $csc @cscArgs $sources
if ($LASTEXITCODE -ne 0) { throw ('编译失败（退出码 ' + $LASTEXITCODE + '）') }

$exe = Get-Item $out
Write-Host ''
Write-Host ('编译成功: ' + $exe.FullName)
Write-Host ('大小: {0:N0} 字节' -f $exe.Length)

# ---- 自检：资源是否真的内嵌进去了 ----
$asm = [System.Reflection.Assembly]::LoadFile($out)
$names = $asm.GetManifestResourceNames()
Write-Host ('内嵌资源: ' + ($names -join ', '))
if (-not ($names -contains 'PermanentDelete.ps1') -or -not ($names -contains 'launch_perm_delete.vbs')) {
    throw '内嵌资源名不对，引擎文件没进 exe'
}

# ---- 可选打包 ----
if ($Package) {
    $stage = Join-Path $binDir 'PermanentDeleteSetup-package'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    foreach ($d in @('', 'src', 'engine', 'assets', 'tests', 'docs')) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $stage $d))
    }
    Copy-Item $out $stage -Force
    Copy-Item (Join-Path $root 'README.md') $stage -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $root 'build.ps1') $stage -Force
    Copy-Item (Join-Path $root 'src\*.cs') (Join-Path $stage 'src') -Force
    Copy-Item (Join-Path $root 'engine\*') (Join-Path $stage 'engine') -Force
    Copy-Item (Join-Path $root 'assets\*') (Join-Path $stage 'assets') -Force
    Copy-Item (Join-Path $root 'tests\*') (Join-Path $stage 'tests') -Force
    Copy-Item (Join-Path $root 'docs\*') (Join-Path $stage 'docs') -Force -ErrorAction SilentlyContinue
    if ($skillSrc) {
        $skillDst = Join-Path $stage ('skill\' + $skillName)
        [void][System.IO.Directory]::CreateDirectory($skillDst)
        Copy-Item (Join-Path $skillSrc '*') $skillDst -Force -ErrorAction SilentlyContinue
    }
    $zip = Join-Path $binDir 'PermanentDeleteSetup-package.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    Write-Host ('已打包: ' + $zip + '  (' + (Get-Item $zip).Length + ' 字节)')
}
