#Requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 2604290100
<#
    Test-All.ps1 —— 一条命令跑完全部测试

    顺序（编码检查放最前面，因为编码坏了后面的测试根本没有意义）：
        0) 编码红线检查      tools\Test-Encoding.ps1
        1) 安装器测试 47 项  tests\Test-SetupExe.ps1
        2) 引擎回归   56 项  tests\Test-Engine-Regression.ps1
        3) 端到端     11 项  tests\Test-Engine-E2E.ps1   （需要交互式桌面）

    用法:
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-All.ps1
        ... -SkipE2E          # CI 里用：runner 没有交互式桌面，E2E 必然失败
        ... -SkipExe          # 不想动系统里的右键菜单时

    注意：
      - 安装器测试会真的往 HKLM 写/删右键菜单，需要管理员权限（脚本跑完会恢复现场）；
      - 全部测试必须用 Windows PowerShell 5.1（引擎的运行时就是它）。

    退出码: 0 = 全绿；1 = 有失败或环境不满足
#>
[CmdletBinding()]
param(
    [switch]$SkipE2E,
    [switch]$SkipExe
)

$ErrorActionPreference = 'Continue'
$testsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $testsDir
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $ps)) { $ps = 'powershell.exe' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host '=========================================================='
Write-Host ' 永久删除右键菜单 —— 全套测试'
Write-Host '=========================================================='
Write-Host (' 仓库根   : {0}' -f $repoRoot)
Write-Host (' 管理员   : {0}' -f $isAdmin)
Write-Host (' 运行时   : Windows PowerShell 5.1')
Write-Host ''

$suites = @()
$suites += [pscustomobject]@{ Name = '编码红线检查'; File = (Join-Path $repoRoot 'tools\Test-Encoding.ps1'); Skip = $false }
$suites += [pscustomobject]@{ Name = '安装器测试 47 项'; File = (Join-Path $testsDir 'Test-SetupExe.ps1'); Skip = [bool]$SkipExe }
$suites += [pscustomobject]@{ Name = '引擎回归 56 项';  File = (Join-Path $testsDir 'Test-Engine-Regression.ps1'); Skip = $false }
$suites += [pscustomobject]@{ Name = '端到端 11 项';    File = (Join-Path $testsDir 'Test-Engine-E2E.ps1'); Skip = [bool]$SkipE2E }

$results = @()
foreach ($s in $suites) {
    if ($s.Skip) {
        Write-Host ('---- 跳过: {0} ----' -f $s.Name)
        $results += [pscustomobject]@{ Name = $s.Name; Exit = -1; Summary = '已跳过' }
        continue
    }
    if (-not (Test-Path $s.File)) {
        $results += [pscustomobject]@{ Name = $s.Name; Exit = 1; Summary = ('找不到 ' + $s.File) }
        continue
    }

    Write-Host ('---- {0} ----' -f $s.Name)
    $logFile = Join-Path $env:TEMP ('pd_test_' + [System.IO.Path]::GetFileNameWithoutExtension($s.File) + '_' + (Get-Date -Format 'HHmmss') + '.log')
    & $ps -NoProfile -ExecutionPolicy Bypass -File $s.File *>&1 | Tee-Object -FilePath $logFile | Out-Null
    $code = $LASTEXITCODE

    $text = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { '' }
    $summary = ''
    $m = [regex]::Match($text, '合计\s*(\d+)\s*项，通过\s*(\d+)，失败\s*(\d+)')
    if ($m.Success) {
        $summary = ('{0}/{1} 通过' -f $m.Groups[2].Value, $m.Groups[1].Value)
    } elseif ($text -match '端到端结果：通过\s*(\d+)，失败\s*(\d+)') {
        $summary = ('{0}/{1} 通过' -f $Matches[1], ([int]$Matches[1] + [int]$Matches[2]))
    } elseif ($text -match '全部通过') {
        $summary = '编码检查通过'
    } elseif ($code -eq 3) {
        # 退出码 3 = 环境不满足（端到端测试遇到「仅 Shift 显示」时会这样返回）
        $summary = '已跳过（环境不满足，见上方说明）'
    } else {
        $summary = ('退出码 ' + $code)
    }
    if ($code -ne 0 -and $code -ne 3) { $summary += ('  ← 看日志: ' + $logFile) }

    $results += [pscustomobject]@{ Name = $s.Name; Exit = $code; Summary = $summary }
    Write-Host ('   → {0}  (退出码 {1})' -f $summary, $code)
    Write-Host ''
}

$failed = @($results | Where-Object { $_.Exit -ne 0 -and $_.Exit -ne -1 -and $_.Exit -ne 3 })
Write-Host '=========================================================='
$results | ForEach-Object {
    $flag = 'PASS'
    if ($_.Exit -eq -1 -or $_.Exit -eq 3) { $flag = 'SKIP' } elseif ($_.Exit -ne 0) { $flag = 'FAIL' }
    Write-Host ('  [{0}] {1}  {2}' -f $flag, $_.Name.PadRight(18), $_.Summary)
}
Write-Host '=========================================================='

if ($failed.Count -gt 0) {
    Write-Host ('结果：{0} 个套件失败' -f $failed.Count)
    exit 1
}
Write-Host '结果：全部通过'
exit 0
