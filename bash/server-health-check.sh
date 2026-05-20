#!/usr/bin/env bash
# ==============================================================================
# server-health-check.sh
# ------------------------------------------------------------------------------
# Description : Checks core server health metrics and outputs a colour-coded
#               report. Optionally sends an alert to a Slack webhook when any
#               threshold is breached.
#
# Usage       : ./server-health-check.sh [OPTIONS]
#   -s  SLACK_WEBHOOK_URL   Slack incoming webhook URL for alerts
#   -c  CPU_THRESHOLD       CPU usage alert threshold in % (default: 85)
#   -m  MEM_THRESHOLD       Memory usage alert threshold in % (default: 90)
#   -d  DISK_THRESHOLD      Disk usage alert threshold in % (default: 80)
#   -p  PORTS               Comma-separated list of TCP ports to check
#                           (default: 22,80,443)
#   -h                      Show this help message
#
# Examples    :
#   ./server-health-check.sh
#   ./server-health-check.sh -c 80 -m 85 -d 75
#   ./server-health-check.sh -s https://hooks.slack.com/services/XXX -p 22,80,443,3000
#
# Dependencies: bash >= 4, coreutils, procps (ps/free), nc (netcat)
#
# Exit codes  :
#   0  All checks passed
#   1  One or more checks breached a threshold
#   2  Script usage error
# ==============================================================================

set -euo pipefail

# ── Colour codes ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Defaults ──────────────────────────────────────────────────────────────────
CPU_THRESHOLD=85
MEM_THRESHOLD=90
DISK_THRESHOLD=80
PORTS="22,80,443"
SLACK_WEBHOOK=""
ALERT_TRIGGERED=0
HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')

# ── Helper functions ──────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -E '(Usage|Options|-[a-z])' | sed 's/^# //'
  exit 2
}

print_header() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║        SERVER HEALTH CHECK REPORT                   ║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
  echo -e "${DIM}  Host : ${HOSTNAME_VAL}${RESET}"
  echo -e "${DIM}  Time : ${TIMESTAMP}${RESET}"
  echo ""
}

print_section() {
  echo -e "${BOLD}  ▸ $1${RESET}"
}

status_ok()   { echo -e "    ${GREEN}✔${RESET}  $1"; }
status_warn() { echo -e "    ${YELLOW}⚠${RESET}  $1"; ALERT_TRIGGERED=1; }
status_fail() { echo -e "    ${RED}✖${RESET}  $1"; ALERT_TRIGGERED=1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while getopts ":s:c:m:d:p:h" opt; do
  case $opt in
    s) SLACK_WEBHOOK="$OPTARG" ;;
    c) CPU_THRESHOLD="$OPTARG" ;;
    m) MEM_THRESHOLD="$OPTARG" ;;
    d) DISK_THRESHOLD="$OPTARG" ;;
    p) PORTS="$OPTARG" ;;
    h) usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; exit 2 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

# ── Check: CPU Usage ──────────────────────────────────────────────────────────
check_cpu() {
  print_section "CPU Usage"

  # Average CPU idle over 1 second; works on Linux with /proc/stat
  if [[ -f /proc/stat ]]; then
    read -r cpu user nice system idle iowait irq softirq steal _ < <(grep '^cpu ' /proc/stat)
    sleep 1
    read -r cpu2 user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ < <(grep '^cpu ' /proc/stat)

    total1=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
    total2=$(( user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2 ))
    idle_delta=$(( idle2 - idle ))
    total_delta=$(( total2 - total1 ))

    if (( total_delta > 0 )); then
      CPU_USAGE=$(( 100 * (total_delta - idle_delta) / total_delta ))
    else
      CPU_USAGE=0
    fi
  else
    # macOS fallback
    CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print int($2)}' || echo 0)
  fi

  LOAD_AVG=$(uptime | awk -F'load average:' '{print $2}' | xargs)
  CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)

  if (( CPU_USAGE >= CPU_THRESHOLD )); then
    status_fail "CPU usage: ${CPU_USAGE}% (threshold: ${CPU_THRESHOLD}%)"
  elif (( CPU_USAGE >= CPU_THRESHOLD * 80 / 100 )); then
    status_warn "CPU usage: ${CPU_USAGE}% (approaching threshold: ${CPU_THRESHOLD}%)"
  else
    status_ok  "CPU usage: ${CPU_USAGE}% (threshold: ${CPU_THRESHOLD}%)"
  fi
  echo -e "    ${DIM}Load avg: ${LOAD_AVG} | Cores: ${CPU_CORES}${RESET}"
}

# ── Check: Memory Usage ───────────────────────────────────────────────────────
check_memory() {
  print_section "Memory Usage"

  if command -v free &>/dev/null; then
    read -r _ total used free shared buff_cache available < <(free -m | grep '^Mem:')
    MEM_USAGE=$(( 100 * used / total ))
    MEM_USED_MB=$used
    MEM_TOTAL_MB=$total
    MEM_AVAIL_MB=$available
  else
    # macOS
    total_pages=$(sysctl -n hw.memsize)
    MEM_TOTAL_MB=$(( total_pages / 1024 / 1024 ))
    page_size=$(sysctl -n hw.pagesize)
    free_pages=$(vm_stat | grep 'Pages free' | awk '{print $3}' | tr -d '.')
    MEM_AVAIL_MB=$(( free_pages * page_size / 1024 / 1024 ))
    MEM_USED_MB=$(( MEM_TOTAL_MB - MEM_AVAIL_MB ))
    MEM_USAGE=$(( 100 * MEM_USED_MB / MEM_TOTAL_MB ))
  fi

  if (( MEM_USAGE >= MEM_THRESHOLD )); then
    status_fail "Memory: ${MEM_USAGE}% used — ${MEM_USED_MB}MB / ${MEM_TOTAL_MB}MB (threshold: ${MEM_THRESHOLD}%)"
  elif (( MEM_USAGE >= MEM_THRESHOLD * 80 / 100 )); then
    status_warn "Memory: ${MEM_USAGE}% used — ${MEM_USED_MB}MB / ${MEM_TOTAL_MB}MB (approaching threshold: ${MEM_THRESHOLD}%)"
  else
    status_ok  "Memory: ${MEM_USAGE}% used — ${MEM_USED_MB}MB / ${MEM_TOTAL_MB}MB (threshold: ${MEM_THRESHOLD}%)"
  fi
  echo -e "    ${DIM}Available: ${MEM_AVAIL_MB}MB${RESET}"
}

# ── Check: Disk Usage ─────────────────────────────────────────────────────────
check_disk() {
  print_section "Disk Usage"

  while IFS= read -r line; do
    usage_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
    mount_point=$(echo "$line" | awk '{print $6}')
    used=$(echo "$line" | awk '{print $3}')
    size=$(echo "$line" | awk '{print $2}')

    label="Disk ${mount_point}: ${usage_pct}% used (${used} / ${size})"

    if (( usage_pct >= DISK_THRESHOLD )); then
      status_fail "$label (threshold: ${DISK_THRESHOLD}%)"
    elif (( usage_pct >= DISK_THRESHOLD * 85 / 100 )); then
      status_warn "$label (approaching threshold: ${DISK_THRESHOLD}%)"
    else
      status_ok  "$label"
    fi
  done < <(df -h --output=source,size,used,avail,pcent,target 2>/dev/null | \
            grep -E '^/dev/' | \
            grep -v 'tmpfs\|loop\|udev' || \
            df -h | grep -E '^/dev/' | grep -v 'tmpfs')
}

# ── Check: Port Availability ──────────────────────────────────────────────────
check_ports() {
  print_section "Port Availability"

  if ! command -v nc &>/dev/null; then
    echo -e "    ${DIM}Skipping port checks — netcat (nc) not found${RESET}"
    return
  fi

  IFS=',' read -ra PORT_LIST <<< "$PORTS"
  for port in "${PORT_LIST[@]}"; do
    port=$(echo "$port" | xargs)   # trim whitespace
    if nc -z -w2 127.0.0.1 "$port" 2>/dev/null; then
      status_ok "Port ${port} is open"
    else
      status_fail "Port ${port} is not reachable"
    fi
  done
}

# ── Check: System Services ────────────────────────────────────────────────────
check_services() {
  print_section "Critical Services"

  if ! command -v systemctl &>/dev/null; then
    echo -e "    ${DIM}Skipping service checks — systemd not available${RESET}"
    return
  fi

  local services=("ssh" "sshd" "cron" "crond")
  local found=0

  for svc in "${services[@]}"; do
    if systemctl list-units --type=service --all 2>/dev/null | grep -q "${svc}.service"; then
      found=1
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        status_ok "Service '${svc}' is active"
      else
        status_fail "Service '${svc}' is NOT running"
      fi
    fi
  done

  (( found == 0 )) && echo -e "    ${DIM}No monitored services found${RESET}"
}

# ── Check: Recent Failed Logins ───────────────────────────────────────────────
check_security() {
  print_section "Security Snapshot"

  # Failed SSH logins in the last 24 hours
  if [[ -f /var/log/auth.log ]]; then
    FAIL_COUNT=$(grep -c 'Failed password' /var/log/auth.log 2>/dev/null || echo 0)
  elif [[ -f /var/log/secure ]]; then
    FAIL_COUNT=$(grep -c 'Failed password' /var/log/secure 2>/dev/null || echo 0)
  else
    FAIL_COUNT="N/A"
  fi

  if [[ "$FAIL_COUNT" == "N/A" ]]; then
    echo -e "    ${DIM}Auth log not accessible — skipping SSH failure count${RESET}"
  elif (( FAIL_COUNT > 100 )); then
    status_warn "Failed SSH login attempts (all-time in log): ${FAIL_COUNT} — consider fail2ban"
  else
    status_ok "Failed SSH attempts in auth log: ${FAIL_COUNT}"
  fi

  # Uptime
  UPTIME_STR=$(uptime -p 2>/dev/null || uptime | awk -F'( up |,  [0-9]+ user)' '{print $2}')
  echo -e "    ${DIM}System uptime: ${UPTIME_STR}${RESET}"

  # Logged-in users
  USER_COUNT=$(who | wc -l | xargs)
  echo -e "    ${DIM}Active sessions: ${USER_COUNT}${RESET}"
}

# ── Print Summary ─────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}${CYAN}  ──────────────────────────────────────────────────────${RESET}"
  if (( ALERT_TRIGGERED == 0 )); then
    echo -e "${BOLD}${GREEN}  ✔  All checks passed — server is healthy${RESET}"
  else
    echo -e "${BOLD}${RED}  ✖  One or more checks require attention${RESET}"
  fi
  echo -e "${BOLD}${CYAN}  ──────────────────────────────────────────────────────${RESET}"
  echo ""
}

# ── Slack Alert ───────────────────────────────────────────────────────────────
send_slack_alert() {
  [[ -z "$SLACK_WEBHOOK" ]] && return
  (( ALERT_TRIGGERED == 0 )) && return

  local emoji=":rotating_light:"
  local color="#E53935"
  local message="*Server health alert on \`${HOSTNAME_VAL}\`*\nOne or more thresholds were breached at ${TIMESTAMP}.\n\nThresholds: CPU ${CPU_THRESHOLD}% | Memory ${MEM_THRESHOLD}% | Disk ${DISK_THRESHOLD}%"

  local payload
  payload=$(printf '{"attachments":[{"color":"%s","text":"%s %s"}]}' \
    "$color" "$emoji" "$message")

  if curl -sf -X POST -H 'Content-type: application/json' \
       --data "$payload" "$SLACK_WEBHOOK" &>/dev/null; then
    echo -e "${DIM}  Slack alert sent.${RESET}"
  else
    echo -e "${YELLOW}  Warning: failed to send Slack alert.${RESET}"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  print_header
  check_cpu
  echo ""
  check_memory
  echo ""
  check_disk
  echo ""
  check_ports
  echo ""
  check_services
  echo ""
  check_security
  print_summary
  send_slack_alert
  exit "$ALERT_TRIGGERED"
}

main "$@"
