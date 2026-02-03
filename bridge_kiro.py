#!/usr/bin/env python3
"""Kiro CLI <-> Telegram Bridge
迁移自 claudecode-telegram，适配 Kiro CLI

主要变更:
1. tmux 会话名: claude -> kiro
2. 状态文件路径: ~/.claude/ -> ~/.kiro/
3. 启动命令: claude --dangerously-skip-permissions -> kiro-cli chat --trust-all-tools
4. 会话恢复: --resume {id} -> --resume / --resume-picker
5. 移除: Ralph Loop 功能
"""

import os
import json
import subprocess
import threading
import time
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# ============ 配置常量 ============
TMUX_SESSION = os.environ.get("TMUX_SESSION", "kiro")
CHAT_ID_FILE = os.path.expanduser("~/.kiro/telegram_chat_id")
PENDING_FILE = os.path.expanduser("~/.kiro/telegram_pending")
BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
PORT = int(os.environ.get("PORT", "8080"))

# Kiro Agent 名称 (可选)
KIRO_AGENT = os.environ.get("KIRO_AGENT", "telegram-bridge")

BOT_COMMANDS = [
    {"command": "clear", "description": "Clear conversation"},
    {"command": "resume", "description": "Resume session (shows options)"},
    {"command": "stop", "description": "Interrupt Kiro (Escape)"},
    {"command": "status", "description": "Check tmux status"},
]

BLOCKED_COMMANDS = [
    "/mcp", "/help", "/settings", "/config", "/model", "/compact", "/cost",
    "/doctor", "/init", "/login", "/logout", "/memory", "/permissions",
    "/pr", "/review", "/terminal", "/vim", "/approved-tools", "/listen",
    "/loop", "/continue_"  # 不再支持
]


def telegram_api(method, data):
    """调用 Telegram Bot API"""
    if not BOT_TOKEN:
        return None
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/{method}",
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"Telegram API error: {e}")
        return None


def setup_bot_commands():
    """注册 Bot 命令"""
    result = telegram_api("setMyCommands", {"commands": BOT_COMMANDS})
    if result and result.get("ok"):
        print("Bot commands registered")


def send_typing_loop(chat_id):
    """持续发送 typing 状态"""
    while os.path.exists(PENDING_FILE):
        telegram_api("sendChatAction", {"chat_id": chat_id, "action": "typing"})
        time.sleep(4)


def tmux_exists():
    """检查 tmux 会话是否存在"""
    return subprocess.run(
        ["tmux", "has-session", "-t", TMUX_SESSION], 
        capture_output=True
    ).returncode == 0


def tmux_send(text, literal=True):
    """向 tmux 会话发送文本"""
    cmd = ["tmux", "send-keys", "-t", TMUX_SESSION]
    if literal:
        cmd.append("-l")
    cmd.append(text)
    subprocess.run(cmd)


def tmux_send_enter():
    """发送 Enter 键"""
    subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "Enter"])


def tmux_send_escape():
    """发送 Escape 键"""
    subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "Escape"])


class Handler(BaseHTTPRequestHandler):
    """HTTP 请求处理器"""
    
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            update = json.loads(body)
            if "callback_query" in update:
                self.handle_callback(update["callback_query"])
            elif "message" in update:
                self.handle_message(update)
        except Exception as e:
            print(f"Error: {e}")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"OK")

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Kiro-Telegram Bridge")

    def handle_callback(self, cb):
        """处理内联键盘回调"""
        chat_id = cb.get("message", {}).get("chat", {}).get("id")
        data = cb.get("data", "")
        telegram_api("answerCallbackQuery", {"callback_query_id": cb.get("id")})

        if not tmux_exists():
            self.reply(chat_id, "tmux session not found")
            return

        if data == "resume_picker":
            # 使用 --resume-picker 交互式选择
            tmux_send_escape()
            time.sleep(0.2)
            tmux_send("/quit")
            tmux_send_enter()
            time.sleep(0.5)
            cmd = f"kiro-cli chat --resume-picker --trust-all-tools"
            if KIRO_AGENT:
                cmd += f" --agent {KIRO_AGENT}"
            tmux_send(cmd)
            tmux_send_enter()
            self.reply(chat_id, "Opening session picker...")

        elif data == "resume_recent":
            # 使用 --resume 继续最近会话
            tmux_send_escape()
            time.sleep(0.2)
            tmux_send("/quit")
            tmux_send_enter()
            time.sleep(0.5)
            cmd = f"kiro-cli chat --resume --trust-all-tools"
            if KIRO_AGENT:
                cmd += f" --agent {KIRO_AGENT}"
            tmux_send(cmd)
            tmux_send_enter()
            self.reply(chat_id, "Resuming most recent session...")

    def handle_message(self, update):
        """处理普通消息和命令"""
        msg = update.get("message", {})
        text = msg.get("text", "")
        chat_id = msg.get("chat", {}).get("id")
        msg_id = msg.get("message_id")
        
        if not text or not chat_id:
            return

        # 保存 chat_id
        with open(CHAT_ID_FILE, "w") as f:
            f.write(str(chat_id))

        if text.startswith("/"):
            cmd = text.split()[0].lower()

            # /status - 检查状态
            if cmd == "/status":
                status = "running" if tmux_exists() else "not found"
                self.reply(chat_id, f"tmux '{TMUX_SESSION}': {status}")
                return

            # /stop - 中断
            if cmd == "/stop":
                if tmux_exists():
                    tmux_send_escape()
                if os.path.exists(PENDING_FILE):
                    os.remove(PENDING_FILE)
                self.reply(chat_id, "Interrupted")
                return

            # /clear - 清除对话
            if cmd == "/clear":
                if not tmux_exists():
                    self.reply(chat_id, "tmux not found")
                    return
                # 先中断当前操作并等待 Kiro CLI 回到空闲状态
                tmux_send_escape()
                time.sleep(1.0)  # 等待更长时间
                tmux_send_escape()
                time.sleep(1.0)
                # 清除输入行
                subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "C-c"])
                time.sleep(0.5)
                subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "C-u"])
                time.sleep(0.5)
                # 发送 /clear 命令
                subprocess.run(["tmux", "send-keys", "-t", TMUX_SESSION, "-l", "/clear"])
                tmux_send_enter()
                time.sleep(1.0)  # 等待确认框出现
                tmux_send("y")
                tmux_send_enter()
                self.reply(chat_id, "Cleared")
                return

            # /resume - 恢复会话
            if cmd == "/resume":
                if not tmux_exists():
                    self.reply(chat_id, "tmux not found")
                    return
                kb = [
                    [{"text": "📋 Resume most recent", "callback_data": "resume_recent"}],
                    [{"text": "🔍 Pick from sessions", "callback_data": "resume_picker"}]
                ]
                telegram_api("sendMessage", {
                    "chat_id": chat_id, 
                    "text": "Select resume option:", 
                    "reply_markup": {"inline_keyboard": kb}
                })
                return

            # 不再支持的命令
            if cmd == "/continue_":
                self.reply(chat_id, "Use /resume instead")
                return

            if cmd == "/loop":
                self.reply(chat_id, "Ralph Loop not supported in Kiro CLI")
                return

            # 阻止的命令
            if cmd in BLOCKED_COMMANDS:
                self.reply(chat_id, f"'{cmd}' not supported (interactive)")
                return

        # 普通消息处理
        print(f"[{chat_id}] {text[:50]}...")
        
        # 创建 pending 标记
        with open(PENDING_FILE, "w") as f:
            f.write(str(int(time.time())))

        # 添加消息反应
        if msg_id:
            telegram_api("setMessageReaction", {
                "chat_id": chat_id, 
                "message_id": msg_id, 
                "reaction": [{"type": "emoji", "emoji": "✅"}]
            })

        # 检查 tmux 会话
        if not tmux_exists():
            self.reply(chat_id, "tmux not found")
            os.remove(PENDING_FILE)
            return

        # 启动 typing 状态循环
        threading.Thread(target=send_typing_loop, args=(chat_id,), daemon=True).start()
        
        # 发送消息到 Kiro
        tmux_send(text)
        tmux_send_enter()

    def reply(self, chat_id, text):
        """发送回复"""
        telegram_api("sendMessage", {"chat_id": chat_id, "text": text})

    def log_message(self, *args):
        pass


def main():
    if not BOT_TOKEN:
        print("Error: TELEGRAM_BOT_TOKEN not set")
        return
    
    # 确保目录存在
    Path(CHAT_ID_FILE).parent.mkdir(parents=True, exist_ok=True)
    
    setup_bot_commands()
    print(f"Kiro-Telegram Bridge on :{PORT} | tmux: {TMUX_SESSION}")
    
    try:
        HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nStopped")


if __name__ == "__main__":
    main()
