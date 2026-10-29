# Win Command Guard（Windows 命令护栏）

> 让 AI agent 在 Windows 上"命令不翻车"：4 道真实事故换来的命令护栏 + 一键安装 + 一键自检。

## 解决什么问题

AI agent 在 Windows 上执行命令时高频翻车，且一翻车就进入"报错循环"，烧 token、烧时间：

| 翻车现场 | 根因 |
|---|---|
| `'rem' 不是内部或外部命令`（命令像被随机切碎） | cmd 按 GBK 逐行解析 UTF-8 的 .bat；LF-only 换行会串行拆词 |
| 带查询串的 URL 请求"参数悄悄丢失" | 外层 cmd 把 URL 里的 `&` 当命令分隔符截断 |
| `python -c` 嵌套引号输出被吞；`'Select-Object' 不是内部或外部命令` | cmd 与 pwsh 引号状态分叉，"裸露区"被 cmd 接管 |
| 中文输出满屏乱码（"汽修二班"→"姹戒慨浜岀彮"） | 子进程输出 UTF-8、控制台按 GB2312 解码；`-NoProfile` 绕过了 profile 的修正 |

以上均来自真实事故记录（2026-10-04 ~ 10-21），复现与修复过程见 `references/pitfalls.md`。

## 快速开始（3 步）

```powershell
winget install --id Microsoft.PowerShell -e                            # ① PowerShell 7（MSI 版）
pwsh -ExecutionPolicy Bypass -File scripts/install.ps1 -SetProfileUtf8 # ② 一键安装
pwsh -ExecutionPolicy Bypass -File scripts/selftest.ps1                # ③ 自检：全绿 ✓
```

支持 ZCode / Claude Code 自动注册（幂等、自动备份）；其他宿主见 `references/porting.md`。

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
