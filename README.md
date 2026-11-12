[English](#win-command-guard) | [中文](#中文说明)

# Win Command Guard

> Keep AI agents from tripping over commands on Windows: a command guard forged from 4 real incidents, with one-click install and one-click self-check.

## What problem it solves

AI agents on Windows fail constantly when executing commands, and one failure often spirals into an "error loop" that burns tokens and time:

| Failure scene | Root cause |
|---|---|
| `'rem' is not recognized as an internal or external command` (commands appear randomly shredded) | cmd parses UTF-8 `.bat` files line-by-line as GBK; LF-only line breaks split words apart |
| Requests to URLs with a query string "silently lose parameters" | the outer cmd treats `&` inside the URL as a command separator and truncates it |
| `python -c` nested quotes swallow output; `'Select-Object' is not recognized as a command` | the quote states of cmd and pwsh diverge; the "bare zone" gets taken over by cmd |
| Chinese output turns into full-screen mojibake | the child process emits UTF-8 while the console decodes as GB2312; `-NoProfile` bypasses the profile's correction |

All of the above come from real incident records (2026-10-04 ~ 11-07); the reproduction and fixes are documented in `references/pitfalls.md`.

## Quick start

**Prerequisites**: Windows 10+ (x64); access to GitHub (use a mirror if downloads are blocked); admin rights for step ① (or accept the UAC prompt).

```powershell
# ⓪ get this package and enter it
git clone https://github.com/baofengweilan/win-command-guard.git
cd win-command-guard

# ① install PowerShell 7 (MSI; open a NEW terminal afterwards so `pwsh` is on PATH)
winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements

# ② one-click install (auto-registers for ZCode / Claude Code; other hosts get a pointer to references/porting.md)
pwsh -ExecutionPolicy Bypass -File scripts\install.ps1 -SetProfileUtf8

# ③ self-check (validates the guard itself: four-gate behavioral samples)
pwsh -ExecutionPolicy Bypass -File scripts\selftest.ps1
```

Two notes:
- The self-check validates the **guard itself**; to confirm the **hook is actually wired into your host**, restart the host and run a live probe — have the agent run a command that does not start with `pwsh`; it should get blocked with the standard fix.
- Other hosts: the guard files land in `%USERPROFILE%\.win-command-guard\`; wire them into your host per the contract in `references/porting.md`. Agents that support skills can also read `SKILL.md` and install themselves.

## How it works

```
agent issues a tool call → host fires PreToolUse → guard (reads JSON from stdin)
  ├─ safe     → exit 0, allow
  └─ dangerous → exit 2, block + stderr gives the "standard fix" → agent passes on the first retry
(JSON parse failure → allow: better to miss a block than to hurt a good command)
```

Four gates: ① enforce pwsh 7 ② .bat/.cmd encoding & line-break pre-check ③ bare `&` in URLs ④ quote escaping / pipe position (details in `SKILL.md`).

## Files

| File | Purpose |
|---|---|
| `SKILL.md` | skill entry: the agent reads this to know how to install and use it |
| `scripts/enforce-pwsh.ps1` | the guard itself (PreToolUse hook, four gates) |
| `scripts/install.ps1` | one-click install: auto-detects hosts, idempotent + auto-backup + read-back verification |
| `scripts/uninstall.ps1` | one-click uninstall: removes only this skill's registration |
| `scripts/selftest.ps1` | one-click self-check: syntax + 9 behavioral samples + encoding environment |
| `scripts/time-context.py` | optional component: injects current time and A-share market session into the conversation |
| `references/pitfalls.md` | pitfall handbook: the real incident and root cause behind every rule |
| `references/porting.md` | porting guide: hook contract + host-by-host comparison + fallback for hookless hosts |
| `LICENSE` | MIT |

## Quality

- `selftest.ps1`: syntax + 9 behavioral samples across the four gates, 10/10 passing on the dev machine;
- the installer was verified on real machines and in sandbox config: idempotent (re-install creates no duplicates), others' configs fully preserved, backup before write, auto-restore if read-back verification fails.

## License

MIT (see `LICENSE`).

---

# 中文说明

> 让 AI agent 在 Windows 上"命令不翻车"：4 道真实事故换来的命令护栏 + 一键安装 + 一键自检。

## 解决什么问题

AI agent 在 Windows 上执行命令时高频翻车，且一翻车就进入"报错循环"，烧 token、烧时间：

| 翻车现场 | 根因 |
|---|---|
| `'rem' 不是内部或外部命令`（命令像被随机切碎） | cmd 按 GBK 逐行解析 UTF-8 的 .bat；LF-only 换行会串行拆词 |
| 带查询串的 URL 请求"参数悄悄丢失" | 外层 cmd 把 URL 里的 `&` 当命令分隔符截断 |
| `python -c` 嵌套引号输出被吞；`'Select-Object' 不是内部或外部命令` | cmd 与 pwsh 引号状态分叉，"裸露区"被 cmd 接管 |
| 中文输出满屏乱码（"汽修二班"→"姹戒慨浜岀彮"） | 子进程输出 UTF-8、控制台按 GB2312 解码；`-NoProfile` 绕过了 profile 的修正 |

以上均来自真实事故记录（2026-10-04 ~ 11-07），复现与修复过程见 `references/pitfalls.md`。

## 快速开始

**前提**：Windows 10+（x64）；能访问 GitHub（下载被卡时用镜像或 Release 附件）；第 ① 步需要管理员权限（或允许 UAC 弹窗）。

```powershell
# ⓪ 获取本包并进入目录
git clone https://github.com/baofengweilan/win-command-guard.git
cd win-command-guard

# ① 安装 PowerShell 7（MSI 版；装完【新开一个终端】，pwsh 才会进 PATH）
winget install --id Microsoft.PowerShell -e --accept-source-agreements --accept-package-agreements

# ② 一键安装（ZCode / Claude Code 自动注册；其他宿主会提示按 references/porting.md 手工接入）
pwsh -ExecutionPolicy Bypass -File scripts\install.ps1 -SetProfileUtf8

# ③ 自检（验证护栏本体：四道闸行为样例）
pwsh -ExecutionPolicy Bypass -File scripts\selftest.ps1
```

两点说明：
- 自检验证的是**护栏本体**；「宿主是否真的挂上了钩子」请重启宿主后实测一次——让 agent 跑一条不以 pwsh 开头的命令，应被拦下并给出标准改法。
- 非 ZCode / Claude Code 宿主：护栏文件已就位（`%USERPROFILE%\.win-command-guard\`），按 `references/porting.md` 的契约接入你的宿主即可；支持 Skill 的 agent 也可以直接读 `SKILL.md` 自助安装。

## 工作原理

```
agent 发起工具调用 → 宿主触发 PreToolUse → 护栏（stdin 收 JSON）
  ├─ 安全 → exit 0 放行
  └─ 危险 → exit 2 拦截 + stderr 给出「标准改法」→ agent 一次重试即过
（JSON 解析失败 → 放行：宁可漏拦，不误伤）
```

四道闸：① 强制 pwsh 7　② .bat/.cmd 编码与换行预检　③ URL 裸 `&`　④ 引号转义 / 管道位置（详见 `SKILL.md`）。

## 文件清单

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 技能入口：agent 读它即知如何安装使用 |
| `scripts/enforce-pwsh.ps1` | 护栏本体（PreToolUse 钩子，四道闸） |
| `scripts/install.ps1` | 一键安装：自动探测宿主，幂等 + 自动备份 + 回读校验 |
| `scripts/uninstall.ps1` | 一键卸载：只移除本技能的注册 |
| `scripts/selftest.ps1` | 一键自检：语法 + 9 个行为样例 + 编码环境 |
| `scripts/time-context.py` | 可选组件：向对话注入当前时间与 A 股时段 |
| `references/pitfalls.md` | 踩坑手册：每条规则对应的真实事故与根因 |
| `references/porting.md` | 移植指南：钩子契约 + 各宿主对照表 + 无钩子宿主退化方案 |
| `LICENSE` | MIT |

## 质量

- `selftest.ps1`：语法 + 四道闸 9 个行为样例，开发机 10/10 通过；
- 安装器经真机与沙盒配置验证：幂等（重复安装不产生重复条目）、他人配置完整保留、写前备份、写后回读校验失败自动还原。

## 许可

MIT（见 `LICENSE`）。
