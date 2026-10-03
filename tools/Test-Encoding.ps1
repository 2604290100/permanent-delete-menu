#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 2604290100
<#
    Test-Encoding.ps1 —— 编码红线检查（本地与 CI 共用）

    这个项目踩过三次编码坑，每次都是"静默毁功能"级别：
      1) 引擎 .ps1 丢 BOM  → PowerShell 5.1 按 GBK 解析 → 弹框变语法错误；
      2) .vbs 里混进中文注释 → wscript 按 ANSI 读，最后一个字节吞掉换行，
         把下一行 `maxLen = 28000` 并进注释，阈值恒为 0；
      3) 补丁工具保存 UTF-8 时静默丢掉 BOM → build.ps1 自己变成语法错误。

    所以把规则固化成脚本，本地改完和 CI 都跑一遍。

    用法:
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-Encoding.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-Encoding.ps1 -Fix

    退出码: 0 = 全部通过；1 = 有违规（-Fix 修不好的就是必须人工处理的）
#>
[CmdletBinding()]
param(
    [switch]$Fix     # 给缺失 BOM 的 .ps1/.psm1/.cs 自动补回（.vbs 的非 ASCII 必须人工改）
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$skipDirs = @('.git', 'bin', 'obj', 'node_modules', '.vs', 'temp', 'tmp')

$violations = @()
$fixed      = @()

function Add-Violation([string]$rel, [string]$why) {
    $script:violations += ('{0}  —— {1}' -f $rel, $why)
}

function Get-RepoFiles([string[]]$patterns) {
    # 注意必须用 -Path 而不是 -LiteralPath：-LiteralPath 会**静默忽略 -Include**，
    # 结果把 .png/.ico/LICENSE 也当成脚本来检查（第一版就踩了这个坑）。
    Get-ChildItem -Path $repoRoot -Recurse -File -Include $patterns -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($repoRoot.Length).TrimStart('\')
            $top = ($rel -split '\\')[0]
            $skipDirs -notcontains $top
        }
}

function Test-HasBom([byte[]]$bytes) {
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Test-IsValidUtf8([string]$path, [bool]$hasBom) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $offset = 0
        if ($hasBom) { $offset = 3 }
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$strict.GetString($bytes, $offset, $bytes.Length - $offset)
        return $true
    } catch {
        return $false
    }
}

Write-Host ''
Write-Host '========== 编码红线检查 =========='

# ---------------------------------------------------------------- 1) BOM 规则
# 必须带 BOM：PowerShell / C# 源码
foreach ($f in (Get-RepoFiles @('*.ps1', '*.psm1', '*.cs'))) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\')
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not (Test-HasBom $bytes)) {
        if ($Fix) {
            $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($f.FullName, $text, (New-Object System.Text.UTF8Encoding($true)))
            $fixed += ('补回 BOM: ' + $rel)
        } else {
            Add-Violation $rel '缺少 UTF-8 BOM（PS 5.1 会按 GBK 解析；csc 会按 ANSI 解码）'
        }
    }
}

# 必须不带 BOM：文档与配置（有些解析器见到 BOM 就报错）
foreach ($f in (Get-RepoFiles @('*.md', '*.yml', '*.yaml', '*.json'))) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\')
    if (Test-HasBom ([System.IO.File]::ReadAllBytes($f.FullName))) {
        Add-Violation $rel '不该有 BOM（Markdown / YAML 必须是不带 BOM 的 UTF-8）'
    }
}
foreach ($name in @('LICENSE', '.gitignore', '.gitattributes', '.editorconfig')) {
    $p = Join-Path $repoRoot $name
    if ((Test-Path $p) -and (Test-HasBom ([System.IO.File]::ReadAllBytes($p)))) {
        Add-Violation $name '不该有 BOM'
    }
}

# ---------------------------------------------------------------- 2) VBS 纯 ASCII
foreach ($f in (Get-RepoFiles @('*.vbs'))) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\')
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if (Test-HasBom $bytes) {
        Add-Violation $rel '.vbs 不能带 BOM（wscript 按 ANSI 读）'
    }
    $max = [int](($bytes | Measure-Object -Maximum).Maximum)
    if ($max -gt 127) {
        Add-Violation $rel ('含非 ASCII 字节（最大 0x{0:X2}）—— 中文注释会吞掉换行，必须改成英文' -f $max)
    }
}

# ---------------------------------------------------------------- 3) UTF-8 合法性
foreach ($f in (Get-RepoFiles @('*.ps1', '*.psm1', '*.cs', '*.vbs', '*.md', '*.yml', '*.yaml'))) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\')
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    if (-not (Test-IsValidUtf8 $f.FullName (Test-HasBom $bytes))) {
        Add-Violation $rel '不是合法的 UTF-8（多半被某个编辑器按 GBK 存过）'
    }
}

# ---------------------------------------------------------------- 4) 个人路径泄漏
# 开源仓库里不该出现贡献者本机的绝对路径（测试曾经硬编码过 D:\...\e2e-dialog.png）
# 例外：文档里"叫用户别贴个人路径"的示范文本（写成 C:\Users\你的名字\... 这种）不算泄漏，
#       靠占位符白名单放行；确实要放行某一行也可以在该行写 encoding-check:ignore。
$personalPatterns = @(
    @{ Re = '[A-Za-z]:\\Users\\[^\\%]';   Why = '硬编码了本机用户目录绝对路径，请改用 $env:USERPROFILE / %USERPROFILE%' },
    @{ Re = '豆包临时工作区';              Why = '硬编码了私人工作区路径' }   # encoding-check:ignore
)
$placeholderLine = 'encoding-check:ignore|你的名字|<用户|<路径|<用户名>|<name>|<username>|placeholder'
foreach ($f in (Get-RepoFiles @('*.ps1', '*.psm1', '*.cs', '*.vbs', '*.yml', '*.yaml'))) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\')
    $lines = [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $placeholderLine) { continue }
        foreach ($p in $personalPatterns) {
            if ($lines[$i] -match $p.Re) {
                Add-Violation ('{0}:{1}' -f $rel, ($i + 1)) $p.Why
            }
        }
    }
}

# ---------------------------------------------------------------- 汇总
Write-Host ''
if ($fixed.Count -gt 0) {
    Write-Host ('已自动修好 {0} 处：' -f $fixed.Count)
    $fixed | ForEach-Object { Write-Host ('  [FIX ] ' + $_) }
}
if ($violations.Count -eq 0) {
    Write-Host '全部通过：脚本带 BOM、VBS 纯 ASCII、文档不带 BOM、无个人路径泄漏'
    Write-Host '=================================='
    exit 0
}

Write-Host ('发现 {0} 处违规：' -f $violations.Count)
$violations | ForEach-Object { Write-Host ('  [FAIL] ' + $_) }
Write-Host ''
Write-Host '提示：加 -Fix 可以自动补回 .ps1/.cs 的 BOM；VBS 的非 ASCII 与个人路径必须人工改。'
Write-Host '=================================='
exit 1
