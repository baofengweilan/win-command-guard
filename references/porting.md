# 移植指南：把护栏接到其他 agent 宿主

## 1. 钩子契约（宿主无关）

护栏本体 `enforce-pwsh.ps1` 只依赖一个极简契约，任何宿主满足即可接入：

```
触发时机：工具调用前（PreToolUse）
输入：stdin 收 JSON  { "tool_name": "...", "tool_input": { ... } }
输出：exit 0 = 放行；exit 2 = 拦截（原因写 stderr，宿主应展示给 agent）
     stdout 可选输出 JSON（如 {"hookSpecificOutput": {"additionalContext": "..."}}）
失败安全：JSON 解析失败 → exit 0（宁可漏拦，不误伤）
```

`time-context.py` 同理：stdin（可空）→ stdout 输出 `{"additionalContext": "..."}`，exit 0。

## 2. 宿主对照表

| 概念 | ZCode | Claude Code | 其他宿主 |
|---|---|---|---|
| 配置文件 | `~/.zcode/cli/config.json` → `hooks.events.<Event>` | `~/.claude/settings.json` → `hooks.<Event>` | 找"工具调用前钩子/前置校验"类机制 |
| 事件名 | `PreToolUse` / `UserPromptSubmit`（共 7 个事件） | 同名（两者高度兼容） | 映射到"工具调用前 / 用户提交时" |
| matcher | 区分大小写正则，匹配工具名 | 同 | 改成目标宿主工具名（`Bash`/`Shell`/`Execute`…） |
| 进程型 | `type: "process"` + `command`/`args`/`timeoutMs`(毫秒) | `type: "command"` + 命令字符串 | 多数宿主支持"执行外部命令" |
| 总开关 | 配置文件钩子需 `hooks.enabled: true` | 存在即生效 | 视宿主而定 |

**ZCode 注册示例**（install.ps1 自动完成）：

```json
{
  "hooks": {
    "enabled": true,
    "events": {
      "PreToolUse": [
        { "matcher": "Bash|Write|Edit",
          "hooks": [ { "type": "process", "command": "pwsh",
            "args": ["-NoProfile", "-File", "<安装目录>\\enforce-pwsh.ps1"],
            "timeoutMs": 10000, "statusMessage": "检查命令规范与 bat 编码/换行" } ] }
      ]
    }
  }
}
```

**Claude Code 注册示例**：

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|Write|Edit",
        "hooks": [ { "type": "command",
          "command": "pwsh -NoProfile -File \"<安装目录>\\enforce-pwsh.ps1\"" } ] }
    ]
  }
}
```

## 3. 宿主没有钩子机制怎么办（退化方案）

1. **规则文件**：把下面这份"行为规范"写进宿主的系统提示 / 规则文档（AGENTS.md 等），
   让 agent 自律；
2. **包装脚本**：命令统一经 `pwsh -File guard-wrapper.ps1 -- <原命令>` 执行，
   在入口处做同样校验；
3. **编码兜底**（无论有无钩子都建议做）：profile 统一 UTF-8（见 SKILL.md / pitfalls.md）。

### 行为规范（护栏期望 agent 遵守的写法）

- 命令显式 `pwsh`；内层字符串用**单引号**；禁 `\"` / `""`。
- 管道写在（外层）引号内；复杂脚本**先落成 `.ps1` 再 `-File` 跑**。
- URL 里的 `&` 包进双引号（或先落 `.ps1`）。
- 写 `.bat/.cmd`：GBK 可编码 + CRLF。
- 涉及中文输出：用标准模板 `pwsh -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Set-Location <绝对路径>; <原命令>"`（内联 UTF-8，`-NoProfile` 恒安全）。
- 相同字符串多处替换：用编辑工具的 replace_all 一次完成，不要逐个改。
- 短模式高频替换/筛选：pwsh 单引号 `-replace` / `Where-Object` 一行。
- 大量不同内容 / 多层嵌套引号 / JSON 拼装：先落 `.ps1`（`.py`）再 `-File` 执行。
- 绝不在 PATH 放置冒充系统命令（`powershell` / `cmd`）的 shim——PATH 全机器共享，会误伤安装器与引导器；AI 用 7 靠显式 `pwsh`，不靠改系统的名字。

## 4. 前置依赖

- PowerShell 7（**MSI** 版）：`winget install --id Microsoft.PowerShell -e`
  （不要用 Microsoft Store 的 MSIX 版：受管目录、权限/路径易出问题）
- 时间注入组件（可选）：python 3 在 PATH
