#Requires -Version 7
<#
.SYNOPSIS
  win-command-guard 一键安装器：把"命令护栏"注册进本机的 AI agent 宿主。

.DESCRIPTION
  1) 复制护栏脚本到 InstallDir（默认 %USERPROFILE%\.win-command-guard）
  2) 自动检测宿主（ZCode / Claude Code），把 PreToolUse 钩子写进其配置；
     加 -WithTimeContext 可同时注册 UserPromptSubmit 时间注入组件（需 python 在 PATH）
  3) 幂等：按脚本文件名识别既有注册，重复运行不会产生重复条目
  4) 写配置前自动备份（*.bak-win-command-guard），写后回读校验，失败自动还原
  5) 加 -SetProfileUtf8 可顺带给 pwsh 用户 profile 追加 UTF-8 统一（防中文乱码）

.EXAMPLE
  pwsh -ExecutionPolicy Bypass -File install.ps1 -WithTimeContext -SetProfileUtf8
#>
[CmdletBinding()]
param(
  [switch]$WithTimeContext,
  [switch]$SetProfileUtf8,
  [string]$InstallDir = (Join-Path $env:USERPROFILE '.win-command-guard'),
  [string]$ZcodeConfig = (Join-Path $env:USERPROFILE '.zcode\cli\config.json'),
  [string]$ClaudeConfig = (Join-Path $env:USERPROFILE '.claude\settings.json')
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
function Info($m) { Write-Host ('[win-command-guard] ' + $m) }

# ---------- 1) 复制脚本 ----------
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item (Join-Path $src 'enforce-pwsh.ps1') $InstallDir -Force
$guardPath = Join-Path $InstallDir 'enforce-pwsh.ps1'
Info ('护栏脚本就位: ' + $guardPath)

$pythonExe = $null
$timePath  = $null
if ($WithTimeContext) {
  $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
  if (-not $pythonExe) {
    Info '警告: 未找到 python，跳过时间注入组件'
  } else {
    Copy-Item (Join-Path $src 'time-context.py') $InstallDir -Force
    $timePath = Join-Path $InstallDir 'time-context.py'
    Info ('时间注入组件就位: ' + $timePath)
  }
}

# ---------- 2) profile UTF-8（可选） ----------
if ($SetProfileUtf8) {
  $prof = Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
  $profDir = Split-Path $prof
  if (-not (Test-Path $profDir)) { New-Item -ItemType Directory -Path $profDir -Force | Out-Null }
  $has = (Test-Path $prof) -and ((Get-Content $prof -Raw) -match 'Console\]::OutputEncoding')
  if ($has) {
    Info 'profile 已含 UTF-8 设置，跳过'
  } else {
    Add-Content -Path $prof -Value '# --- win-command-guard: 统一 UTF-8，防中文乱码 ---' -Encoding utf8
    Add-Content -Path $prof -Value 'chcp 65001 > $null' -Encoding utf8
    Add-Content -Path $prof -Value '[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new()' -Encoding utf8
    Add-Content -Path $prof -Value '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()' -Encoding utf8
    Add-Content -Path $prof -Value '$global:OutputEncoding    = [System.Text.UTF8Encoding]::new()' -Encoding utf8
    Info ('已为 profile 追加 UTF-8 设置: ' + $prof)
  }
}

# ---------- 工具函数 ----------
function Get-Json($path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
function Save-Json($cfg, $path) {
  $cfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8
}
function Backup-File($path) {
  if (Test-Path $path) {
    Copy-Item -LiteralPath $path -Destination ($path + '.bak-win-command-guard') -Force
  }
}
function Find-Existing($eventGroups, $scriptName) {
  foreach ($grp in @($eventGroups)) {
    foreach ($h in @($grp.hooks)) {
      $blob = ([string]$h.command) + ' ' + (@($h.args) -join ' ')
      if ($blob -match [regex]::Escape($scriptName)) { return $true }
    }
  }
  return $false
}
function Add-Event($events, $eventName, $newGroup) {
  $arr = @()
  if ($events.PSObject.Properties[$eventName] -and $null -ne $events.$eventName) {
    $arr = @($events.$eventName)
  }
  $arr += $newGroup
  $events | Add-Member -Force -MemberType NoteProperty -Name $eventName -Value $arr
}
function Save-WithVerify($cfg, $path) {
  $backup = $path + '.bak-win-command-guard'
  Backup-File $path
  Save-Json $cfg $path
  try { Get-Json $path | Out-Null }
  catch {
    Copy-Item -LiteralPath $backup -Destination $path -Force
    throw ('写入 ' + $path + ' 后回读校验失败，已还原备份。原因: ' + $_.Exception.Message)
  }
}

# ---------- 3a) ZCode（hooks.events.<Event>，process 型） ----------
if (Test-Path $ZcodeConfig) {
  $cfg = Get-Json $ZcodeConfig
  if (-not $cfg.PSObject.Properties['hooks'] -or $null -eq $cfg.hooks) {
    $cfg | Add-Member -Force -MemberType NoteProperty -Name hooks -Value ([pscustomobject]@{})
  }
  if (-not $cfg.hooks.PSObject.Properties['enabled']) {
    $cfg.hooks | Add-Member -Force -MemberType NoteProperty -Name enabled -Value $true
  }
  $cfg.hooks.enabled = $true
  if (-not $cfg.hooks.PSObject.Properties['events'] -or $null -eq $cfg.hooks.events) {
    $cfg.hooks | Add-Member -Force -MemberType NoteProperty -Name events -Value ([pscustomobject]@{})
  }
  $events = $cfg.hooks.events
  $changed = $false

  $existingP = @()
  if ($events.PSObject.Properties['PreToolUse'] -and $null -ne $events.PreToolUse) { $existingP = @($events.PreToolUse) }
  if (Find-Existing $existingP 'enforce-pwsh.ps1') {
    Info 'ZCode: 已有 enforce-pwsh.ps1 注册，跳过（幂等）'
  } else {
    $hook = [pscustomobject]@{
      type = 'process'; command = 'pwsh'
      args = @('-NoProfile', '-File', $guardPath)
      timeoutMs = 10000; statusMessage = '检查命令规范与 bat 编码/换行'
    }
    Add-Event $events 'PreToolUse' ([pscustomobject]@{ matcher = 'Bash|Write|Edit'; hooks = @($hook) })
    $changed = $true
    Info 'ZCode: 已注册 PreToolUse 护栏（matcher: Bash|Write|Edit）'
  }

  if ($timePath) {
    $existingU = @()
    if ($events.PSObject.Properties['UserPromptSubmit'] -and $null -ne $events.UserPromptSubmit) { $existingU = @($events.UserPromptSubmit) }
    if (Find-Existing $existingU 'time-context.py') {
      Info 'ZCode: 已有 time-context.py 注册，跳过（幂等）'
    } else {
      $th = [pscustomobject]@{
        type = 'process'; command = $pythonExe
        args = @($timePath); timeoutMs = 5000; statusMessage = '注入当前时间上下文'
      }
      Add-Event $events 'UserPromptSubmit' ([pscustomobject]@{ hooks = @($th) })
      $changed = $true
      Info 'ZCode: 已注册 UserPromptSubmit 时间注入'
    }
  }

  if ($changed) {
    Save-WithVerify $cfg $ZcodeConfig
    Info ('ZCode 配置已更新（备份: ' + $ZcodeConfig + '.bak-win-command-guard）')
  }
} else {
  Info ('未发现 ZCode 配置（' + $ZcodeConfig + '），跳过')
}

# ---------- 3b) Claude Code（hooks.<Event>，command 型） ----------
if (Test-Path $ClaudeConfig) {
  $cfg = Get-Json $ClaudeConfig
  if (-not $cfg.PSObject.Properties['hooks'] -or $null -eq $cfg.hooks) {
    $cfg | Add-Member -Force -MemberType NoteProperty -Name hooks -Value ([pscustomobject]@{})
  }
  $hooks = $cfg.hooks
  $changed = $false

  $existingP = @()
  if ($hooks.PSObject.Properties['PreToolUse'] -and $null -ne $hooks.PreToolUse) { $existingP = @($hooks.PreToolUse) }
  if (Find-Existing $existingP 'enforce-pwsh.ps1') {
    Info 'Claude Code: 已有 enforce-pwsh.ps1 注册，跳过（幂等）'
  } else {
    $hook = [pscustomobject]@{
      type = 'command'
      command = 'pwsh -NoProfile -File "' + $guardPath + '"'
    }
    $arr = $existingP
    $arr += [pscustomobject]@{ matcher = 'Bash|Write|Edit'; hooks = @($hook) }
    $hooks | Add-Member -Force -MemberType NoteProperty -Name PreToolUse -Value $arr
    $changed = $true
    Info 'Claude Code: 已注册 PreToolUse 护栏（matcher: Bash|Write|Edit）'
  }

  if ($timePath) {
    $existingU = @()
    if ($hooks.PSObject.Properties['UserPromptSubmit'] -and $null -ne $hooks.UserPromptSubmit) { $existingU = @($hooks.UserPromptSubmit) }
    if (Find-Existing $existingU 'time-context.py') {
      Info 'Claude Code: 已有 time-context.py 注册，跳过（幂等）'
    } else {
      $th = [pscustomobject]@{
        type = 'command'
        command = '"' + $pythonExe + '" "' + $timePath + '"'
      }
      $arrU = $existingU
      $arrU += [pscustomobject]@{ hooks = @($th) }
      $hooks | Add-Member -Force -MemberType NoteProperty -Name UserPromptSubmit -Value $arrU
      $changed = $true
      Info 'Claude Code: 已注册 UserPromptSubmit 时间注入'
    }
  }

  if ($changed) {
    Save-WithVerify $cfg $ClaudeConfig
    Info ('Claude Code 配置已更新（备份: ' + $ClaudeConfig + '.bak-win-command-guard）')
  }
} else {
  Info ('未发现 Claude Code 配置（' + $ClaudeConfig + '），跳过')
}

# ---------- 4) 收尾 ----------
Info '完成。重启宿主 agent 后生效；可用 selftest.ps1 自检。'
if (-not (Test-Path $ZcodeConfig) -and -not (Test-Path $ClaudeConfig)) {
  Info '提示：未检测到受支持的宿主，请参考 references/porting.md 手工注册。'
}
