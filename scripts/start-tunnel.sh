#!/usr/bin/env bash
set -euo pipefail

SESSION_NAME="vscode-tunnel"
ENV_FILE="$HOME/.vscode-tunnel/env.sh"
CODE_BIN="$HOME/.vscode-tunnel/bin/code"
LOG_DIR="$HOME/.vscode-tunnel/logs"
LOG_FILE="$LOG_DIR/tunnel.log"
TUNNEL_NAME="$(hostname -s)"

log() { echo "[start-tunnel] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# ---- 1. Source env.sh and verify tmux ----
if [ ! -f "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE not found. Run install.sh first."
    exit 1
fi
source "$ENV_FILE"

TMUX_BIN=$(command -v tmux) || { log "ERROR: tmux not found in PATH"; exit 1; }
log "Using tmux: $TMUX_BIN"

# ---- 2. Auto-heal: download code CLI if missing ----
if [ ! -x "$CODE_BIN" ]; then
    log "code CLI not found at $CODE_BIN, downloading..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  CLI_OS="cli-alpine-x64" ;;
        aarch64) CLI_OS="cli-alpine-arm64" ;;
        *)       log "ERROR: unsupported architecture: $ARCH"; exit 1 ;;
    esac
    mkdir -p "$(dirname "$CODE_BIN")"
    curl -fSL "https://code.visualstudio.com/sha/download?build=stable&os=$CLI_OS" -o /tmp/vscode-cli.tar.gz
    tar -xzf /tmp/vscode-cli.tar.gz -C "$(dirname "$CODE_BIN")/"
    rm -f /tmp/vscode-cli.tar.gz
    if [ ! -x "$CODE_BIN" ]; then
        log "ERROR: download succeeded but $CODE_BIN is not executable"
        exit 1
    fi
    log "code CLI downloaded successfully"
fi

# ---- 3. Clean up stale tmux session and lock files ----
"$TMUX_BIN" kill-session -t "$SESSION_NAME" 2>/dev/null || true
LOCK_FILE="$HOME/.vscode/cli/tunnel-stable.lock"
if [ -f "$LOCK_FILE" ]; then
    rm -f "$LOCK_FILE"
    log "Removed stale tunnel lock file"
fi
log "Cleaned up stale tmux session and lock files (if any)"

# ---- 4. Wait for network ----
MAX_WAIT=120
WAITED=0
log "Waiting for network (max ${MAX_WAIT}s)..."
until host tunnels.api.visualstudio.com >/dev/null 2>&1; do
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        log "WARNING: network timeout after ${MAX_WAIT}s, starting anyway (watchdog will retry)"
        break
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done
if [ "$WAITED" -lt "$MAX_WAIT" ]; then
    log "Network ready after ${WAITED}s"
fi

# ---- 5. Log rotation ----
mkdir -p "$LOG_DIR"
if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 10485760 ]; then
    mv -f "${LOG_FILE}.2" "${LOG_FILE}.3" 2>/dev/null || true
    mv -f "${LOG_FILE}.1" "${LOG_FILE}.2" 2>/dev/null || true
    mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    log "Log rotated"
fi

# ---- 6. Create tmux session with remain-on-exit ----
"$TMUX_BIN" new-session -d -s "$SESSION_NAME" -x 200 -y 50
"$TMUX_BIN" set-option -t "$SESSION_NAME" remain-on-exit on
log "tmux session '$SESSION_NAME' created"

# ---- 7. Launch tunnel inside tmux ----
# Use tmux pipe-pane for logging instead of | tee, to preserve terminal interactivity
"$TMUX_BIN" pipe-pane -t "$SESSION_NAME" "cat >> $LOG_FILE"
"$TMUX_BIN" send-keys -t "$SESSION_NAME" \
    "$CODE_BIN tunnel --accept-server-license-terms --name $TUNNEL_NAME" Enter

log "Tunnel started in tmux session '$SESSION_NAME' with name '$TUNNEL_NAME'"
