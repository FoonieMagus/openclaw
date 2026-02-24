#!/usr/bin/env bash
set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get the repository root directory
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${BLUE}OpenClaw Config Setup${NC}"
echo "====================="
echo

# Prompt for config name
read -p "Enter config name: " CONFIG_NAME

if [[ -z "$CONFIG_NAME" ]]; then
  echo -e "${RED}Error: Config name cannot be empty${NC}"
  exit 1
fi

# Sanitize config name (remove special characters, spaces)
CONFIG_NAME=$(echo "$CONFIG_NAME" | tr -cd '[:alnum:]_-')

CONFIG_BASE_DIR="$REPO_ROOT/config/$CONFIG_NAME"

# Check if directory already exists
if [[ -d "$CONFIG_BASE_DIR" ]]; then
  echo -e "${BLUE}Config directory already exists: $CONFIG_BASE_DIR${NC}"
  echo
  echo "What would you like to do?"
  echo "  1) Update existing config (re-enter tokens, keep directory structure)"
  echo "  2) Override config (delete and recreate from scratch)"
  echo "  3) Pair Telegram device only"
  echo
  read -p "Choose an option [1/2/3]: " CONFIG_ACTION

  case "$CONFIG_ACTION" in
    1)
      echo
      echo -e "${BLUE}Updating existing config...${NC}"
      # Fall through to the config prompts below
      ;;
    2)
      echo
      echo -e "${RED}This will delete all existing config in $CONFIG_BASE_DIR${NC}"
      read -p "Are you sure? [y/N]: " CONFIRM_OVERRIDE
      if [[ "$CONFIRM_OVERRIDE" != "y" && "$CONFIRM_OVERRIDE" != "Y" ]]; then
        echo "Aborted."
        exit 0
      fi
      echo -e "${BLUE}Removing existing config...${NC}"
      rm -rf "$CONFIG_BASE_DIR"
      echo -e "${GREEN}✓${NC} Removed $CONFIG_BASE_DIR"
      echo
      # Create fresh directory structure
      echo -e "${BLUE}Creating directories...${NC}"
      mkdir -p "$CONFIG_BASE_DIR/config"
      mkdir -p "$CONFIG_BASE_DIR/workspace"
      echo -e "${GREEN}✓${NC} Created $CONFIG_BASE_DIR/config/"
      echo -e "${GREEN}✓${NC} Created $CONFIG_BASE_DIR/workspace/"
      echo
      ;;
    3)
      echo
      ENV_FILE="$CONFIG_BASE_DIR/.env"
      DOCKER_PROJECT="openclaw-$CONFIG_NAME"
      DOCKER_CMD="docker compose --env-file $ENV_FILE -p $DOCKER_PROJECT exec"

      echo -e "${BLUE}Approve Telegram device pairing:${NC}"
      echo "Send /start to your Telegram bot to get a pairing code."
      read -p "Enter the pairing code: " PAIRING_CODE

      if [[ -z "$PAIRING_CODE" ]]; then
        echo -e "${RED}Error: Pairing code cannot be empty${NC}"
        exit 1
      fi

      echo "Approving Telegram pairing..."
      if $DOCKER_CMD openclaw-gateway node dist/index.js pairing approve telegram "$PAIRING_CODE"; then
        echo -e "${GREEN}✓${NC} Telegram bot paired successfully!"
      else
        echo -e "${RED}Error: Failed to approve Telegram pairing${NC}"
        exit 1
      fi

      echo
      echo -e "${GREEN}Done!${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid option. Please choose 1, 2, or 3.${NC}"
      exit 1
      ;;
  esac
else
  # Create directory structure
  echo -e "${BLUE}Creating directories...${NC}"
  mkdir -p "$CONFIG_BASE_DIR/config"
  mkdir -p "$CONFIG_BASE_DIR/workspace"
  echo -e "${GREEN}✓${NC} Created $CONFIG_BASE_DIR/config/"
  echo -e "${GREEN}✓${NC} Created $CONFIG_BASE_DIR/workspace/"
  echo
fi

# Prompt for gateway port
read -p "Enter gateway port (e.g., 48780): " GATEWAY_PORT

# Validate port number
if ! [[ "$GATEWAY_PORT" =~ ^[0-9]+$ ]] || [[ "$GATEWAY_PORT" -lt 1024 ]] || [[ "$GATEWAY_PORT" -gt 65535 ]]; then
  echo -e "${RED}Error: Invalid port number. Must be between 1024 and 65535${NC}"
  exit 1
fi

# Calculate bridge port (gateway port + 100)
BRIDGE_PORT=$((GATEWAY_PORT + 100))

# Check if ports are available
if lsof -Pi :$GATEWAY_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo -e "${RED}Error: Gateway port $GATEWAY_PORT is already in use${NC}"
  exit 1
fi

if lsof -Pi :$BRIDGE_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo -e "${RED}Error: Bridge port $BRIDGE_PORT is already in use${NC}"
  exit 1
fi

echo -e "${GREEN}✓${NC} Ports $GATEWAY_PORT and $BRIDGE_PORT are available"
echo

# Create .env file
ENV_FILE="$CONFIG_BASE_DIR/.env"

echo -e "${BLUE}Creating .env file...${NC}"

# Prompt for Claude Code token
read -p "Enter Claude Code token: " CLAUDE_TOKEN

if [[ -z "$CLAUDE_TOKEN" ]]; then
  echo -e "${RED}Error: Claude Code token cannot be empty${NC}"
  exit 1
fi

# Create auth-profiles.json
echo -e "${BLUE}Creating auth profiles...${NC}"
AUTH_PROFILES_DIR="$CONFIG_BASE_DIR/config/agents/main/agent"
mkdir -p "$AUTH_PROFILES_DIR"

TIMESTAMP=$(( $(date +%s) * 1000 ))

cat > "$AUTH_PROFILES_DIR/auth-profiles.json" <<EOF
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "token",
      "provider": "anthropic",
      "token": "$CLAUDE_TOKEN"
    }
  },
  "lastGood": {
    "anthropic": "anthropic:default"
  },
  "usageStats": {
    "anthropic:default": {
      "lastUsed": $TIMESTAMP,
      "errorCount": 0
    }
  }
}
EOF

echo -e "${GREEN}✓${NC} Created $AUTH_PROFILES_DIR/auth-profiles.json"
echo

# Prompt for Telegram bot token
read -p "Enter Telegram bot token: " TG_BOT_TOKEN

if [[ -z "$TG_BOT_TOKEN" ]]; then
  echo -e "${RED}Error: Telegram bot token cannot be empty${NC}"
  exit 1
fi

# Generate secure gateway auth token (48-character hex string)
echo -e "${BLUE}Generating secure gateway auth token...${NC}"
AUTH_TOKEN=$(openssl rand -hex 24)

if [[ -z "$AUTH_TOKEN" ]]; then
  echo -e "${RED}Error: Failed to generate auth token${NC}"
  exit 1
fi

cat > "$ENV_FILE" <<EOF
OPENCLAW_CONFIG_DIR=$CONFIG_BASE_DIR/config/
OPENCLAW_WORKSPACE_DIR=$CONFIG_BASE_DIR/workspace/
OPENCLAW_GATEWAY_PORT=$GATEWAY_PORT
OPENCLAW_BRIDGE_PORT=$BRIDGE_PORT
OPENCLAW_GATEWAY_TOKEN=$AUTH_TOKEN
EOF

echo -e "${GREEN}✓${NC} Created $ENV_FILE"
echo

# Create openclaw.json config file
echo -e "${BLUE}Creating OpenClaw configuration...${NC}"
CONFIG_FILE="$CONFIG_BASE_DIR/config/openclaw.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

cat > "$CONFIG_FILE" <<EOF
{
  "meta": {
    "lastTouchedVersion": "2026.2.6",
    "lastTouchedAt": "$TIMESTAMP"
  },
  "wizard": {
    "lastRunAt": "$TIMESTAMP",
    "lastRunVersion": "2026.2.6",
    "lastRunCommand": "configure",
    "lastRunMode": "local"
  },
  "auth": {
    "profiles": {
      "anthropic:default": {
        "provider": "anthropic",
        "mode": "token"
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace",
      "compaction": {
        "mode": "safeguard"
      },
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      }
    }
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto"
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "botToken": "$TG_BOT_TOKEN",
      "groupPolicy": "allowlist",
      "streamMode": "partial"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "$AUTH_TOKEN"
    },
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    }
  },
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      }
    }
  }
}
EOF

echo -e "${GREEN}✓${NC} Created $CONFIG_FILE"
echo

# Launch Docker Compose
echo -e "${BLUE}Starting Docker containers...${NC}"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
  echo -e "${RED}Error: Docker is not running. Please start Docker and try again.${NC}"
  exit 1
fi

# Launch with unique project name for isolation
DOCKER_PROJECT="openclaw-$CONFIG_NAME"

if ! docker compose --env-file "$ENV_FILE" -p "$DOCKER_PROJECT" up -d; then
  echo -e "${RED}Error: Failed to start Docker containers${NC}"
  echo "Check Docker logs for more details:"
  echo -e "  ${BLUE}docker compose -p $DOCKER_PROJECT logs${NC}"
  exit 1
fi

echo -e "${GREEN}✓${NC} Docker containers started successfully"
echo

echo "Configuration details:"
echo "  Config name:        $CONFIG_NAME"
echo "  Base directory:     $CONFIG_BASE_DIR"
echo "  Gateway port:       $GATEWAY_PORT"
echo "  Bridge port:        $BRIDGE_PORT"
echo "  Gateway auth token: $AUTH_TOKEN"
echo "  Docker project:     $DOCKER_PROJECT"
echo

# Device Pairing Flow
echo -e "${BLUE}Device Pairing Instructions:${NC}"
echo -e "1. Your Gateway Token: ${GREEN}$AUTH_TOKEN${NC}"
echo "2. Opening gateway overview page in your browser..."
echo "3. On the page, paste the token above as 'Gateway Token' and tap 'Connect'"
echo

# Open browser
if open "http://127.0.0.1:$GATEWAY_PORT/overview" 2>/dev/null; then
  sleep 1
else
  echo "Please open: http://127.0.0.1:$GATEWAY_PORT/overview"
fi

# Poll for device pairing requests
echo "Waiting for device pairing request..."
PENDING_FILE="$CONFIG_BASE_DIR/config/devices/pending.json"
DOCKER_CMD="docker compose --env-file $ENV_FILE -p $DOCKER_PROJECT exec"
REQUEST_ID=""

while [ -z "$REQUEST_ID" ]; do
  sleep 2

  # Check if pending.json exists and is not empty
  if [ -f "$PENDING_FILE" ] && [ -s "$PENDING_FILE" ]; then
    # Extract the first request ID from the JSON keys
    REQUEST_ID=$(grep -Eo '"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"' "$PENDING_FILE" | head -1 | tr -d '"')

    if [ -n "$REQUEST_ID" ]; then
      echo -e "${GREEN}✓${NC} Device pairing request received: $REQUEST_ID"
    fi
  else
    echo -n "."
  fi
done

echo

# Auto-approve the device
echo "Approving device pairing request..."
if $DOCKER_CMD openclaw-gateway node dist/index.js devices approve "$REQUEST_ID"; then
  echo -e "${GREEN}✓${NC} Device paired successfully!"
else
  echo -e "${RED}Error: Failed to approve device${NC}"
  exit 1
fi

echo
echo -e "${BLUE}Telegram Bot Pairing:${NC}"
echo "1. Open Telegram and find your bot"
echo "2. Send /start to the bot"
echo "3. You will receive a pairing code"
echo

read -p "Enter the pairing code from Telegram: " PAIRING_CODE

if [[ -z "$PAIRING_CODE" ]]; then
  echo -e "${RED}Error: Pairing code cannot be empty${NC}"
  exit 1
fi

echo "Approving Telegram pairing..."
if $DOCKER_CMD openclaw-gateway node dist/index.js pairing approve telegram "$PAIRING_CODE"; then
  echo -e "${GREEN}✓${NC} Telegram bot paired successfully!"
else
  echo -e "${RED}Error: Failed to approve Telegram pairing${NC}"
  exit 1
fi

echo
echo -e "${GREEN}Setup complete! Your OpenClaw gateway is ready.${NC}"
echo
echo "To view logs:"
echo -e "  ${BLUE}docker compose -p $DOCKER_PROJECT logs -f${NC}"
echo
echo "To stop containers:"
echo -e "  ${BLUE}docker compose -p $DOCKER_PROJECT down${NC}"
