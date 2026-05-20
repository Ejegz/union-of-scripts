# /bash — Bash Scripts

Production-ready Bash scripts for server operations, monitoring, and maintenance.

---

## server-health-check.sh

Performs a comprehensive health check on a Linux server and outputs a colour-coded terminal report. Optionally fires a Slack alert when any threshold is breached.

### What it checks

| Check | Details |
|---|---|
| **CPU usage** | Live 1-second sample from `/proc/stat` |
| **Memory usage** | Used vs available via `free` |
| **Disk usage** | All `/dev/*` mount points via `df` |
| **Port availability** | TCP connect test via `nc` |
| **System services** | `ssh` / `cron` via `systemctl` |
| **Security snapshot** | Failed SSH attempts, uptime, active sessions |

### Usage

```bash
# Basic run — uses default thresholds
./server-health-check.sh

# Custom thresholds
./server-health-check.sh -c 80 -m 85 -d 75

# Check specific ports
./server-health-check.sh -p 22,80,443,3000,8080

# With Slack alerting
./server-health-check.sh \
  -s https://hooks.slack.com/services/YOUR/WEBHOOK/URL \
  -c 80 -m 85 -d 75 -p 22,80,443
```

### Options

| Flag | Default | Description |
|---|---|---|
| `-c` | `85` | CPU usage alert threshold (%) |
| `-m` | `90` | Memory usage alert threshold (%) |
| `-d` | `80` | Disk usage alert threshold (%) |
| `-p` | `22,80,443` | Comma-separated ports to check |
| `-s` | _(none)_ | Slack incoming webhook URL |
| `-h` | — | Show usage help |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed |
| `1` | One or more thresholds breached |
| `2` | Script usage error |

### Run as a cron job

```cron
# Run every 15 minutes, log output
*/15 * * * * /opt/scripts/server-health-check.sh -s "$SLACK_WEBHOOK" >> /var/log/health-check.log 2>&1
```

### Dependencies

- `bash >= 4`
- `coreutils` (`df`, `uptime`)
- `procps` (`free`, `ps`)
- `netcat` (`nc`) — for port checks
- `curl` — for Slack alerts
- `systemd` — for service checks (optional)

All standard on Ubuntu 20.04+, Debian 11+, Amazon Linux 2, RHEL/CentOS 7+.
