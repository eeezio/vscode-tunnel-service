# vscode-tunnel-service

Systemd user service that automatically runs a [VS Code tunnel](https://code.visualstudio.com/docs/remote/tunnels) inside tmux on boot, with a watchdog that monitors tunnel health every 5 minutes and auto-recovers from failures.

This allows you to access any Linux machine remotely via VS Code without setting up SSH port forwarding or VPN — just install once and the tunnel stays alive across reboots.

## Features

- **Boot persistence** — Tunnel starts automatically on system boot via systemd user service + loginctl linger, no manual login needed
- **tmux integration** — Tunnel runs inside a named tmux session (`vscode-tunnel`) for easy attach/debug
- **6-layer health watchdog** — Checks every 5 minutes: auth token, auth prompt, tmux session, process alive, not zombie, network reachable, active TCP connections
- **Smart restart logic** — Skips restart when network is down (saves restart budget); restarts only when genuinely broken
- **Auth failure detection** — Detects when tunnel needs re-authentication and sends email notification with the auth URL and device code
- **Email notifications** — Configurable email alerts (Gmail SMTP) when manual intervention is needed
- **Self-healing** — If VS Code CLI binary goes missing, auto-downloads on next startup; stale lock files are cleaned automatically
- **Log management** — Triple logging: tmux (live), log file (rotated at 10MB x 3), journald (systemd). Logs persist across restarts.
- **Zero hardcoded paths** — All paths and usernames discovered at install time; portable across machines
- **One-command install/uninstall** — Clone, run `./install.sh`, done

## Architecture

```
Boot
  └─ systemd (PID 1)
       └─ User systemd instance (loginctl linger enabled)
            ├─ vscode-tunnel.service
            │    └─ start-tunnel.sh
            │         └─ tmux session "vscode-tunnel"
            │              └─ code tunnel --accept-server-license-terms --name $(hostname -s)
            │
            └─ vscode-tunnel-watchdog.timer (every 5 min)
                 └─ vscode-tunnel-watchdog.service
                      └─ watchdog-tunnel.sh (6-layer health check + email notification)
```

## Prerequisites

- Linux with systemd (tested on Ubuntu 24.04)
- tmux
- curl
- Python 3 (for email notifications via smtplib)
- `host` command (package: `dnsutils` on Debian/Ubuntu, `bind-utils` on RHEL/Fedora)
- `ss` command (package: `iproute2`, usually pre-installed)
- sudo access (one-time, to enable loginctl linger)

## Quick Start

```bash
git clone https://github.com/eeezio/vscode-tunnel-service.git
cd vscode-tunnel-service
./install.sh
```

The installer will:
1. Detect your CPU architecture (x86_64 / arm64) and download VS Code CLI
2. Copy scripts to `~/.vscode-tunnel/`
3. Generate a machine-specific `env.sh` with dynamically discovered PATH
4. Install systemd unit files
5. Enable and start the tunnel service and watchdog timer

If linger is not enabled, the installer will warn you. Run:

```bash
sudo loginctl enable-linger $(whoami)
```

### First-time authentication

VS Code tunnel requires a one-time GitHub or Microsoft account login. After `./install.sh` completes:

```bash
# Attach to the tunnel session
tmux attach -t vscode-tunnel

# You'll see a URL and device code — open the URL in a browser and enter the code
# Once authenticated, the tunnel will connect

# Detach from tmux (tunnel keeps running)
# Press: Ctrl+B, then D
```

After authentication, the tunnel will reconnect automatically on reboot — no further login needed.

### Configure email notifications (optional)

Add the following to `~/.vscode-tunnel/env.sh` to receive email alerts when the tunnel needs re-authentication:

```bash
export TUNNEL_NOTIFY_EMAIL="you@gmail.com"
export TUNNEL_SMTP_HOST="smtp.gmail.com"
export TUNNEL_SMTP_PORT="587"
export TUNNEL_SMTP_USER="you@gmail.com"
export TUNNEL_SMTP_PASS="xxxx xxxx xxxx xxxx"  # Gmail App Password
```

Generate a Gmail App Password at: https://myaccount.google.com/apppasswords

Then lock down the file:

```bash
chmod 600 ~/.vscode-tunnel/env.sh
```

When auth is needed, you'll receive an email with the auth URL, device code, and instructions.

> **On a shared/NFS home directory?** You almost certainly also need to set `TUNNEL_ALLOWED_HOST` — see the next section. Skipping it leads to duplicate emails from every cluster node.

## ⚠️ Important: Shared / NFS Home Directories (clusters)

On many HPC and cluster environments, your home directory is **NFS-mounted and shared across every login/compute node**. This breaks the default assumption that `~/.vscode-tunnel/` is local to one machine, and causes serious problems if you don't account for it:

- **`~/.vscode-tunnel/`** (scripts, lock file, logs, `env.sh`) is visible on *every* node
- **`~/.config/systemd/user/`** (the enable symlinks) is also shared — so `systemctl --user enable` done on one node makes the units "enabled" everywhere
- If the service starts on multiple nodes (via login sessions or per-node linger), **each node's watchdog fights over the same shared lock and log files, and they each send duplicate alert emails** — an email storm
- Each node's watchdog also sees the others' tunnel PIDs (which don't exist locally) and may trigger spurious restarts

### The fix: host guard

Set `TUNNEL_ALLOWED_HOST` in `env.sh` to the short hostname of the **one** machine that should run the tunnel:

```bash
echo 'export TUNNEL_ALLOWED_HOST="'"$(hostname -s)"'"' >> ~/.vscode-tunnel/env.sh
```

Both `start-tunnel.sh` and `watchdog-tunnel.sh` check this on every run. On any host whose short hostname doesn't match, they **exit immediately** — no tunnel, no restart, no email. Since the scripts are shared via NFS, this single setting makes all other nodes no-ops automatically.

If `TUNNEL_ALLOWED_HOST` is unset, the guard is disabled (the service runs on whatever host it's on — fine for truly local home directories).

### Cleaning up other nodes

If the tunnel already started on other nodes before you set the guard, those orphan tunnel processes keep running until that node reboots (or you get a session there to kill them). They're harmless once the guard is in place (their watchdog stops emailing), but to fully clean up, on each affected node run:

```bash
systemctl --user stop vscode-tunnel.service vscode-tunnel-watchdog.timer
systemctl --user disable vscode-tunnel.service vscode-tunnel-watchdog.timer
tmux kill-session -t vscode-tunnel 2>/dev/null
pkill -u "$USER" -f 'code tunnel'
```

Note: `~/.vscode/cli/token.json` (the auth token) is also shared, which is actually fine — all nodes use the same account. Only the *runtime/control* state causes conflicts, which the host guard resolves.

## Repo Structure

```
vscode-tunnel-service/
├── install.sh                          # One-command installer
├── uninstall.sh                        # Clean teardown
├── scripts/
│   ├── start-tunnel.sh                 # Startup: env check → auto-heal CLI → clean locks → wait network → tmux → tunnel
│   ├── stop-tunnel.sh                  # Graceful tmux session shutdown
│   └── watchdog-tunnel.sh              # 6-layer health monitoring + email notification
├── systemd/
│   ├── vscode-tunnel.service           # Main tunnel service (Type=forking)
│   ├── vscode-tunnel-watchdog.service  # Watchdog oneshot service
│   └── vscode-tunnel-watchdog.timer    # 5-minute repeating timer
└── README.md
```

### Runtime files (generated by install.sh, not in repo)

```
~/.vscode-tunnel/
├── env.sh                              # Machine-specific PATH + SMTP config (auto-generated, chmod 600)
├── bin/code                            # VS Code CLI binary
├── start-tunnel.sh                     # Copied from repo
├── stop-tunnel.sh                      # Copied from repo
├── watchdog-tunnel.sh                  # Copied from repo
└── logs/
    └── tunnel.log                      # Tunnel output (auto-rotated, 10MB x 3)
```

## How It Works

### Startup (`start-tunnel.sh`)

1. **Source `env.sh`** — Load dynamically generated PATH
2. **Verify tmux** — `command -v tmux`, fail fast if not found
3. **Auto-heal VS Code CLI** — If `~/.vscode-tunnel/bin/code` is missing or not executable, detect architecture and download the correct version automatically
4. **Clean stale tmux session and lock files** — Kill any leftover `vscode-tunnel` session and remove `~/.vscode/cli/tunnel-stable.lock` to prevent singleton lock deadlock
5. **Wait for network** — DNS-probe `tunnels.api.visualstudio.com` every 5s, up to 120s timeout. If timeout, start anyway and let watchdog retry later
6. **Log rotation** — If `tunnel.log` exceeds 10MB, rotate (keeps 3 historical copies, ~40MB max)
7. **Create tmux session** — With `remain-on-exit on` so crash output is preserved for debugging
8. **Launch tunnel** — `code tunnel` with `tmux pipe-pane` for logging (preserves terminal interactivity for auth prompts)

### Watchdog (`watchdog-tunnel.sh`)

Runs every 5 minutes via systemd timer. Performs checks in order:

| # | Check | On Failure |
|---|-------|------------|
| 0 | Auth token file exists (`~/.vscode/cli/token.json`) | Email notification (no restart) |
| 0.5 | Auth prompt visible in tmux (without tunnel success line) | Email notification (no restart) |
| 1 | tmux session `vscode-tunnel` exists | Restart service |
| 2 | `code tunnel` process is alive | Restart service |
| 3 | Process is not in zombie state | Restart service |
| 4 | Network is reachable (DNS lookup) | **Skip this round** (don't waste restart budget) |
| 5 | Process has ESTABLISHED TCP connections | Restart service (after 3 consecutive failures, send email) |

Key design decisions:
- **Check 0** catches deleted or missing auth token files
- **Check 0.5** detects active auth prompts by looking for auth keywords in the visible tmux pane, but only reports if no `Tunnel:` success line is present (prevents false positives from old auth prompts still visible on idle screens)
- **Check 4 skips** instead of restarting — when the network is down, restarting won't help and wastes systemd's restart budget (10 attempts per 10 minutes)
- **Check 5 fallback** — if the tunnel fails to connect 3 times in a row, sends email notification (catches auth issues that Check 0 and 0.5 missed)
- **Email deduplication** — notifications are sent only once per incident (uses a lock file `~/.vscode-tunnel/.auth-notified`), cleared automatically when the tunnel recovers
- All restarts go through `systemctl --user restart` for clean lifecycle management

### systemd Configuration

| Parameter | Value | Why |
|-----------|-------|-----|
| `Type=forking` | — | tmux daemonizes after `new-session -d` |
| `RemainAfterExit=yes` | — | Service stays "active" after start script exits |
| `Restart=on-failure` | — | Auto-restart on non-zero exit |
| `RestartSec=30` | 30 seconds | Avoid rapid restart loops |
| `StartLimitBurst=10` | 10 attempts | Max restarts per interval |
| `StartLimitIntervalSec=600` | 10 minutes | Reset restart counter after this window |
| `After=network-online.target` | — | Wait for network stack before starting |
| `OnBootSec=3min` | 3 minutes | First watchdog check after boot (give tunnel time to start) |
| `OnUnitActiveSec=5min` | 5 minutes | Watchdog interval |

## Useful Commands

```bash
# ---- Tunnel management ----

# Attach to tunnel session (see live output)
tmux attach -t vscode-tunnel
# Detach: Ctrl+B, then D

# Restart the tunnel
systemctl --user restart vscode-tunnel

# Stop the tunnel
systemctl --user stop vscode-tunnel

# ---- Monitoring ----

# Check service status
systemctl --user status vscode-tunnel

# Check watchdog timer
systemctl --user status vscode-tunnel-watchdog.timer
systemctl --user list-timers | grep watchdog

# Manually trigger watchdog
systemctl --user start vscode-tunnel-watchdog.service

# ---- Logs ----

# View tunnel process output
cat ~/.vscode-tunnel/logs/tunnel.log

# Tail tunnel log in real-time
tail -f ~/.vscode-tunnel/logs/tunnel.log

# View systemd service logs
journalctl --user -u vscode-tunnel

# View watchdog logs
journalctl --user -u vscode-tunnel-watchdog

# Follow logs in real-time
journalctl --user -u vscode-tunnel -f
```

## Logging

Three channels, each serving a different purpose:

| Channel | What it captures | How to view | Persists across restarts |
|---------|-----------------|-------------|------------------------|
| **tmux** | Live tunnel stdout/stderr | `tmux attach -t vscode-tunnel` | No (session recreated) |
| **Log file** | Tunnel output, persisted and rotated | `cat ~/.vscode-tunnel/logs/tunnel.log` | Yes (append mode) |
| **journald** | Script-level logs (startup, watchdog, errors) | `journalctl --user -u vscode-tunnel` | Yes (systemd managed) |

Log rotation: `tunnel.log` is rotated when it exceeds 10MB. Up to 3 historical files are kept (`tunnel.log.1`, `.2`, `.3`), so maximum disk usage is ~40MB. journald handles its own rotation automatically.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller will:
1. Stop and disable all services and timers
2. Remove systemd unit files
3. Reload systemd daemon
4. Ask whether to delete `~/.vscode-tunnel/` (prompts for confirmation to avoid losing logs)

Note: loginctl linger is NOT automatically disabled (it may be used by other services). To disable manually:

```bash
sudo loginctl disable-linger $(whoami)
```

## Deploying to a New Machine

```bash
# On the new machine
git clone https://github.com/eeezio/vscode-tunnel-service.git
cd vscode-tunnel-service
./install.sh
sudo loginctl enable-linger $(whoami)

# Authenticate (first time only)
tmux attach -t vscode-tunnel
# Follow the login prompts, then Ctrl+B, D to detach

# Optional: configure email notifications
cat >> ~/.vscode-tunnel/env.sh <<'EOF'

export TUNNEL_NOTIFY_EMAIL="you@gmail.com"
export TUNNEL_SMTP_HOST="smtp.gmail.com"
export TUNNEL_SMTP_PORT="587"
export TUNNEL_SMTP_USER="you@gmail.com"
export TUNNEL_SMTP_PASS="xxxx xxxx xxxx xxxx"
EOF
chmod 600 ~/.vscode-tunnel/env.sh
```

That's it. The tunnel will persist across reboots.

## Updating

To update scripts after pulling new changes:

```bash
cd ~/vscode-tunnel-service
git pull
./install.sh  # Re-copies scripts, re-generates env.sh, restarts services
```

The installer is idempotent — safe to run multiple times. It skips the VS Code CLI download if it's already installed.

Note: `install.sh` regenerates `env.sh`, which will overwrite SMTP settings. Re-add them after updating, or add them to a separate file and source it from `env.sh`.

## Troubleshooting

### Tunnel doesn't start on boot

```bash
# Check if linger is enabled
loginctl show-user $(whoami) | grep Linger
# Should show: Linger=yes

# If not:
sudo loginctl enable-linger $(whoami)
```

### Tunnel process exits immediately

```bash
# Attach to tmux to see error output (remain-on-exit preserves it)
tmux attach -t vscode-tunnel

# Check service logs
journalctl --user -u vscode-tunnel --no-pager -n 50
```

### Tunnel stuck on "error access singleton, retrying"

A stale lock file from a previous tunnel process. The startup script should clean this automatically, but if it persists:

```bash
rm -f ~/.vscode/cli/tunnel-stable.lock
systemctl --user restart vscode-tunnel
```

### Watchdog keeps restarting the tunnel

```bash
# Check watchdog logs for which check is failing
journalctl --user -u vscode-tunnel-watchdog --no-pager -n 20

# Common causes:
# - "no active TCP connections" → tunnel connected but idle; may be a false positive
# - "code tunnel process not found" → tunnel crashed, check tmux for error output
# - "network unreachable" → DNS issue, watchdog skips (no restart)
```

### Tunnel name rejected (label validation error)

VS Code tunnel names only allow `[\w-=]{1,50}`. The script uses `hostname -s` (short hostname, no domain suffix) to avoid this. If your short hostname still has invalid characters:

```bash
# Check what name would be used
hostname -s
```

### VS Code CLI is outdated

```bash
# Remove the old binary and restart — start-tunnel.sh will auto-download the latest
rm ~/.vscode-tunnel/bin/code
systemctl --user restart vscode-tunnel
```

### tmux session exists but tunnel isn't running

```bash
# The session may have remain-on-exit holding a dead pane
# Kill it and restart
tmux kill-session -t vscode-tunnel
systemctl --user restart vscode-tunnel
```

### journalctl shows "No journal files were opened due to insufficient permissions"

Your user needs to be in the `systemd-journal` group:

```bash
sudo usermod -aG systemd-journal $(whoami)
```

Then restart your user systemd instance to pick up the new group:

```bash
# This will briefly disconnect your tunnel (it auto-reconnects)
sudo systemctl restart user@$(id -u).service
```

### Receiving duplicate / repeated alert emails (every few minutes)

Almost always caused by a **shared/NFS home directory** with the service running on more than one node. See the "Shared / NFS Home Directories" section above. Fix:

```bash
# Set the owner host (run on the machine that should host the tunnel)
echo 'export TUNNEL_ALLOWED_HOST="'"$(hostname -s)"'"' >> ~/.vscode-tunnel/env.sh

# Clear any stale notification lock
rm -f ~/.vscode-tunnel/.auth-notified

# Confirm which hosts have written to the shared log
grep -aoE 'zhewan@[a-z0-9-]+' ~/.vscode-tunnel/logs/tunnel.log | sort -u
```

Then clean up the other nodes (stop/disable their service) as described in the shared-home section.

### Email notifications not working

```bash
# Verify SMTP settings in env.sh
cat ~/.vscode-tunnel/env.sh | grep SMTP

# Test email manually
source ~/.vscode-tunnel/env.sh
python3 -c "
import smtplib, os
from email.mime.text import MIMEText
msg = MIMEText('Test from vscode-tunnel-service')
msg['Subject'] = '[TUNNEL TEST] email test'
msg['From'] = os.environ['TUNNEL_SMTP_USER']
msg['To'] = os.environ['TUNNEL_NOTIFY_EMAIL']
s = smtplib.SMTP(os.environ['TUNNEL_SMTP_HOST'], int(os.environ['TUNNEL_SMTP_PORT']), timeout=15)
s.starttls()
s.login(os.environ['TUNNEL_SMTP_USER'], os.environ['TUNNEL_SMTP_PASS'])
s.sendmail(msg['From'], [msg['To']], msg.as_string())
s.quit()
print('OK')
"

# Force re-send notification (clear the dedup lock)
rm -f ~/.vscode-tunnel/.auth-notified
```

### Reinstall from scratch

```bash
./uninstall.sh          # Remove everything (say 'y' to delete ~/.vscode-tunnel/)
./install.sh            # Fresh install
```

## Supported Platforms

| Architecture | OS | Status |
|-------------|-----|--------|
| x86_64 | Ubuntu 24.04 | Tested |
| x86_64 | Other systemd-based Linux | Should work |
| aarch64 (ARM64) | systemd-based Linux | Supported (auto-detected) |

## License

MIT
