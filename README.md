# vscode-tunnel-service

Systemd user service that runs a VS Code tunnel inside tmux, with automatic startup on boot and a watchdog that checks health every 5 minutes.

## Prerequisites

- Linux with systemd (tested on Ubuntu 24.04)
- tmux
- curl
- `host` command (from `dnsutils` / `bind-utils`)
- `ss` command (from `iproute2`, usually pre-installed)

## Quick Start

```bash
git clone <repo-url>
cd vscode-tunnel-service
./install.sh
```

If linger is not enabled, the installer will prompt you to run:

```bash
sudo loginctl enable-linger $(whoami)
```

On first run, you may need to authenticate the tunnel:

```bash
tmux attach -t vscode-tunnel
# Follow the GitHub/Microsoft login prompts
# Ctrl+B, D to detach
```

## What It Does

1. **On boot:** Starts a tmux session named `vscode-tunnel` and runs `code tunnel` inside it
2. **Every 5 minutes:** A watchdog checks tunnel health (5-layer check):
   - tmux session exists?
   - `code tunnel` process alive?
   - Process not zombie?
   - Network reachable?
   - Process has active TCP connections?
3. **If unhealthy:** Automatically restarts the tunnel service

## Useful Commands

```bash
# Attach to tunnel session (see live output)
tmux attach -t vscode-tunnel

# View tunnel log file
cat ~/.vscode-tunnel/logs/tunnel.log

# View systemd logs
journalctl --user -u vscode-tunnel
journalctl --user -u vscode-tunnel-watchdog

# Check service status
systemctl --user status vscode-tunnel
systemctl --user status vscode-tunnel-watchdog.timer

# Manually restart
systemctl --user restart vscode-tunnel

# Manually trigger watchdog
systemctl --user start vscode-tunnel-watchdog.service
```

## Uninstall

```bash
./uninstall.sh
```

## File Locations

| File | Path |
|------|------|
| Scripts & config | `~/.vscode-tunnel/` |
| VS Code CLI | `~/.vscode-tunnel/bin/code` |
| Environment config | `~/.vscode-tunnel/env.sh` |
| Tunnel log | `~/.vscode-tunnel/logs/tunnel.log` |
| Systemd units | `~/.config/systemd/user/vscode-tunnel*` |
