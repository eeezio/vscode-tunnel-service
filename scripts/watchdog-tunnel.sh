#!/usr/bin/env bash
set -euo pipefail

SESSION_NAME="vscode-tunnel"
ENV_FILE="$HOME/.vscode-tunnel/env.sh"

log() { echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# ---- Source env.sh ----
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

TMUX_BIN=$(command -v tmux) || { log "ERROR: tmux not found"; exit 1; }

# ---- Check 0: auth token exists? ----
TOKEN_FILE="$HOME/.vscode/cli/token.json"
if [ ! -f "$TOKEN_FILE" ]; then
    log "CRITICAL: $TOKEN_FILE is missing! Tunnel requires manual re-authentication."
    log "CRITICAL: Run: tmux attach -t $SESSION_NAME  and complete the login flow."
    exit 1
fi

# ---- Check 1: tmux session exists? ----
if ! "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
    log "FAIL: tmux session '$SESSION_NAME' does not exist, restarting service"
    systemctl --user restart vscode-tunnel.service
    exit 0
fi

# ---- Check 2: code tunnel process alive? ----
TUNNEL_PID=$(pgrep -u "$USER" -f "code tunnel" || true)
if [ -z "$TUNNEL_PID" ]; then
    log "FAIL: code tunnel process not found, restarting service"
    systemctl --user restart vscode-tunnel.service
    exit 0
fi

# ---- Check 3: process not zombie? ----
PROC_STATE=$(ps -o state= -p "$TUNNEL_PID" 2>/dev/null || echo "X")
if [ "$PROC_STATE" = "Z" ]; then
    log "FAIL: code tunnel process (PID=$TUNNEL_PID) is zombie, restarting service"
    systemctl --user restart vscode-tunnel.service
    exit 0
fi

# ---- Check 4: network reachable? ----
if ! host tunnels.api.visualstudio.com >/dev/null 2>&1; then
    log "SKIP: network unreachable (DNS failed), skipping this round"
    exit 0
fi

# ---- Check 5: process has ESTABLISHED TCP connections? ----
CONNECTIONS=$(ss -tnp 2>/dev/null | grep "pid=$TUNNEL_PID" | grep -c "ESTAB" || echo "0")
if [ "$CONNECTIONS" -eq 0 ]; then
    log "FAIL: code tunnel process (PID=$TUNNEL_PID) has no active TCP connections, restarting service"
    systemctl --user restart vscode-tunnel.service
    exit 0
fi

log "OK: tunnel running (PID=$TUNNEL_PID, state=$PROC_STATE, connections=$CONNECTIONS)"
