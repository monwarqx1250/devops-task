#!/usr/bin/env bash
#
# system_health.sh - collect basic host health metrics, log them, and return a
# monitoring-friendly exit code.
#
#   Exit codes: 0 = healthy, 1 = warning, 2 = critical, 3 = usage/runtime error
#
# Requires a Linux host with /proc, GNU coreutils (df) and procps (ps).
# Run `system_health.sh --help` for options.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

readonly EXIT_OK=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2
readonly EXIT_ERROR=3

# ---- defaults (overridable by flags or environment) -------------------------
CPU_WARN="${HEALTH_CPU_WARN:-90}"
CPU_CRIT="${HEALTH_CPU_CRIT:-95}"
MEM_WARN="${HEALTH_MEM_WARN:-85}"
MEM_CRIT="${HEALTH_MEM_CRIT:-95}"
DISK_WARN="${HEALTH_DISK_WARN:-80}"
DISK_CRIT="${HEALTH_DISK_CRIT:-90}"
LOG_FILE="${HEALTH_LOG_FILE:-health_log.txt}"
MAX_LOG_BYTES="${HEALTH_MAX_LOG_BYTES:-1048576}" # rotate at 1 MiB
LOG_KEEP="${HEALTH_LOG_KEEP:-5}"                 # keep 5 rotated files
CPU_SAMPLE_SECONDS="${HEALTH_CPU_SAMPLE_SECONDS:-1}"
WEBHOOK_URL="${HEALTH_WEBHOOK_URL:-}"            # optional Slack/Discord webhook
OUTPUT_JSON=false
QUIET=false

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Collect CPU, memory, disk (all mounted filesystems), load average and the top 5
processes by memory. Append a timestamped entry to the log file and print
[WARNING]/[CRITICAL] messages when a threshold is exceeded.

Options:
  --cpu N          CPU usage warning threshold in %        (default: $CPU_WARN)
  --cpu-crit N     CPU usage critical threshold in %       (default: $CPU_CRIT)
  --mem N          Memory usage warning threshold in %     (default: $MEM_WARN)
  --mem-crit N     Memory usage critical threshold in %    (default: $MEM_CRIT)
  --disk N         Disk usage warning threshold in %       (default: $DISK_WARN)
  --disk-crit N    Disk usage critical threshold in %      (default: $DISK_CRIT)
  --json           Print the report as JSON and log it as one JSON line
  --log-file PATH  Log file to append to                   (default: $LOG_FILE)
  --max-size BYTES Rotate the log file when it exceeds BYTES (default: $MAX_LOG_BYTES)
  --keep N         Number of rotated log files to keep     (default: $LOG_KEEP)
  -q, --quiet      Do not print the report, only warnings
  -h, --help       Show this help and exit
  -V, --version    Show the version and exit

Environment:
  HEALTH_WEBHOOK_URL  If set, POST a message to this Slack/Discord-compatible
                      webhook when the status is warning or critical.
  HEALTH_*            Every option above also has an environment default, e.g.
                      HEALTH_DISK_WARN=75 or HEALTH_LOG_FILE=/var/log/health.log

Exit codes:
  0 healthy, 1 warning, 2 critical, 3 usage or runtime error

Examples:
  $SCRIPT_NAME --disk 80 --cpu 90 --mem 85
  $SCRIPT_NAME --json --log-file /var/log/system_health/health_log.txt
EOF
}

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit "$EXIT_ERROR"
}

is_percent() {
  [[ "$1" =~ ^[0-9]+$ ]] && (("$1" >= 0 && "$1" <= 100))
}

need_value() {
  # $1 = flag, $2 = number of remaining args (including the flag)
  (("$2" >= 2)) || die "option $1 requires a value (see --help)"
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --cpu) need_value "$1" "$#"; CPU_WARN="$2"; shift 2 ;;
      --cpu-crit) need_value "$1" "$#"; CPU_CRIT="$2"; shift 2 ;;
      --mem) need_value "$1" "$#"; MEM_WARN="$2"; shift 2 ;;
      --mem-crit) need_value "$1" "$#"; MEM_CRIT="$2"; shift 2 ;;
      --disk) need_value "$1" "$#"; DISK_WARN="$2"; shift 2 ;;
      --disk-crit) need_value "$1" "$#"; DISK_CRIT="$2"; shift 2 ;;
      --log-file) need_value "$1" "$#"; LOG_FILE="$2"; shift 2 ;;
      --max-size) need_value "$1" "$#"; MAX_LOG_BYTES="$2"; shift 2 ;;
      --keep) need_value "$1" "$#"; LOG_KEEP="$2"; shift 2 ;;
      --json) OUTPUT_JSON=true; shift ;;
      -q | --quiet) QUIET=true; shift ;;
      -h | --help) usage; exit "$EXIT_OK" ;;
      -V | --version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit "$EXIT_OK" ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done

  local name value
  for name in CPU_WARN CPU_CRIT MEM_WARN MEM_CRIT DISK_WARN DISK_CRIT; do
    value="${!name}"
    is_percent "$value" || die "$name must be an integer between 0 and 100, got '$value'"
  done
  ((CPU_WARN <= CPU_CRIT)) || die "--cpu ($CPU_WARN) must not exceed --cpu-crit ($CPU_CRIT)"
  ((MEM_WARN <= MEM_CRIT)) || die "--mem ($MEM_WARN) must not exceed --mem-crit ($MEM_CRIT)"
  ((DISK_WARN <= DISK_CRIT)) || die "--disk ($DISK_WARN) must not exceed --disk-crit ($DISK_CRIT)"
  [[ "$MAX_LOG_BYTES" =~ ^[0-9]+$ ]] || die "--max-size must be a number of bytes"
  if ! [[ "$LOG_KEEP" =~ ^[0-9]+$ ]] || ((LOG_KEEP < 1)); then
    die "--keep must be a positive integer"
  fi
}

check_dependencies() {
  [[ -r /proc/stat && -r /proc/meminfo && -r /proc/loadavg ]] \
    || die "this script needs a Linux /proc filesystem"
  local cmd
  for cmd in awk df ps date; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

# ---- metric collection --------------------------------------------------------

# CPU usage over a short sample: 100 * (1 - idle_delta / total_delta).
cpu_usage() {
  local user nice system idle iowait irq softirq steal
  local idle1 total1 idle2 total2
  read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
  idle1=$((idle + iowait))
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  sleep "$CPU_SAMPLE_SECONDS"
  read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
  idle2=$((idle + iowait))
  total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  awk -v di="$((idle2 - idle1))" -v dt="$((total2 - total1))" \
    'BEGIN { if (dt <= 0) { print "0.0" } else { printf "%.1f", 100 * (1 - di / dt) } }'
}

# Prints: "<used_percent> <used_mib> <total_mib>" based on MemAvailable.
memory_usage() {
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      if (total == 0) { print "0.0 0 0"; exit }
      used = total - avail
      printf "%.1f %d %d\n", 100 * used / total, used / 1024, total / 1024
    }' /proc/meminfo
}

# Prints one line per real filesystem: "<use%> <mountpoint> <fstype> <size_mib> <used_mib>".
# Pseudo/virtual filesystems are skipped so they cannot trigger disk alerts.
disk_usage() {
  df -P -T -m 2>/dev/null | awk '
    NR == 1 { next }
    $2 ~ /^(tmpfs|devtmpfs|squashfs|overlay|proc|sysfs|cgroup2?|nsfs|ramfs|autofs|efivarfs|fuse\..*|virtiofs)$/ { next }
    {
      pct = $6; sub(/%/, "", pct)
      mount = $7
      for (i = 8; i <= NF; i++) mount = mount " " $i   # mount points with spaces
      printf "%s %s %s %s %s\n", pct, mount, $2, $3, $4
    }'
}

load_average() {
  awk '{ print $1, $2, $3 }' /proc/loadavg
}

# Prints the top 5 processes by memory: "<pid> <mem%> <rss_mib> <command>".
top_processes() {
  ps -eo pid=,pmem=,rss=,comm= --sort=-pmem 2>/dev/null | head -n 5 \
    | awk '{ cmd = $4; for (i = 5; i <= NF; i++) cmd = cmd " " $i; printf "%s %s %d %s\n", $1, $2, $3 / 1024, cmd }'
}

# ---- helpers ---------------------------------------------------------------------

# Compare a decimal value against an integer threshold: returns 0 if value >= threshold.
exceeds() {
  awk -v v="$1" -v t="$2" 'BEGIN { exit !(v >= t) }'
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size
  size=$(wc -c <"$LOG_FILE")
  ((size >= MAX_LOG_BYTES)) || return 0
  local i
  rm -f -- "$LOG_FILE.$LOG_KEEP"
  for ((i = LOG_KEEP - 1; i >= 1; i--)); do
    [[ -f "$LOG_FILE.$i" ]] && mv -f -- "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))"
  done
  mv -f -- "$LOG_FILE" "$LOG_FILE.1"
}

send_webhook() {
  [[ -n "$WEBHOOK_URL" ]] || return 0
  command -v curl >/dev/null 2>&1 || { printf '%s: curl not found, skipping webhook\n' "$SCRIPT_NAME" >&2; return 0; }
  local text payload
  text="$(json_escape "$1")"
  # "text" is read by Slack, "content" by Discord.
  payload=$(printf '{"text":"%s","content":"%s"}' "$text" "$text")
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "$payload" "$WEBHOOK_URL" >/dev/null \
    || printf '%s: webhook delivery failed\n' "$SCRIPT_NAME" >&2
}

# ---- main --------------------------------------------------------------------------

main() {
  parse_args "$@"
  check_dependencies

  local timestamp host
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  host="$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname)"

  local cpu mem_pct mem_used mem_total load1 load5 load15
  cpu="$(cpu_usage)"
  read -r mem_pct mem_used mem_total < <(memory_usage)
  read -r load1 load5 load15 < <(load_average)

  local -a disks procs messages=()
  mapfile -t disks < <(disk_usage)
  mapfile -t procs < <(top_processes)

  local status=$EXIT_OK

  raise() { # $1 = level (1 warning, 2 critical), $2 = message
    messages+=("$([[ $1 -eq $EXIT_CRITICAL ]] && echo '[CRITICAL]' || echo '[WARNING]') $2")
    (($1 > status)) && status=$1
    return 0
  }

  if exceeds "$cpu" "$CPU_CRIT"; then
    raise "$EXIT_CRITICAL" "CPU usage ${cpu}% >= ${CPU_CRIT}%"
  elif exceeds "$cpu" "$CPU_WARN"; then
    raise "$EXIT_WARNING" "CPU usage ${cpu}% >= ${CPU_WARN}%"
  fi

  if exceeds "$mem_pct" "$MEM_CRIT"; then
    raise "$EXIT_CRITICAL" "Memory usage ${mem_pct}% >= ${MEM_CRIT}%"
  elif exceeds "$mem_pct" "$MEM_WARN"; then
    raise "$EXIT_WARNING" "Memory usage ${mem_pct}% >= ${MEM_WARN}%"
  fi

  local line pct mount fstype size used
  for line in "${disks[@]}"; do
    read -r pct mount fstype size used <<<"$line"
    if exceeds "$pct" "$DISK_CRIT"; then
      raise "$EXIT_CRITICAL" "Disk usage on ${mount} ${pct}% >= ${DISK_CRIT}%"
    elif exceeds "$pct" "$DISK_WARN"; then
      raise "$EXIT_WARNING" "Disk usage on ${mount} ${pct}% >= ${DISK_WARN}%"
    fi
  done

  local status_text
  case "$status" in
    "$EXIT_OK") status_text="healthy" ;;
    "$EXIT_WARNING") status_text="warning" ;;
    *) status_text="critical" ;;
  esac

  # ---- render -------------------------------------------------------------------
  local report
  if [[ "$OUTPUT_JSON" == true ]]; then
    local disks_json="" procs_json="" msgs_json="" sep="" pid pmem rss cmd m
    for line in "${disks[@]}"; do
      read -r pct mount fstype size used <<<"$line"
      disks_json+="${sep}{\"mount\":\"$(json_escape "$mount")\",\"fstype\":\"$fstype\",\"used_percent\":$pct,\"size_mib\":$size,\"used_mib\":$used}"
      sep=","
    done
    sep=""
    for line in "${procs[@]}"; do
      read -r pid pmem rss cmd <<<"$line"
      procs_json+="${sep}{\"pid\":$pid,\"mem_percent\":$pmem,\"rss_mib\":$rss,\"command\":\"$(json_escape "$cmd")\"}"
      sep=","
    done
    sep=""
    for m in "${messages[@]}"; do
      msgs_json+="${sep}\"$(json_escape "$m")\""
      sep=","
    done
    report=$(printf '{"timestamp":"%s","host":"%s","status":"%s","exit_code":%d,"cpu":{"used_percent":%s,"warn":%d,"crit":%d},"memory":{"used_percent":%s,"used_mib":%d,"total_mib":%d,"warn":%d,"crit":%d},"load_average":{"1m":%s,"5m":%s,"15m":%s},"disks":[%s],"disk_thresholds":{"warn":%d,"crit":%d},"top_processes":[%s],"messages":[%s]}' \
      "$timestamp" "$(json_escape "$host")" "$status_text" "$status" \
      "$cpu" "$CPU_WARN" "$CPU_CRIT" \
      "$mem_pct" "$mem_used" "$mem_total" "$MEM_WARN" "$MEM_CRIT" \
      "$load1" "$load5" "$load15" \
      "$disks_json" "$DISK_WARN" "$DISK_CRIT" "$procs_json" "$msgs_json")
  else
    report="===== ${timestamp} ${host} status=${status_text} =====
CPU usage:    ${cpu}% (warn ${CPU_WARN}%, crit ${CPU_CRIT}%)
Memory usage: ${mem_pct}% (${mem_used}/${mem_total} MiB, warn ${MEM_WARN}%, crit ${MEM_CRIT}%)
Load average: ${load1} ${load5} ${load15}
Disk usage (warn ${DISK_WARN}%, crit ${DISK_CRIT}%):"
    for line in "${disks[@]}"; do
      read -r pct mount fstype size used <<<"$line"
      report+=$'\n'"$(printf '  %5s%%  %-25s %-8s %8s MiB used of %s MiB' "$pct" "$mount" "$fstype" "$used" "$size")"
    done
    report+=$'\n'"Top 5 processes by memory:"
    report+=$'\n'"$(printf '  %7s %6s %9s  %s' PID MEM% RSS_MiB COMMAND)"
    local pid pmem rss cmd
    for line in "${procs[@]}"; do
      read -r pid pmem rss cmd <<<"$line"
      report+=$'\n'"$(printf '  %7s %6s %9s  %s' "$pid" "$pmem" "$rss" "$cmd")"
    done
    local m
    for m in "${messages[@]}"; do
      report+=$'\n'"$m"
    done
  fi

  # ---- log (rotate first so one run never splits across files) ------------------
  local log_dir
  log_dir="$(dirname -- "$LOG_FILE")"
  [[ -d "$log_dir" ]] || mkdir -p -- "$log_dir" || die "cannot create log directory $log_dir"
  rotate_log
  printf '%s\n' "$report" >>"$LOG_FILE" || die "cannot write to $LOG_FILE"

  # ---- output ----------------------------------------------------------------------
  if [[ "$QUIET" == true ]]; then
    for m in "${messages[@]}"; do printf '%s\n' "$m" >&2; done
  else
    printf '%s\n' "$report"
  fi

  if ((status != EXIT_OK)); then
    send_webhook "system_health ${status_text} on ${host}: $(printf '%s; ' "${messages[@]}")"
  fi

  return "$status"
}

main "$@"
