#!/bin/bash
# Kiro Telegram Bridge 启动脚本
#
# 使用方法:
#   export TELEGRAM_BOT_TOKEN="your_token"
#   ./start-kiro-bridge.sh
#
# 环境变量:
#   TELEGRAM_BOT_TOKEN - Telegram Bot Token (必需)
#   TMUX_SESSION       - tmux 会话名称 (默认: kiro)
#   PORT               - Bridge 监听端口 (默认: 8080)
#   KIRO_AGENT         - Kiro Agent 名称 (默认: telegram-bridge)
#   KIRO_MODEL         - Kiro 模型 (默认: claude-opus-4.5)
#   SKIP_TUNNEL        - 跳过 cloudflared tunnel (设置为 1 跳过)
#   WEBHOOK_URL        - 手动指定 Webhook URL (可选，自动检测 tunnel URL)

set -e

# ============ 颜色定义 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============ 配置 ============
TMUX_SESSION="${TMUX_SESSION:-kiro}"
PORT="${PORT:-8080}"
KIRO_AGENT="${KIRO_AGENT:-telegram-bridge}"
KIRO_MODEL="${KIRO_MODEL:-claude-opus-4.5}"

# ============ 检查环境 ============
echo -e "${GREEN}=== Kiro Telegram Bridge ===${NC}"

# 检查 TELEGRAM_BOT_TOKEN
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo -e "${RED}Error: TELEGRAM_BOT_TOKEN not set${NC}"
    echo "Please set: export TELEGRAM_BOT_TOKEN=\"your_token\""
    exit 1
fi

# 检查 kiro-cli
if ! command -v kiro-cli &> /dev/null; then
    echo -e "${RED}Error: kiro-cli not found${NC}"
    echo "Please install Kiro CLI first"
    exit 1
fi

# 检查 tmux
if ! command -v tmux &> /dev/null; then
    echo -e "${RED}Error: tmux not found${NC}"
    echo "Please install: brew install tmux"
    exit 1
fi

# 检查 cloudflared (可选)
if [ -z "$SKIP_TUNNEL" ] && ! command -v cloudflared &> /dev/null; then
    echo -e "${YELLOW}Warning: cloudflared not found${NC}"
    echo "Install with: brew install cloudflared"
    echo "Or set SKIP_TUNNEL=1 to skip tunnel setup"
    SKIP_TUNNEL=1
fi

# ============ 创建目录结构 ============
echo -e "${YELLOW}Creating directories...${NC}"
mkdir -p ~/.kiro/agents
mkdir -p ~/.kiro/hooks

# ============ 安装 Agent 配置 ============
AGENT_FILE=~/.kiro/agents/${KIRO_AGENT}.json
if [ ! -f "$AGENT_FILE" ]; then
    echo -e "${YELLOW}Installing Agent config: $AGENT_FILE${NC}"
    if [ -f "kiro-agent-config/telegram-bridge.json" ]; then
        cp kiro-agent-config/telegram-bridge.json "$AGENT_FILE"
    else
        cat > "$AGENT_FILE" << 'EOF'
{
  "name": "telegram-bridge",
  "description": "Telegram Bridge Agent",
  "tools": ["*"],
  "allowedTools": ["*"],
  "hooks": {
    "stop": [
      {
        "command": "~/.kiro/hooks/send-to-telegram.sh",
        "timeout_ms": 30000
      }
    ]
  },
  "includeMcpJson": true
}
EOF
    fi
fi

# ============ 安装 Hook 脚本 ============
HOOK_FILE=~/.kiro/hooks/send-to-telegram.sh
if [ ! -f "$HOOK_FILE" ]; then
    echo -e "${YELLOW}Installing Hook script: $HOOK_FILE${NC}"
    if [ -f "kiro-hooks/send-to-telegram.sh" ]; then
        cp kiro-hooks/send-to-telegram.sh "$HOOK_FILE"
    fi
fi
chmod +x "$HOOK_FILE" 2>/dev/null || true

# 更新 Hook 中的 Token
if [ -f "$HOOK_FILE" ]; then
    # 如果 hook 中还是默认 token，则更新
    if grep -q "YOUR_BOT_TOKEN_HERE" "$HOOK_FILE"; then
        echo -e "${YELLOW}Updating Bot Token in Hook...${NC}"
        sed -i.bak "s/YOUR_BOT_TOKEN_HERE/$TELEGRAM_BOT_TOKEN/" "$HOOK_FILE"
        rm -f "${HOOK_FILE}.bak"
    fi
fi

# ============ 启动 tmux 会话 ============
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo -e "${YELLOW}Creating tmux session: $TMUX_SESSION${NC}"
    tmux new-session -d -s "$TMUX_SESSION"
    sleep 1
    
    # 启动 Kiro CLI
    echo -e "${YELLOW}Starting Kiro CLI...${NC}"
    tmux send-keys -t "$TMUX_SESSION" "kiro-cli chat --trust-all-tools --agent $KIRO_AGENT --model $KIRO_MODEL" Enter
    
    echo -e "${GREEN}Kiro CLI started in tmux session '$TMUX_SESSION'${NC}"
    echo "To attach: tmux attach -t $TMUX_SESSION"
else
    echo -e "${GREEN}tmux session '$TMUX_SESSION' already exists${NC}"
fi

# ============ 启动 Bridge ============
echo ""
echo -e "${GREEN}Starting Bridge Server...${NC}"
echo "  Port: $PORT"
echo "  tmux: $TMUX_SESSION"
echo "  Agent: $KIRO_AGENT"
echo "  Model: $KIRO_MODEL"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# 导出环境变量供 bridge 使用
export TMUX_SESSION
export PORT
export KIRO_AGENT

# ============ 启动 Cloudflared Tunnel ============
TUNNEL_URL=""
if [ -z "$SKIP_TUNNEL" ]; then
    echo -e "${YELLOW}Starting Cloudflared Tunnel...${NC}"
    
    # 在后台启动 cloudflared，输出到临时文件
    TUNNEL_LOG=$(mktemp)
    cloudflared tunnel --url http://localhost:$PORT --protocol http2 > "$TUNNEL_LOG" 2>&1 &
    TUNNEL_PID=$!
    
    # 等待 tunnel URL 出现
    echo -n "  Waiting for tunnel URL"
    for i in {1..30}; do
        TUNNEL_URL=$(grep -o 'https://[^[:space:]]*\.trycloudflare\.com' "$TUNNEL_LOG" 2>/dev/null | head -1)
        if [ -n "$TUNNEL_URL" ]; then
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    
    if [ -n "$TUNNEL_URL" ]; then
        echo -e "${GREEN}  Tunnel URL: $TUNNEL_URL${NC}"
        
        # 等待 DNS 传播
        echo -e "${YELLOW}  Waiting for DNS propagation...${NC}"
        sleep 5
        
        # ============ 设置 Telegram Webhook ============
        echo -e "${YELLOW}Setting Telegram Webhook...${NC}"
        
        # 重试设置 webhook，最多 3 次
        for attempt in 1 2 3; do
            WEBHOOK_RESULT=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=${TUNNEL_URL}")
            
            if echo "$WEBHOOK_RESULT" | grep -q '"ok":true'; then
                echo -e "${GREEN}  Webhook set successfully${NC}"
                break
            else
                if [ $attempt -lt 3 ]; then
                    echo -e "${YELLOW}  Attempt $attempt failed, retrying in 3 seconds...${NC}"
                    sleep 3
                else
                    echo -e "${RED}  Failed to set webhook after 3 attempts: $WEBHOOK_RESULT${NC}"
                    echo -e "${YELLOW}  You can manually set webhook later:${NC}"
                    echo "  curl \"https://api.telegram.org/bot\${TELEGRAM_BOT_TOKEN}/setWebhook?url=${TUNNEL_URL}\""
                fi
            fi
        done
    else
        echo -e "${RED}  Failed to get tunnel URL${NC}"
        echo "  Check log: $TUNNEL_LOG"
    fi
    
    # 清理函数
    cleanup() {
        echo ""
        echo -e "${YELLOW}Stopping...${NC}"
        if [ -n "$TUNNEL_PID" ]; then
            kill $TUNNEL_PID 2>/dev/null || true
        fi
        rm -f "$TUNNEL_LOG"
        exit 0
    }
    trap cleanup INT TERM
else
    echo -e "${YELLOW}Skipping tunnel setup (SKIP_TUNNEL is set)${NC}"
    if [ -n "$WEBHOOK_URL" ]; then
        echo -e "${YELLOW}Setting Telegram Webhook to: $WEBHOOK_URL${NC}"
        curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook?url=${WEBHOOK_URL}"
    fi
fi

# 启动 bridge
python3 bridge_kiro.py
