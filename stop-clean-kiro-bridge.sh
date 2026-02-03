#!/bin/bash
# Kiro Telegram Bridge 停止和清理脚本
#
# 使用方法:
#   ./stop-clean-kiro-bridge.sh
#
# 功能:
#   - 停止 Bridge Server (Python 进程)
#   - 停止 Cloudflared Tunnel
#   - 关闭 tmux 会话
#   - 清理状态文件和配置
#
# 环境变量:
#   TMUX_SESSION - tmux 会话名称 (默认: kiro)

set -e

# ============ 颜色定义 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============ 配置 ============
TMUX_SESSION="${TMUX_SESSION:-kiro}"
KIRO_DIR="$HOME/.kiro"

echo -e "${RED}=== Stopping Kiro Telegram Bridge ===${NC}"

# ============ 停止 Bridge Server ============
echo -e "${YELLOW}Stopping Bridge Server...${NC}"

BRIDGE_PIDS=$(pgrep -f "python.*bridge_kiro.py" 2>/dev/null || true)
if [ -n "$BRIDGE_PIDS" ]; then
    echo "  Found Bridge processes: $BRIDGE_PIDS"
    for pid in $BRIDGE_PIDS; do
        kill -TERM "$pid" 2>/dev/null || true
        echo "  Terminated PID: $pid"
    done
    sleep 1
    for pid in $BRIDGE_PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            echo "  Force killed PID: $pid"
        fi
    done
    echo -e "${GREEN}  Bridge Server stopped${NC}"
else
    echo "  No Bridge Server process found"
fi

# ============ 停止 Cloudflared Tunnel ============
echo -e "${YELLOW}Stopping Cloudflared Tunnel...${NC}"

TUNNEL_PIDS=$(pgrep -f "cloudflared tunnel" 2>/dev/null || true)
if [ -n "$TUNNEL_PIDS" ]; then
    echo "  Found Cloudflared processes: $TUNNEL_PIDS"
    for pid in $TUNNEL_PIDS; do
        kill -TERM "$pid" 2>/dev/null || true
        echo "  Terminated PID: $pid"
    done
    sleep 1
    for pid in $TUNNEL_PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            echo "  Force killed PID: $pid"
        fi
    done
    echo -e "${GREEN}  Cloudflared Tunnel stopped${NC}"
else
    echo "  No Cloudflared process found"
fi

# ============ 关闭 tmux 会话 ============
echo -e "${YELLOW}Closing tmux session: $TMUX_SESSION...${NC}"

if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    tmux kill-session -t "$TMUX_SESSION"
    echo -e "${GREEN}  tmux session '$TMUX_SESSION' closed${NC}"
else
    echo "  tmux session '$TMUX_SESSION' not found"
fi

# ============ 清理状态文件 ============
echo -e "${YELLOW}Cleaning up state files...${NC}"

# 清理 pending 文件
PENDING_FILE="$KIRO_DIR/telegram_pending"
if [ -f "$PENDING_FILE" ]; then
    rm -f "$PENDING_FILE"
    echo "  Removed: $PENDING_FILE"
fi

# 清理 chat_id 文件
CHAT_ID_FILE="$KIRO_DIR/telegram_chat_id"
if [ -f "$CHAT_ID_FILE" ]; then
    rm -f "$CHAT_ID_FILE"
    echo "  Removed: $CHAT_ID_FILE"
fi

# 清理 hook 脚本
HOOK_FILE="$KIRO_DIR/hooks/send-to-telegram.sh"
if [ -f "$HOOK_FILE" ]; then
    rm -f "$HOOK_FILE"
    echo "  Removed: $HOOK_FILE"
fi

# 清理 agent 配置
AGENT_FILE="$KIRO_DIR/agents/telegram-bridge.json"
if [ -f "$AGENT_FILE" ]; then
    rm -f "$AGENT_FILE"
    echo "  Removed: $AGENT_FILE"
fi

# 清理 hook 日志
HOOK_LOG="/tmp/kiro-telegram-hook.log"
if [ -f "$HOOK_LOG" ]; then
    rm -f "$HOOK_LOG"
    echo "  Removed: $HOOK_LOG"
fi

echo -e "${GREEN}=== Kiro Telegram Bridge Stopped ===${NC}"

# ============ 显示状态 ============
echo ""
echo "Status:"

# 检查 Bridge 进程
REMAINING_BRIDGE=$(pgrep -f "python.*bridge_kiro.py" 2>/dev/null || true)
if [ -n "$REMAINING_BRIDGE" ]; then
    echo -e "  ${RED}Warning: Some Bridge processes still running: $REMAINING_BRIDGE${NC}"
else
    echo -e "  ${GREEN}✓ No Bridge processes running${NC}"
fi

# 检查 Cloudflared 进程
REMAINING_TUNNEL=$(pgrep -f "cloudflared tunnel" 2>/dev/null || true)
if [ -n "$REMAINING_TUNNEL" ]; then
    echo -e "  ${RED}Warning: Some Cloudflared processes still running: $REMAINING_TUNNEL${NC}"
else
    echo -e "  ${GREEN}✓ No Cloudflared processes running${NC}"
fi

# 检查 tmux 会话
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo -e "  ${RED}Warning: tmux session '$TMUX_SESSION' still exists${NC}"
else
    echo -e "  ${GREEN}✓ tmux session '$TMUX_SESSION' closed${NC}"
fi
