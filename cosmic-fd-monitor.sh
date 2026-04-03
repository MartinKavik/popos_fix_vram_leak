#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  cosmic-fd-monitor.sh once
  cosmic-fd-monitor.sh watch

Environment variables:
  INTERVAL   Sample interval in seconds for watch mode
             default: 30
  OUTPUT     Log file path
             default: ./fd-logs/cosmic-fd-monitor.log
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERVAL="${INTERVAL:-30}"
OUTPUT="${OUTPUT:-$SCRIPT_DIR/fd-logs/cosmic-fd-monitor.log}"

ensure_output_dir() {
  mkdir -p "$(dirname "$OUTPUT")"
}

append_header() {
  if [[ ! -s "$OUTPUT" ]]; then
    cat >>"$OUTPUT" <<'EOF'
# timestamp kind pid comm fd_count soft_limit hard_limit sockets pipes memfd pidfd anon_inode_other other note
EOF
  fi
}

fd_type_counts() {
  local pid="$1"
  local sockets=0
  local pipes=0
  local memfd=0
  local pidfd=0
  local anon_inode_other=0
  local other=0
  local fd target

  for fd in /proc/"$pid"/fd/*; do
    [[ -e "$fd" ]] || continue
    target="$(readlink "$fd" 2>/dev/null || true)"
    case "$target" in
      socket:*)
        sockets=$((sockets + 1))
        ;;
      pipe:*)
        pipes=$((pipes + 1))
        ;;
      /memfd:*)
        memfd=$((memfd + 1))
        ;;
      anon_inode:\[pidfd\])
        pidfd=$((pidfd + 1))
        ;;
      anon_inode:*)
        anon_inode_other=$((anon_inode_other + 1))
        ;;
      *)
        other=$((other + 1))
        ;;
    esac
  done

  printf '%s %s %s %s %s %s' \
    "$sockets" "$pipes" "$memfd" "$pidfd" "$anon_inode_other" "$other"
}

log_proc() {
  local ts="$1"
  local kind="$2"
  local pid="$3"
  local note="$4"
  local fd_count soft_limit hard_limit comm counts fd

  [[ -d "/proc/$pid" ]] || return 0

  comm="$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null | awk '{print $1}')"
  if [[ -z "$comm" ]]; then
    comm="$(cat /proc/"$pid"/comm 2>/dev/null || echo unknown)"
  fi

  fd_count=0
  for fd in /proc/"$pid"/fd/*; do
    [[ -e "$fd" ]] || continue
    fd_count=$((fd_count + 1))
  done

  read -r soft_limit hard_limit _ < <(
    awk '/Max open files/ {print $4, $5, $6}' /proc/"$pid"/limits 2>/dev/null || true
  )
  counts="$(fd_type_counts "$pid")"

  printf '%s %s %s %s %s %s %s %s %s %s %s %s %s %s\n' \
    "$ts" "$kind" "$pid" "$comm" "$fd_count" "${soft_limit:-na}" "${hard_limit:-na}" \
    $counts "$note" >>"$OUTPUT"
}

sample_once() {
  local ts session_pid panel_pid comp_pid notif_pid
  ts="$(date --iso-8601=seconds)"

  {
    printf '%s event - - - - - - - - - - - - sample_start\n' "$ts"
  } >>"$OUTPUT"

  session_pid="$(pgrep -xo cosmic-session || true)"
  panel_pid="$(pgrep -xo cosmic-panel || true)"
  comp_pid="$(pgrep -xo cosmic-comp || true)"
  notif_pid="$(pgrep -xo -f '(^|/)cosmic-notifications( |$)' || true)"

  [[ -n "$session_pid" ]] && log_proc "$ts" core "$session_pid" "-"
  [[ -n "$panel_pid" ]] && log_proc "$ts" core "$panel_pid" "-"
  [[ -n "$comp_pid" ]] && log_proc "$ts" core "$comp_pid" "-"
  [[ -n "$notif_pid" ]] && log_proc "$ts" core "$notif_pid" "-"

  if [[ -n "$panel_pid" ]]; then
    while read -r child_pid child_comm; do
      [[ -n "$child_pid" ]] || continue
      log_proc "$ts" child "$child_pid" "$child_comm"
    done < <(
      ps --ppid "$panel_pid" -o pid=,comm= 2>/dev/null | sed 's/^ *//'
    )
  fi
}

watch_loop() {
  while true; do
    sample_once
    sleep "$INTERVAL"
  done
}

main() {
  ensure_output_dir
  append_header

  case "${1:-}" in
    once)
      sample_once
      ;;
    watch)
      watch_loop
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "${1:-}"
