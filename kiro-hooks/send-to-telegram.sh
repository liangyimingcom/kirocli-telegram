#!/bin/bash
# Kiro CLI Stop hook - sends response back to Telegram
# 
# 安装步骤:
# 1. 复制到 ~/.kiro/hooks/send-to-telegram.sh
# 2. chmod +x ~/.kiro/hooks/send-to-telegram.sh
# 3. 在 Agent 配置中添加 stop hook
#
# 与 Claude Code 的主要区别:
# 1. 输入格式: {"hook_event_name": "stop", "cwd": "..."}
# 2. 没有 transcript_path，使用 tmux capture-pane 获取输出

# ============ 配置 ============
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-YOUR_BOT_TOKEN_HERE}"
CHAT_ID_FILE=~/.kiro/telegram_chat_id
PENDING_FILE=~/.kiro/telegram_pending
TMUX_SESSION="${TMUX_SESSION:-kiro}"
DEBUG_LOG=/tmp/kiro-telegram-hook.log

# ============ 读取 hook 输入 ============
INPUT=$(cat)
echo "[$(date)] Hook triggered: $INPUT" >> "$DEBUG_LOG"

# ============ 检查 pending 文件 ============
# 只响应 Telegram 发起的消息
[ ! -f "$PENDING_FILE" ] && exit 0

PENDING_TIME=$(cat "$PENDING_FILE" 2>/dev/null)
NOW=$(date +%s)

# 检查超时 (10分钟)
if [ -z "$PENDING_TIME" ] || [ $((NOW - PENDING_TIME)) -gt 600 ]; then
    rm -f "$PENDING_FILE"
    echo "[$(date)] Pending file timeout, exiting" >> "$DEBUG_LOG"
    exit 0
fi

# 检查 chat_id 文件
if [ ! -f "$CHAT_ID_FILE" ]; then
    rm -f "$PENDING_FILE"
    echo "[$(date)] No chat_id file, exiting" >> "$DEBUG_LOG"
    exit 0
fi

CHAT_ID=$(cat "$CHAT_ID_FILE")
echo "[$(date)] Processing for chat_id: $CHAT_ID" >> "$DEBUG_LOG"

# ============ 获取 Kiro 输出 ============
TMPFILE=$(mktemp)

# 使用 tmux capture-pane 获取最近输出
# -p: 输出到 stdout
# -S: 起始行 (负数表示从当前位置往上)
tmux capture-pane -t "$TMUX_SESSION" -p -S -200 > "$TMPFILE" 2>/dev/null

if [ ! -s "$TMPFILE" ]; then
    rm -f "$TMPFILE" "$PENDING_FILE"
    echo "[$(date)] No output captured, exiting" >> "$DEBUG_LOG"
    exit 0
fi

echo "[$(date)] Captured $(wc -l < "$TMPFILE") lines" >> "$DEBUG_LOG"

# ============ 处理并发送响应 ============
python3 - "$TMPFILE" "$CHAT_ID" "$TELEGRAM_BOT_TOKEN" << 'PYEOF'
import sys
import re
import json
import urllib.request

tmpfile, chat_id, token = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(tmpfile) as f:
        content = f.read().strip()
except Exception as e:
    print(f"Error reading file: {e}", file=sys.stderr)
    sys.exit(0)

if not content:
    sys.exit(0)

# ============ 提取助手响应 ============
# Kiro CLI 输出格式分析:
# - 用户输入提示符: [agent-name] XX% !> 或 [agent-name] XXK !>
# - 助手响应以 > 开头（单独一行或后跟内容）
# - 工具调用后会有第二段响应（最终结果）
# - 我们需要提取最后一个 > 开头的响应块

lines = content.split('\n')

# 查找最后一个用户输入位置
last_user_idx = -1
for i, line in enumerate(lines):
    # 匹配 [agent-name] XX% !> 或 [agent-name] XXK !> 格式
    if re.match(r'^\[[\w-]+\]\s+\d+[%K]\s*!?>', line):
        last_user_idx = i

# 提取用户输入之后的内容
if last_user_idx >= 0:
    response_lines = lines[last_user_idx + 1:]
else:
    response_lines = lines[-50:]

# 查找最后一个以 > 开头的响应块（最终结果）
# 响应块格式: > 1. xxx 或单独的 > 后跟内容
last_response_start = -1
for i, line in enumerate(response_lines):
    # 匹配响应开始: > 后跟内容（不是空的 >）
    if re.match(r'^>\s*\S', line):
        last_response_start = i

# 如果找到最后一个响应块，只提取该块
if last_response_start >= 0:
    response_lines = response_lines[last_response_start:]

# 过滤掉 hook 状态行和其他系统输出
filtered_lines = []
for line in response_lines:
    # 跳过 hook 状态行: ✓ 1 of 1 hooks finished in X.XX s
    if re.match(r'^[✓✗]?\s*\d+\s+of\s+\d+\s+hooks?\s+finished', line):
        continue
    # 跳过 Credits/Time 行: ▸ Credits: 0.09 • Time: 5s
    if re.match(r'^[▸▹]?\s*Credits:', line):
        continue
    # 跳过空的提示符行
    if re.match(r'^\[[\w-]+\]\s+\d+[%K]\s*!?>\s*$', line):
        continue
    # 跳过工具调用行
    if re.match(r'^I will run the following command:', line):
        break  # 遇到工具调用就停止（我们只要最后的响应）
    if re.match(r'^I\'ll create the following file:', line):
        break
    if re.match(r'^Replacing:', line):
        break
    if re.match(r'^\+\s+\d+:', line):  # 文件内容行
        break
    if re.match(r'^- Completed in', line):
        break
    if re.match(r'^Purpose:', line):
        break
    filtered_lines.append(line)

response_lines = filtered_lines

# 过滤掉控制字符和 ANSI 转义序列
def clean_line(line):
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    line = ansi_escape.sub('', line)
    line = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '', line)
    return line

cleaned_lines = [clean_line(line) for line in response_lines]
text = '\n'.join(cleaned_lines).strip()

# 移除响应开头的 > 符号
text = re.sub(r'^>\s?', '', text, flags=re.MULTILINE)

if not text:
    sys.exit(0)

# ============ 截断长文本 ============
if len(text) > 4000:
    text = text[:4000] + "\n..."

# ============ Markdown 转 HTML ============
def esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

blocks, inlines = [], []

# 处理代码块
text = re.sub(
    r'```(\w*)\n?(.*?)```', 
    lambda m: (blocks.append((m.group(1) or '', m.group(2))), f"\x00B{len(blocks)-1}\x00")[1], 
    text, 
    flags=re.DOTALL
)

# 处理内联代码
text = re.sub(
    r'`([^`\n]+)`', 
    lambda m: (inlines.append(m.group(1)), f"\x00I{len(inlines)-1}\x00")[1], 
    text
)

# 转义 HTML 特殊字符
text = esc(text)

# 处理粗体和斜体
text = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', text)
text = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<i>\1</i>', text)

# 还原代码块
for i, (lang, code) in enumerate(blocks):
    if lang:
        replacement = f'<pre><code class="language-{lang}">{esc(code.strip())}</code></pre>'
    else:
        replacement = f'<pre>{esc(code.strip())}</pre>'
    text = text.replace(f"\x00B{i}\x00", replacement)

# 还原内联代码
for i, code in enumerate(inlines):
    text = text.replace(f"\x00I{i}\x00", f'<code>{esc(code)}</code>')

# ============ 发送到 Telegram ============
def send(txt, mode=None):
    data = {"chat_id": chat_id, "text": txt}
    if mode:
        data["parse_mode"] = mode
    try:
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{token}/sendMessage", 
            json.dumps(data).encode(), 
            {"Content-Type": "application/json"}
        )
        response = urllib.request.urlopen(req, timeout=10)
        result = json.loads(response.read())
        return result.get("ok", False)
    except Exception as e:
        print(f"Send error: {e}", file=sys.stderr)
        return False

# 尝试发送 HTML 格式，失败则回退到纯文本
if not send(text, "HTML"):
    print("HTML send failed, trying plain text", file=sys.stderr)
    with open(tmpfile) as f:
        plain_text = f.read()[:4096]
    send(plain_text)

print("Message sent successfully", file=sys.stderr)
PYEOF

# ============ 清理 ============
rm -f "$TMPFILE" "$PENDING_FILE"
echo "[$(date)] Hook completed" >> "$DEBUG_LOG"
exit 0
