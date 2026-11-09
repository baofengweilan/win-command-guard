# win-command-guard —— PreToolUse 命令护栏（PowerShell 7）
#
# 契约（适用于 ZCode / Claude Code 等采用同款钩子模型的宿主）：
#   stdin 收 JSON：{ "tool_name": "...", "tool_input": { ... } }
#   exit 0 = 放行；exit 2 = 拦截（原因写 stderr，同时给出正确改法）
#   JSON 解析失败一律放行——宁可漏拦，不误伤。
#
# 四道闸（全部来自 Windows 真实踩坑，案例时间线见 references/pitfalls.md）：
#   闸一（Bash）：命令必须显式走 pwsh 7；禁 node -e / 多行 python -c（内联脚本先落文件再跑）。
#   闸二（Write|Edit|ApplyPatch）：.bat/.cmd 必须GBK(ANSI) 可编码 + 纯 CRLF——
#       cmd 按代码页逐行解析 bat，UTF-8 中文会乱码碎行（'rem' 不是内部或外部命令）、
#       LF-only 会串行拆词（'ist' 不是内部或外部命令）。
#   闸三（Bash）：命令含 URL 且 URL 里的 & 裸露在双引号外——外层 cmd 不认 pwsh 单引号，
#       会把 & 当命令分隔符截断 URL 查询串。修法：URL 写进 pwsh 单引号串，或先落 .ps1 再 -File 执行。
#   闸四（Bash）：-Command 内层禁用转义双引号 \" 与双写 ""，收尾引号外禁挂管道 |——
#       cmd 解析 " 只认翻转、反斜杠是字面量，内层一转义，cmd 的引号状态就和 pwsh 的参数解析分叉，
#       "裸露区"里的 | & % 会被 cmd 当自己的语法执行（python -c 嵌套转义碎掉、
#       Select-Object 被 cmd 当程序跑）。内层字符串一律 pwsh 单引号；要双引号字面量/JSON/
#       多层嵌套 → 先落 .ps1 再 -File 执行。
#
# 合规快车道（动手前先选对路，护栏是保险丝不是老师；2026-11-07 增）：
#   · 相同字符串多处替换 → Edit 工具 replace_all 一次搞定，禁止逐个 Edit 刷次数。
#   · 短模式高频替换/筛选 → pwsh 单引号 -replace / Where-Object 一行，别绕道逐个改。
#   · 大量不同内容/多层嵌套引号/JSON 拼装 → 先用写文件工具落 .ps1（.py），再 pwsh -NoProfile -File 执行。
#   · 标准命令模板（内联 UTF-8，中文输出恒安全，不依赖 profile）：
#       pwsh -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Set-Location <绝对路径>; <原命令>"
#
# 注册方式：运行同目录 install.ps1（自动检测宿主并写入配置），或参考 references/porting.md 手工注册。

$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $json = $raw | ConvertFrom-Json } catch { exit 0 }  # 解析不了就不拦：宁可漏拦，不误伤
$tool = $json.tool_name
# 注意：绝不能用 $input 做变量名——它是 PowerShell 自动变量（管道输入枚举器），
# stdin 被管道喂入时已被绑定，赋值会静默失败，导致 $cmd 恒为 null、全护栏失效。
$toolInput = $json.tool_input

# ---------- 闸二：Write / Edit 写 .bat/.cmd 的编码与换行检查 ----------
if ($tool -in @('Write', 'Edit', 'ApplyPatch') -and $toolInput.file_path) {
    $path = [string]$toolInput.file_path
    if ($path -match '\.(bat|cmd)$') {
        # 待检文本：Write 查整份 content；Edit 查新片段 new_string
        $text = if ($null -ne $toolInput.content) { [string]$toolInput.content } else { [string]$toolInput.new_string }
        if ([string]::IsNullOrEmpty($text)) { exit 0 }

        # 坑一：必须是 GBK(ANSI) 可编码（UTF-8 独有字符如 emoji/部分符号 cmd 会读成乱码）
        $gbkStrict = [System.Text.Encoding]::GetEncoding(
            936,
            [System.Text.EncoderExceptionFallback]::new(),
            [System.Text.DecoderExceptionFallback]::new()
        )
        try {
            $null = $gbkStrict.GetBytes($text)
        } catch {
            [Console]::Error.WriteLine(
                '命令护栏拦截：.bat/.cmd 内容含 GBK(ANSI) 无法表示的字符（emoji 或生僻符号），' +
                'cmd 会把它解析成乱码命令。改用纯 ASCII 文案，或先用写文件工具生成 .py 转存 GBK。'
            )
            exit 2
        }

        # 坑二：必须纯 CRLF 换行（LF-only 会让 cmd 串行拆词）
        if ($text -match "(?<!`r)`n") {
            [Console]::Error.WriteLine(
                '命令护栏拦截：.bat/.cmd 必须使用 CRLF（\r\n）换行，LF-only 会让 cmd 串行解析、' +
                '把命令拆成碎片。用 \r\n 连接每一行后再写入。'
            )
            exit 2
        }
    }
    exit 0
}

# ---------- 闸一：Bash 命令规范 ----------
if ($tool -ne 'Bash') { exit 0 }  # 其他工具不归本护栏管
$cmd = $toolInput.command
if (-not $cmd) { exit 0 }

# 规矩一：命令必须显式走 pwsh（禁 cmd 裸跑、禁老版 powershell）
# 2026-11-07：标准模板内联 UTF-8 输出编码，-NoProfile 恒安全，删除"中文输出别用 -NoProfile"例外分支——
#   例外靠模型现场判断，判断错就乱码返工一轮；内联后无分支可错。
if ($cmd -notmatch '(?i)(^|[\s;&|(])pwsh(\.exe)?\s') {
    [Console]::Error.WriteLine(
        '命令护栏拦截：命令必须用 pwsh 7 执行。改写为 ' +
        'pwsh -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Set-Location <绝对路径>; <原命令>" 后重试；' +
        '多步操作先 Set-Location 或用绝对路径。老版 powershell 同样禁用。内层字符串用 pwsh 单引号（禁 \" 转义，见规矩四）。'
    )
    exit 2
}

# 规矩二：复杂内联脚本先落文件（cmd/转义是 Windows 上反复踩坑的源头）
if ($cmd -match '(?i)\bnode\s+-e\b') {
    [Console]::Error.WriteLine(
        '命令护栏拦截：不要用 node -e 内联脚本（shell 转义坑）。先用写文件工具落成 .mjs/.js 文件，再 pwsh 里 node <文件> 执行。'
    )
    exit 2
}
$hasNewline = $cmd -match "`n"
if ($hasNewline -and $cmd -match '(?i)\bpython(\.exe)?\b.*\s-c\s') {
    [Console]::Error.WriteLine(
        '命令护栏拦截：多行 python -c 输出会被吞/转义出错。先用写文件工具落成 .py 文件，再 pwsh 里 python <文件> 执行。'
    )
    exit 2
}

# 规矩三：URL 里的裸 & 会被外层 cmd 截断（cmd 只保护双引号内的 &，不认 pwsh 单引号）
if ($cmd -match '(?i)https?://') {
    $inDq = $false
    $bareAmp = $false
    foreach ($ch in $cmd.ToCharArray()) {
        if ($ch -eq '"') { $inDq = -not $inDq }
        elseif ($ch -eq '&' -and -not $inDq) { $bareAmp = $true; break }
    }
    if ($bareAmp) {
        [Console]::Error.WriteLine(
            '命令护栏拦截：命令里有 URL 且 & 裸露在双引号外——外层 cmd 会把 & 当命令分隔符截断 URL。' +
            'URL 写在 pwsh 单引号字符串里（外层双引号已经保护它，别用 \" 转义），或把请求/下载逻辑先用写文件工具' +
            '落成 .ps1 再 pwsh -NoProfile -File 执行。'
        )
        exit 2
    }
}

# 规矩四：引号嵌套与 cmd 层管道
# 4a: 内层 \" / "" —— cmd 解析 " 只认翻转、反斜杠是字面量，内层一转义，cmd 的引号状态
#     就和 pwsh 的参数解析分叉，"裸露区"里的 | & % 归 cmd 管。内层一律单引号：
#     Write-Host ('PUSH_EXIT=' + $LASTEXITCODE)；要双引号字面量/JSON/多层嵌套 → 落 .ps1。
if ($cmd -match '\\"' -or $cmd -match '""') {
    [Console]::Error.WriteLine(
        '命令护栏拦截：-Command 内层不要出现 \" 或 ""——cmd 的引号状态会和 pwsh 分叉，' +
        '裸露区里的 | & % 会被 cmd 当自己的语法执行。内层字符串一律用 pwsh 单引号，' +
        '如 Write-Host (''PUSH_EXIT='' + $LASTEXITCODE)；路径用 Join-Path 拼、URL/参数整体单引号；' +
        '需要双引号字面量/JSON/多层嵌套，先用写文件工具落成 .ps1 再 pwsh -NoProfile -File 执行。'
    )
    exit 2
}
# 4b: 收尾引号之外不许挂 cmd 层管道 |——Select-Object/ForEach-Object 是 pwsh 内建命令，
#     cmd 层不存在，会报"不是内部或外部命令"。整条管道写进引号内。|| 不在拦截之列。
$inDq = $false
$barePipe = $false
$chars = $cmd.ToCharArray()
for ($i = 0; $i -lt $chars.Length; $i++) {
    if ($chars[$i] -eq '"') { $inDq = -not $inDq }
    elseif (-not $inDq -and $chars[$i] -eq '|') {
        if ($i + 1 -lt $chars.Length -and $chars[$i + 1] -eq '|') { $i++; continue }
        $barePipe = $true; break
    }
}
if ($barePipe) {
    [Console]::Error.WriteLine(
        '命令护栏拦截：pwsh -Command 的收尾双引号外不许再挂管道 |——Select-Object/ForEach-Object ' +
        '这些是 pwsh 内建命令，cmd 层不存在，会报"不是内部或外部命令"。把整条管道写进引号内。'
    )
    exit 2
}

exit 0
