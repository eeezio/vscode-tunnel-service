#!/usr/bin/env bash
set -euo pipefail

SESSION_NAME="vscode-tunnel"
ENV_FILE="$HOME/.vscode-tunnel/env.sh"

log() { echo "[stop-tunnel] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

TMUX_BIN=$(command -v tmux) || { log "WARNING: tmux not found, cannot kill session"; exit 0; }

if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
    "$TMUX_BIN" kill-session -t "$SESSION_NAME"
    log "tmux session '$SESSION_NAME' killed"
else
    log "tmux session '$SESSION_NAME' not found (already stopped)"
fi
