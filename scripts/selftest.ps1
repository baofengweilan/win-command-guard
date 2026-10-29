#Requires -Version 7
<#
.SYNOPSIS
  win-command-guard 自检：护栏语法 + 四道闸行为样例 + 编码环境，一键验证安装是否可用。

.DESCRIPTION
  用 9 个真实样例直接"喂"护栏脚本（stdin JSON 契约），核对退出码：
  合法命令应放行(exit 0)，各类危险写法应拦截(exit 2)。
  全部通过 exit 0；有失败 exit 1。

.EXAMPLE
  pwsh -ExecutionPolicy Bypass -File selftest.ps1
#>
[CmdletBinding()]
param(
  [string]$Guard = (Join-Path $PSScriptRoot 'enforce-pwsh.ps1')
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $Guard)) { Write-Error ('找不到护栏脚本: ' + $Guard); exit 1 }

$results = @()
function Add-Result($name, $expected, $actual, $pass) {
  $script:results += [pscustomobject]@{ 检查 = $name; 期望 = $expected; 实际 = $actual; 通过 = $pass }
}
function Invoke-Guard($json) {
  # 返回 @(退出码, 输出文本)
  $out = $json | & pwsh -NoProfile -File $Guard 2>&1
  return @($LASTEXITCODE, ($out -join ' '))
}

# ---------- 1) 语法解析 ----------
$errs = $null; $toks = $null
[System.Management.Automation.Language.Parser]::ParseFile($Guard, [ref]$toks, [ref]$errs) | Out-Null
Add-Result '护栏语法解析' '0 错误' ("$(@($errs).Count) 错误") (@($errs).Count -eq 0)

# ---------- 2) 闸一：命令必须显式走 pwsh ----------
$r = Invoke-Guard @'
{"tool_name":"Bash","tool_input":{"command":"pwsh -NoProfile -Command \"whoami\""}}
'@
Add-Result '闸一放行：合法 pwsh 命令' 'exit 0' "exit $($r[0])" ($r[0] -eq 0)

$r = Invoke-Guard @'
{"tool_name":"Bash","tool_input":{"command":"whoami"}}
'@
Add-Result '闸一拦截：非 pwsh 命令' 'exit 2' "exit $($r[0])" ($r[0] -eq 2)
$blockMsg = $r[1]

# ---------- 3) 闸二：.bat/.cmd 的 GBK + CRLF ----------
$r = Invoke-Guard @'
{"tool_name":"Write","tool_input":{"file_path":"demo.bat","content":"@echo off\r\nrem 中文注释\r\n"}}
'@
Add-Result '闸二放行：bat=GBK+CRLF' 'exit 0' "exit $($r[0])" ($r[0] -eq 0)

$r = Invoke-Guard @'
{"tool_name":"Write","tool_input":{"file_path":"demo.bat","content":"@echo off\r\nrem \ud83d\ude00\r\n"}}
'@
Add-Result '闸二拦截：bat 含 emoji(GBK 不可编码)' 'exit 2' "exit $($r[0])" ($r[0] -eq 2)

$r = Invoke-Guard @'
{"tool_name":"Write","tool_input":{"file_path":"demo.bat","content":"@echo off\nrem 中文\n"}}
'@
Add-Result '闸二拦截：bat 为 LF-only' 'exit 2' "exit $($r[0])" ($r[0] -eq 2)

# ---------- 4) 闸三：URL 里的裸 & ----------
$r = Invoke-Guard @'
{"tool_name":"Bash","tool_input":{"command":"pwsh -NoProfile -Command 'Invoke-WebRequest https://example.com/?a=1&b=2'"}}
'@
Add-Result '闸三拦截：URL 的 & 裸露在引号外' 'exit 2' "exit $($r[0])" ($r[0] -eq 2)

# ---------- 5) 闸四：引号转义 / cmd 层管道 ----------
$r = Invoke-Guard @'
{"tool_name":"Bash","tool_input":{"command":"pwsh -NoProfile -Command \"Write-Host \\\"hi\\\"\""}}
'@
Add-Result '闸四拦截：内层出现 \" 转义' 'exit 2' "exit $($r[0])" ($r[0] -eq 2)

$r = Invoke-Guard @'
{"tool_name":"Bash","tool_input":{"command":"pwsh -NoProfile -Command \"Get-ChildItem\" | Select-Object Name"}}
'@
Add-Result '闸四拦截：收尾引号外挂管道' 'exit 2' "exit $($r[0])" ($r[0] -eq 2)

# ---------- 6) 编码环境（信息项） ----------
$encProfile   = (& pwsh -Command '[Console]::OutputEncoding.WebName' 2>$null) -join ''
$encNoProfile = (& pwsh -NoProfile -Command '[Console]::OutputEncoding.WebName' 2>$null) -join ''
$encTip = if ($encProfile -eq 'utf-8') { '已统一 UTF-8' } else { '建议运行 install.ps1 -SetProfileUtf8 统一编码' }
Add-Result '编码环境(信息)' '建议 utf-8' "profile=$encProfile / noProfile=$encNoProfile（$encTip）" $true

# ---------- 输出 ----------
$results | Format-Table -AutoSize
Write-Host ''
Write-Host ('拦截样例返回的提示（节选）: ' + ($blockMsg.Substring(0, [Math]::Min(80, $blockMsg.Length))))
$failed = @($results | Where-Object { -not $_.通过 }).Count
if ($failed -eq 0) {
  Write-Host '==> 全部通过 ✓  护栏工作正常。'
  exit 0
} else {
  Write-Host ("==> {0} 项未通过 ✗  请检查护栏脚本与环境。" -f $failed)
  exit 1
}
