#!/usr/bin/env bash
set -euo pipefail

SESSION_NAME="vscode-tunnel"
ENV_FILE="$HOME/.vscode-tunnel/env.sh"
NOTIFY_EMAIL="${TUNNEL_NOTIFY_EMAIL:-}"
NOTIFY_LOCK="$HOME/.vscode-tunnel/.auth-notified"

log() { echo "[watchdog] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

notify_auth_needed() {
    local reason="$1"
    # Capture tmux pane to extract auth URL and device code
    local pane_content
    pane_content=$("$TMUX_BIN" capture-pane -t "$SESSION_NAME" -p 2>/dev/null || echo "")

    local auth_url
    auth_url=$(echo "$pane_content" | grep -oP 'https://github\.com/login/device|https://microsoft\.com/devicelogin' | head -1 || echo "")
    local device_code
    device_code=$(echo "$pane_content" | grep -oP 'use code \K[A-Z0-9-]+' | head -1 || echo "")

    log "CRITICAL: $reason"
    log "CRITICAL: Auth URL: ${auth_url:-not found in tmux}"
    log "CRITICAL: Device code: ${device_code:-not found in tmux}"
    log "CRITICAL: Manual fix: tmux attach -t $SESSION_NAME"

    # Send email notification (only once until resolved)
    if [ -n "$NOTIFY_EMAIL" ] && [ ! -f "$NOTIFY_LOCK" ]; then
        local subject="[TUNNEL ALERT] $(hostname -s): re-authentication required"
        local body="VS Code tunnel on $(hostname -s) needs manual re-authentication.

Reason: $reason
Time: $(date)

Auth URL: ${auth_url:-not found - attach to tmux to see}
Device Code: ${device_code:-not found - attach to tmux to see}

To fix, SSH/attach and run:
  tmux attach -t $SESSION_NAME

Or open the auth URL above and enter the device code."

        python3 - "$NOTIFY_EMAIL" "$subject" "$body" <<'PYEOF' 2>/dev/null \
import sys, smtplib, os
from email.mime.text import MIMEText
to, subj, body = sys.argv[1], sys.argv[2], sys.argv[3]
smtp_host = os.environ.get("TUNNEL_SMTP_HOST", "smtp.gmail.com")
smtp_port = int(os.environ.get("TUNNEL_SMTP_PORT", "587"))
smtp_user = os.environ.get("TUNNEL_SMTP_USER", "")
smtp_pass = os.environ.get("TUNNEL_SMTP_PASS", "")
if not smtp_user or not smtp_pass:
    print("SMTP credentials not configured"); sys.exit(1)
msg = MIMEText(body)
msg["Subject"] = subj
msg["From"] = smtp_user
msg["To"] = to
s = smtplib.SMTP(smtp_host, smtp_port, timeout=15)
s.starttls()
s.login(smtp_user, smtp_pass)
s.sendmail(smtp_user, [to], msg.as_string())
s.quit()
PYEOF
            && log "Email notification sent to $NOTIFY_EMAIL" \
            || log "WARNING: failed to send email notification"
        touch "$NOTIFY_LOCK"
    elif [ -f "$NOTIFY_LOCK" ]; then
        log "Email already sent (remove $NOTIFY_LOCK to re-notify)"
    fi
}

# ---- Source env.sh ----
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

TMUX_BIN=$(command -v tmux) || { log "ERROR: tmux not found"; exit 1; }

# ---- Check 0: auth token exists? ----
TOKEN_FILE="$HOME/.vscode/cli/token.json"
if [ ! -f "$TOKEN_FILE" ]; then
    notify_auth_needed "Auth token $TOKEN_FILE is missing"
    exit 1
fi

# ---- Check 0.5: tunnel waiting for auth? (process alive but showing login prompt) ----
# Only capture visible pane area — auth prompt stays on screen while waiting
if "$TMUX_BIN" has-session -t "$SESSION_NAME" 2>/dev/null; then
    PANE_TEXT=$("$TMUX_BIN" capture-pane -t "$SESSION_NAME" -p 2>/dev/null || echo "")
    if echo "$PANE_TEXT" | grep -qP 'use code [A-Z0-9-]+' || \
       echo "$PANE_TEXT" | grep -q 'How would you like to log in' || \
       echo "$PANE_TEXT" | grep -q 'login/device' || \
       echo "$PANE_TEXT" | grep -q 'devicelogin'; then
        notify_auth_needed "Tunnel is waiting for device code authentication"
        exit 1
    fi
fi

# Clear notification lock if tunnel is healthy (auth was completed)
if [ -f "$NOTIFY_LOCK" ]; then
    rm -f "$NOTIFY_LOCK"
    log "Auth issue resolved, cleared notification lock"
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
RESTART_COUNT_FILE="$HOME/.vscode-tunnel/.restart-count"
if [ "$CONNECTIONS" -eq 0 ]; then
    # Track consecutive no-connection restarts
    COUNT=$(cat "$RESTART_COUNT_FILE" 2>/dev/null || echo "0")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$RESTART_COUNT_FILE"
    if [ "$COUNT" -ge 3 ]; then
        # 3+ consecutive failures — likely auth issue, not transient
        notify_auth_needed "Tunnel has failed to connect $COUNT times in a row (possible auth or config issue)"
        exit 1
    fi
    log "FAIL: code tunnel process (PID=$TUNNEL_PID) has no active TCP connections (attempt $COUNT/3), restarting service"
    systemctl --user restart vscode-tunnel.service
    exit 0
fi
# Reset restart counter on success
if [ -f "$RESTART_COUNT_FILE" ]; then
    rm -f "$RESTART_COUNT_FILE"
fi

log "OK: tunnel running (PID=$TUNNEL_PID, state=$PROC_STATE, connections=$CONNECTIONS)"
