#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.vscode-tunnel"
SYSTEMD_DIR="$HOME/.config/systemd/user"

log() { echo "[uninstall] $1"; }

log "=== VS Code Tunnel Service Uninstaller ==="

# ---- 1. Stop and disable services ----
log "Stopping and disabling services..."
systemctl --user stop vscode-tunnel-watchdog.timer 2>/dev/null || true
systemctl --user disable vscode-tunnel-watchdog.timer 2>/dev/null || true
systemctl --user stop vscode-tunnel.service 2>/dev/null || true
systemctl --user disable vscode-tunnel.service 2>/dev/null || true

# ---- 2. Remove systemd unit files ----
log "Removing systemd unit files..."
rm -f "$SYSTEMD_DIR/vscode-tunnel.service"
rm -f "$SYSTEMD_DIR/vscode-tunnel-watchdog.service"
rm -f "$SYSTEMD_DIR/vscode-tunnel-watchdog.timer"

# ---- 3. Reload systemd ----
systemctl --user daemon-reload

# ---- 4. Optionally remove install directory ----
if [ -d "$INSTALL_DIR" ]; then
    log ""
    log "Installation directory exists at: $INSTALL_DIR"
    read -p "Delete it? This will remove logs, code CLI, and all config. [y/N] " -r
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
        log "Deleted $INSTALL_DIR"
    else
        log "Kept $INSTALL_DIR"
    fi
fi

log ""
log "=== Uninstall complete ==="
log "Note: loginctl linger was NOT disabled. Disable manually if needed:"
log "    sudo loginctl disable-linger $(whoami)"
