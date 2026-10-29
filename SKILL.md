---
name: win-command-guard
description: 给 Windows 上的 AI coding agent 一键安装"命令护栏"：强制命令走 PowerShell 7，拦截引号转义、URL 截断、bat 编码等致命写法，统一 UTF-8 防中文乱码，可选注入时间与市场时段。当用户抱怨 agent 在 Windows 上命令报错循环、命令碎裂、写坏 bat、中文乱码，或想给 agent 加命令安全护栏时使用。
---

# Win Command Guard —— Windows 命令护栏

一套从**真实踩坑**中沉淀出来的 agent 命令护栏（事故时间线见 `references/pitfalls.md`）：

| 组件 | 文件 | 作用 |
|---|---|---|
| 护栏本体 | `scripts/enforce-pwsh.ps1` | PreToolUse 钩子：命令执行前拦截 4 类致命写法，并教 agent 正确改法 |
| 一键安装 | `scripts/install.ps1` | 自动检测宿主（ZCode / Claude Code）并注册钩子；幂等、自动备份 |
| 卸载 | `scripts/uninstall.ps1` | 从宿主配置中移除本技能的注册 |
| 自检 | `scripts/selftest.ps1` | 9 个行为样例 + 语法 + 编码，一键验证 |
| 时间注入（可选） | `scripts/time-context.py` | 向对话注入当前时间与 A 股时段，防 agent 凭记忆猜日期 |

## 何时使用
- agent 在 Windows 上"命令翻车"：报错循环、'不是内部或外部命令'、命令碎裂、`python -c` 输出被吞
- agent 写的 `.bat/.cmd` 运行后中文乱码 / 整行碎掉
- 命令输出中文乱码
- 新机器初始化，想提前预防以上全部问题

## 使用步骤
1. **前置**：确认已装 PowerShell 7（**MSI 版**，不要从商店装 MSIX）：
   ```powershell
   winget install --id Microsoft.PowerShell -e
   ```
2. **安装**（在包根目录执行）：
   ```powershell
   pwsh -ExecutionPolicy Bypass -File scripts/install.ps1
   ```
   可选开关：`-WithTimeContext`（同时装时间注入，需 python 在 PATH）、`-SetProfileUtf8`（顺带统一 profile 编码，防中文乱码）
3. **自检**：
   ```powershell
   pwsh -ExecutionPolicy Bypass -File scripts/selftest.ps1
   ```
   应显示「全部通过 ✓」。
4. **重启宿主 agent**，钩子生效。

## 护栏规则（四道闸）

| 闸 | 拦什么 | 为什么（真实事故） |
|---|---|---|
| 闸一 | 命令不以 pwsh 开头；`node -e`；多行 `python -c` | 强制 PowerShell 7；内联脚本的转义在 cmd 层必炸 |
| 闸二 | 写 `.bat/.cmd` 时内容非 GBK 可编码、或非 CRLF 换行 | cmd 按代码页解析 bat：UTF-8 中文→乱码碎行，LF-only→串行拆词 |
| 闸三 | URL 中的 `&` 裸露在双引号外 | 外层 cmd 把 `&` 当命令分隔符，URL 查询串被悄悄截断 |
| 闸四 | 内层 `\"` / `""` 转义；收尾引号外挂 `|` 管道 | cmd 与 pwsh 的引号状态分叉，"裸露区"里的 `\| & %` 被 cmd 当自己的语法执行 |

**拦截不是终点**：每条拦截信息都附「标准改法」，agent 通常一次重试即过。
**失败安全**：JSON 解析失败的输入一律放行——宁可漏拦，不误伤。

## 注意
- 涉及中文输出的命令**不要用 `-NoProfile`**（会绕过 profile 的 UTF-8 设置而乱码）——护栏的拦截提示里也带这句提醒。
- 移植到其他宿主（事件名 / matcher / 进程型差异；无钩子机制宿主的退化方案）见 `references/porting.md`。
