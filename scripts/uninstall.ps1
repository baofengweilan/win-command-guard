#Requires -Version 7
<#
.SYNOPSIS
  win-command-guard 卸载器：从宿主配置中移除本技能注册的钩子。

.DESCRIPTION
  按脚本文件名（enforce-pwsh.ps1 / time-context.py）在各宿主配置里定位并移除相关条目；
  写前自动备份，写后回读校验。加 -RemoveFiles 同时删除安装目录里的脚本。
  不会动 profile 的 UTF-8 设置（如需移除请手工删除对应行）。

.EXAMPLE
  pwsh -ExecutionPolicy Bypass -File uninstall.ps1 -RemoveFiles
#>
[CmdletBinding()]
param(
  [switch]$RemoveFiles,
  [string]$InstallDir = (Join-Path $env:USERPROFILE '.win-command-guard'),
  [string]$ZcodeConfig = (Join-Path $env:USERPROFILE '.zcode\cli\config.json'),
  [string]$ClaudeConfig = (Join-Path $env:USERPROFILE '.claude\settings.json')
)

$ErrorActionPreference = 'Stop'
function Info($m) { Write-Host ('[win-command-guard] ' + $m) }
function Get-Json($path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
function Save-Json($cfg, $path) {
  $cfg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8
}
function Backup-File($path) {
  if (Test-Path $path) {
    Copy-Item -LiteralPath $path -Destination ($path + '.bak-win-command-guard') -Force
  }
}

# 判断某个 hook 是否引用了我们的脚本
function Test-IsOurs($h) {
  $blob = ([string]$h.command) + ' ' + (@($h.args) -join ' ')
  return ($blob -match [regex]::Escape('enforce-pwsh.ps1')) -or ($blob -match [regex]::Escape('time-context.py'))
}

# 在"事件数组"里过滤掉我们的条目；返回 (新数组, 是否有变化)
function Remove-Ours($groups) {
  $kept = @()
  $changed = $false
  foreach ($grp in @($groups)) {
    $keptHooks = @()
    foreach ($h in @($grp.hooks)) {
      if (Test-IsOurs $h) { $changed = $true } else { $keptHooks += $h }
    }
    if ($keptHooks.Count -gt 0) {
      $grp.hooks = $keptHooks
      $kept += $grp
    } else {
      $changed = $true   # 整组都是我们的 → 丢弃该组
    }
  }
  return @($kept, $changed)
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

# ---------- ZCode ----------
if (Test-Path $ZcodeConfig) {
  $cfg = Get-Json $ZcodeConfig
  $changed = $false
  if ($cfg.PSObject.Properties['hooks'] -and $null -ne $cfg.hooks -and
      $cfg.hooks.PSObject.Properties['events'] -and $null -ne $cfg.hooks.events) {
    $events = $cfg.hooks.events
    foreach ($evt in @('PreToolUse', 'UserPromptSubmit')) {
      if ($events.PSObject.Properties[$evt] -and $null -ne $events.$evt) {
        $res = Remove-Ours @($events.$evt)
        if ($res[1]) {
          $events | Add-Member -Force -MemberType NoteProperty -Name $evt -Value $res[0]
          $changed = $true
          Info ('ZCode: 已移除 ' + $evt + ' 里的护栏条目')
        }
      }
    }
  }
  if ($changed) {
    Save-WithVerify $cfg $ZcodeConfig
    Info ('ZCode 配置已更新（备份: ' + $ZcodeConfig + '.bak-win-command-guard）')
  } else {
    Info 'ZCode: 无本技能的注册条目'
  }
} else {
  Info ('未发现 ZCode 配置（' + $ZcodeConfig + '），跳过')
}

# ---------- Claude Code ----------
if (Test-Path $ClaudeConfig) {
  $cfg = Get-Json $ClaudeConfig
  $changed = $false
  if ($cfg.PSObject.Properties['hooks'] -and $null -ne $cfg.hooks) {
    $hooks = $cfg.hooks
    foreach ($evt in @('PreToolUse', 'UserPromptSubmit')) {
      if ($hooks.PSObject.Properties[$evt] -and $null -ne $hooks.$evt) {
        $res = Remove-Ours @($hooks.$evt)
        if ($res[1]) {
          $hooks | Add-Member -Force -MemberType NoteProperty -Name $evt -Value $res[0]
          $changed = $true
          Info ('Claude Code: 已移除 ' + $evt + ' 里的护栏条目')
        }
      }
    }
  }
  if ($changed) {
    Save-WithVerify $cfg $ClaudeConfig
    Info ('Claude Code 配置已更新（备份: ' + $ClaudeConfig + '.bak-win-command-guard）')
  } else {
    Info 'Claude Code: 无本技能的注册条目'
  }
} else {
  Info ('未发现 Claude Code 配置（' + $ClaudeConfig + '），跳过')
}

# ---------- 文件 ----------
if ($RemoveFiles -and (Test-Path $InstallDir)) {
  Remove-Item -LiteralPath $InstallDir -Recurse -Force
  Info ('已删除安装目录: ' + $InstallDir)
}

Info '卸载完成。重启宿主 agent 后生效。'
