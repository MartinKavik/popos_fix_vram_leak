#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  cosmic-kms-debug.sh start   # stop greeter and run cosmic-comp (kiosk)
  cosmic-kms-debug.sh stop    # stop cosmic-comp and restart greeter

Environment overrides:
  COSMIC_COMP_BIN   Path to cosmic-comp (default: ~/repos/cosmic-comp/target/release/cosmic-comp)
  KIOSK_CMD         Kiosk child command (default: none)
  LOG_FILE          Log file (default: ~/cosmic-kms-debug.log)
  STATE_FILE        Debug state dump (default: ~/cosmic-kms-debug.state)
  DRM_CARD          DRM device (default: auto-detect lowest /dev/dri/cardN)
  VT_TARGET         VT to switch to before starting (default: 3)
  RUN_AS_ROOT       Run cosmic-comp as root (default: 0)
  FALLBACK_ROOT     If user-run fails, retry as root (default: 1)
  USER_LIBSEAT_BACKEND      Libseat backend for user run (default: logind)
  USER_LIBSEAT_BACKEND_ALT  Fallback libseat backend for user run (default: seatd)
  ROOT_LIBSEAT_BACKEND      Libseat backend for root run (default: seatd)
  USE_DBUS_SESSION          Wrap with dbus-run-session (default: 0)
  USE_SEATD_LAUNCH          Wrap seatd attempts with seatd-launch (default: 1)
USAGE
}

log_msg() {
  local msg="$*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

COSMIC_COMP_BIN_DEFAULT="$HOME/repos/cosmic-comp/target/release/cosmic-comp"
COSMIC_COMP_BIN="${COSMIC_COMP_BIN:-$COSMIC_COMP_BIN_DEFAULT}"
KIOSK_CMD="${KIOSK_CMD:-none}"
LOG_FILE="${LOG_FILE:-$HOME/cosmic-kms-debug.log}"
STATE_FILE="${STATE_FILE:-$HOME/cosmic-kms-debug.state}"
VT_TARGET="${VT_TARGET:-3}"
NUCLEAR="${NUCLEAR:-1}"
RUN_AS_ROOT="${RUN_AS_ROOT:-1}"
FALLBACK_ROOT="${FALLBACK_ROOT:-1}"
USER_LIBSEAT_BACKEND="${USER_LIBSEAT_BACKEND:-logind}"
USER_LIBSEAT_BACKEND_ALT="${USER_LIBSEAT_BACKEND_ALT:-seatd}"
ROOT_LIBSEAT_BACKEND="${ROOT_LIBSEAT_BACKEND:-seatd}"
USE_DBUS_SESSION="${USE_DBUS_SESSION:-0}"
USE_SEATD_LAUNCH="${USE_SEATD_LAUNCH:-1}"
SEATD_STOPPED_FLAG="/tmp/cosmic-seatd-stopped"

resolve_drm_card() {
  if [[ -n "${DRM_CARD:-}" ]]; then
    if [[ -e "$DRM_CARD" ]]; then
      echo "$DRM_CARD"
      return
    fi
  fi

  if command -v loginctl >/dev/null 2>&1; then
    local master
    master="$(loginctl seat-status seat0 2>/dev/null | grep -oE 'drm:card[0-9]+' | head -n 1 || true)"
    if [[ -n "$master" ]]; then
      master="${master#drm:}"
      if [[ -e "/dev/dri/$master" ]]; then
        echo "/dev/dri/$master"
        return
      fi
    fi
  fi

  local cards=(/dev/dri/card[0-9]*)
  if [[ ${#cards[@]} -eq 0 || ! -e "${cards[0]}" ]]; then
    echo ""
    return
  fi

  printf '%s\n' "${cards[@]}" | sort -V | head -n 1
}

current_vt() {
  if command -v fgconsole >/dev/null 2>&1; then
    fgconsole || true
  else
    echo ""
  fi
}

current_session_id() {
  if [[ -n "${XDG_SESSION_ID:-}" ]]; then
    echo "$XDG_SESSION_ID"
  else
    echo ""
  fi
}

active_session_id() {
  if command -v loginctl >/dev/null 2>&1; then
    loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null || true
  fi
}

ensure_vt() {
  local vt_now
  vt_now="$(current_vt)"
  if [[ -n "$vt_now" && "$vt_now" != "$VT_TARGET" ]]; then
    echo "Switching to VT $VT_TARGET (current: $vt_now)..."
    sudo chvt "$VT_TARGET" || true
  fi
}

stop_greeter() {
  echo "Stopping cosmic-greeter.service..."
  sudo systemctl stop cosmic-greeter || true
  sudo systemctl stop greetd || true
  sudo systemctl stop display-manager || true
}

start_seatd() {
  if [[ "$USE_SEATD_LAUNCH" == "1" ]]; then
    return
  fi
  if systemctl list-unit-files | grep -q '^seatd\\.service'; then
    echo "Starting seatd.service..."
    sudo systemctl start seatd || true
  fi
}

prepare_seatd_launch() {
  if [[ "$USE_SEATD_LAUNCH" != "1" ]]; then
    return
  fi
  if systemctl list-unit-files | grep -q '^seatd\\.service'; then
    if systemctl is-active --quiet seatd; then
      echo "Stopping seatd.service for seatd-launch..."
      sudo systemctl stop seatd || true
      touch "$SEATD_STOPPED_FLAG" || true
    fi
  fi
  if [[ -S /run/seatd.sock ]]; then
    sudo rm -f /run/seatd.sock || true
  fi
}

warn_if_missing_video_group() {
  if ! id -nG | tr ' ' '\n' | grep -qx "video"; then
    echo "WARNING: user not in 'video' group; seatd backend may fail. Log out/in or run: sudo usermod -aG video $USER"
  fi
}

start_greeter() {
  echo "Starting cosmic-greeter.service..."
  sudo systemctl start cosmic-greeter || true
}

terminate_other_sessions() {
  local current_sid
  current_sid="$(current_session_id)"

  if ! command -v loginctl >/dev/null 2>&1; then
    return
  fi

  while read -r sid _user _seat _rest; do
    [[ -z "$sid" ]] && continue
    if [[ -n "$current_sid" && "$sid" == "$current_sid" ]]; then
      continue
    fi
    local name
    name="$(loginctl show-session "$sid" -p Name --value 2>/dev/null || true)"
    if [[ "$name" == "$USER" ]]; then
      echo "Terminating session $sid for user $name"
      sudo loginctl terminate-session "$sid" || true
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
}

hard_kill_other_sessions() {
  local current_sid
  current_sid="$(current_session_id)"

  if ! command -v loginctl >/dev/null 2>&1; then
    return
  fi

  while read -r sid _uid _user _seat _tty _state; do
    [[ -z "$sid" ]] && continue
    if [[ -n "$current_sid" && "$sid" == "$current_sid" ]]; then
      continue
    fi
    echo "Force-killing session $sid on ${_seat:-?} ${_tty:-?}"
    sudo loginctl kill-session "$sid" -s SIGKILL || true
  done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
}

nuclear_isolate() {
  if [[ "$NUCLEAR" != "1" ]]; then
    return
  fi

  echo "NUCLEAR=1: isolating to multi-user.target (stops graphical session)"
  sudo systemctl isolate multi-user.target || true
  sleep 1
}

nuclear_kill_active_non_target() {
  if [[ "$NUCLEAR" != "1" ]]; then
    return
  fi

  if ! command -v loginctl >/dev/null 2>&1; then
    return
  fi

  local active_sid
  active_sid="$(active_session_id)"
  if [[ -n "$active_sid" ]]; then
    local active_vt
    active_vt="$(loginctl show-session "$active_sid" -p VTNr --value 2>/dev/null || true)"
    if [[ -n "$active_vt" && "$active_vt" != "$VT_TARGET" ]]; then
      echo "NUCLEAR=1: killing active session $active_sid on VT $active_vt (target VT $VT_TARGET)"
      sudo loginctl kill-session "$active_sid" -s SIGKILL || true
      sleep 1
    fi
  fi
}

ensure_session_active() {
  local sid
  sid="$(current_session_id)"
  if [[ -z "$sid" ]] || ! command -v loginctl >/dev/null 2>&1; then
    return
  fi

  local active
  active="$(loginctl show-session "$sid" -p Active --value 2>/dev/null || true)"
  if [[ "$active" != "yes" ]]; then
    echo "Session $sid not active; attempting loginctl activate $sid"
    sudo loginctl activate "$sid" || true
    sleep 1
  fi
}

kill_common_compositors() {
  sudo pkill -x cosmic-comp || true
  sudo pkill -x cosmic-panel || true
  sudo pkill -f cosmic-workspaces || true
  sudo pkill -x cosmic-files || true
  sudo pkill -f cosmic-applet || true
  sudo pkill -f cosmic-applet-system || true
  sudo pkill -x cosmic-term || true
  sudo pkill -x xdg-desktop-portal || true
  sudo pkill -x xdg-desktop-portal-wlr || true
  sudo pkill -x Xwayland || true
  sudo pkill -x gnome-shell || true
  sudo pkill -x sway || true
  sudo pkill -x kwin_wayland || true
  sudo pkill -x weston || true
}

drm_pids() {
  local card="$1"
  if [[ -n "$card" && -e "$card" ]]; then
    sudo fuser "$card" 2>/dev/null | tr -cs '0-9' '\n' || true
  fi
}

logind_pid() {
  systemctl show -p MainPID --value systemd-logind 2>/dev/null || true
}

show_drm_users() {
  local card="$1"
  if [[ -n "$card" && -e "$card" ]]; then
    echo "Current DRM users for $card:"
    sudo fuser -v "$card" 2>/dev/null || true
    local pids
    pids="$(drm_pids "$card" | paste -sd ' ' -)"
    if [[ -n "$pids" ]]; then
      echo "Processes using $card:"
      ps -o pid=,user=,comm=,args= -p $pids || true
      local lp
      lp="$(logind_pid)"
      if [[ -n "$lp" ]]; then
        echo "systemd-logind PID: $lp"
      fi
    else
      echo "No processes currently using $card."
    fi
  else
    echo "DRM card not found. Available cards:"
    ls -1 /dev/dri/card* 2>/dev/null || true
  fi
}

kill_drm_users() {
  local card="$1"
  if [[ -n "$card" && -e "$card" ]]; then
    echo "Killing processes holding $card (best-effort)..."
    local lp
    lp="$(logind_pid)"
    local pids
    pids="$(drm_pids "$card" | tr '\n' ' ')"
    local kill_list=()
    for pid in $pids; do
      [[ -z "$pid" ]] && continue
      if [[ "$pid" == "1" || "$pid" == "$lp" ]]; then
        continue
      fi
      kill_list+=("$pid")
    done
    if [[ ${#kill_list[@]} -gt 0 ]]; then
      sudo kill -TERM "${kill_list[@]}" || true
      sleep 1
      sudo kill -KILL "${kill_list[@]}" || true
    else
      echo "No killable DRM users found (skipping logind/systemd)."
    fi
  fi
}

dump_debug_state() {
  local card="$1"
  {
    echo "---- DEBUG STATE $(date --iso-8601=seconds) ----"
    echo "VT: $(current_vt)"
    echo "Session: $(current_session_id)"
    if command -v loginctl >/dev/null 2>&1; then
      echo "ActiveSession: $(active_session_id)"
      if [[ -n "$(current_session_id)" ]]; then
        echo "---- loginctl show-session (current) ----"
        loginctl show-session "$(current_session_id)" -p Active -p State -p Type -p Class -p VTNr -p Seat -p Name -p Leader -p TTY -p Remote -p Service -p Display 2>/dev/null || true
      fi
    fi
    echo "NUCLEAR: $NUCLEAR"
    echo "RUN_AS_ROOT: $RUN_AS_ROOT"
    echo "USER_LIBSEAT_BACKEND: $USER_LIBSEAT_BACKEND"
    echo "ROOT_LIBSEAT_BACKEND: $ROOT_LIBSEAT_BACKEND"
    echo "USE_DBUS_SESSION: $USE_DBUS_SESSION"
    echo "USE_SEATD_LAUNCH: $USE_SEATD_LAUNCH"
    echo "XDG_RUNTIME_DIR: ${XDG_RUNTIME_DIR:-}"
    if command -v loginctl >/dev/null 2>&1; then
      echo "---- loginctl list-sessions ----"
      loginctl list-sessions --no-legend || true
      echo "---- loginctl seat-status seat0 ----"
      loginctl seat-status seat0 || true
    fi
    echo "---- /dev/dri ----"
    ls -l /dev/dri 2>/dev/null || true
    echo "---- /dev/dri/by-path ----"
    ls -l /dev/dri/by-path 2>/dev/null || true
    if [[ -n "$card" && -e "$card" ]]; then
      echo "---- card permissions ----"
      stat -c 'path=%n mode=%a owner=%U group=%G' "$card" 2>/dev/null || true
      echo "---- card acl ----"
      getfacl -p "$card" 2>/dev/null || true
      echo "---- card udev ----"
      udevadm info -q property -n "$card" 2>/dev/null || true
      echo "---- user groups ----"
      id -nG || true
    fi
    show_drm_users "$card"
    if [[ -d /sys/kernel/debug/dri ]]; then
      echo "---- /sys/kernel/debug/dri/*/clients ----"
      sudo sh -c 'cat /sys/kernel/debug/dri/*/clients 2>/dev/null || true' || true
      echo "---- /sys/kernel/debug/dri/*/name ----"
      sudo sh -c 'cat /sys/kernel/debug/dri/*/name 2>/dev/null || true' || true
    fi
    echo "---- systemd-logind status ----"
    systemctl is-active systemd-logind 2>/dev/null || true
    systemctl status systemd-logind --no-pager -n 20 2>/dev/null || true
    echo "---- seatd status ----"
    systemctl status seatd --no-pager -n 20 2>/dev/null || true
    echo "---- greetd/cosmic-greeter status ----"
    systemctl status greetd cosmic-greeter --no-pager -n 20 2>/dev/null || true
    echo "---- recent logind logs ----"
    journalctl -u systemd-logind -n 200 --no-pager 2>/dev/null || true
    echo "---- recent kernel logs ----"
    journalctl -k -n 200 --no-pager 2>/dev/null || true
    if [[ -f "$LOG_FILE" ]]; then
      echo "---- Last 200 log lines ----"
      tail -n 200 "$LOG_FILE" || true
    fi
    echo "-----------------------------"
  } | tee "$STATE_FILE"
}

cmd_start() {
  if [[ ! -x "$COSMIC_COMP_BIN" ]]; then
    echo "cosmic-comp not found or not executable: $COSMIC_COMP_BIN" >&2
    exit 1
  fi

  : > "$LOG_FILE"
  log_msg "---- cosmic-kms-debug start $(date --iso-8601=seconds) ----"
  log_msg "VT_TARGET=$VT_TARGET NUCLEAR=$NUCLEAR RUN_AS_ROOT=$RUN_AS_ROOT FALLBACK_ROOT=$FALLBACK_ROOT USE_DBUS_SESSION=$USE_DBUS_SESSION USE_SEATD_LAUNCH=$USE_SEATD_LAUNCH USER_LIBSEAT_BACKEND=$USER_LIBSEAT_BACKEND USER_LIBSEAT_BACKEND_ALT=$USER_LIBSEAT_BACKEND_ALT ROOT_LIBSEAT_BACKEND=$ROOT_LIBSEAT_BACKEND"
  log_msg "COSMIC_COMP_BIN=$COSMIC_COMP_BIN KIOSK_CMD=$KIOSK_CMD LOG_FILE=$LOG_FILE STATE_FILE=$STATE_FILE"
  log_msg "TTY=$(tty 2>/dev/null || echo 'notty') FGCONSOLE=$(fgconsole 2>/dev/null || echo 'n/a')"
  log_msg "Forcing VT switch to $VT_TARGET..."
  sudo chvt "$VT_TARGET" || true
  sleep 1

  local card
  card="$(resolve_drm_card)"

  ensure_vt
  nuclear_isolate
  stop_greeter
  start_seatd
  warn_if_missing_video_group
  nuclear_kill_active_non_target
  terminate_other_sessions
  hard_kill_other_sessions
  ensure_session_active
  kill_common_compositors
  show_drm_users "$card"
  kill_drm_users "$card"
  show_drm_users "$card"

  # Always write a state snapshot before starting
  dump_debug_state "$card"

  log_msg "Starting cosmic-comp (KMS) with kiosk child: $KIOSK_CMD"
  log_msg "Log: $LOG_FILE"
  log_msg "State dump: $STATE_FILE"
  local kiosk_args=()
  if [[ -n "$KIOSK_CMD" && "$KIOSK_CMD" != "none" ]]; then
    kiosk_args=("$KIOSK_CMD")
  fi
  log_msg "CMD: $COSMIC_COMP_BIN ${kiosk_args[*]}"
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
  fi

  local dbus_prefix=()
  if [[ "$USE_DBUS_SESSION" == "1" ]] && command -v dbus-run-session >/dev/null 2>&1; then
    dbus_prefix=(dbus-run-session --)
  fi

  run_comp() {
    local as_root="$1"
    local backend="$2"
    local launch_prefix=()
    if [[ "$as_root" == "0" && "$backend" == "seatd" && "$USE_SEATD_LAUNCH" == "1" ]]; then
      log_msg "Skipping user-seatd: seatd-launch requires root to bind /run/seatd.sock"
      return 1
    fi
    if [[ "$backend" == "seatd" && "$USE_SEATD_LAUNCH" == "1" && -x /usr/bin/seatd-launch ]]; then
      prepare_seatd_launch
      launch_prefix=(seatd-launch --)
      log_msg "Using seatd-launch wrapper for backend=$backend"
    fi
    local cmd_prefix=("${launch_prefix[@]}" "${dbus_prefix[@]}")
    if [[ "$as_root" == "1" ]]; then
      sudo mkdir -p /run/user/0 || true
      sudo chmod 700 /run/user/0 || true
      log_msg "RUNNING AS ROOT (XDG_RUNTIME_DIR=/run/user/0, LIBSEAT_BACKEND=$backend)"
      set +e
      sudo -E env \
        LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
        RUST_LOG=info,smithay=info \
        RUST_BACKTRACE=1 \
        LIBSEAT_BACKEND="$backend" \
        XDG_RUNTIME_DIR=/run/user/0 \
        SMITHAY_CACHE_LOG=1 \
        "${cmd_prefix[@]}" "$COSMIC_COMP_BIN" "${kiosk_args[@]}" 2>&1 | tee -a "$LOG_FILE"
      local code=${PIPESTATUS[0]}
      set -e
      return $code
    else
      log_msg "RUNNING AS USER (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR, LIBSEAT_BACKEND=$backend)"
      set +e
      LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
      RUST_LOG=info,smithay=info \
      RUST_BACKTRACE=1 \
      LIBSEAT_BACKEND="$backend" \
      SMITHAY_CACHE_LOG=1 \
      "${cmd_prefix[@]}" "$COSMIC_COMP_BIN" "${kiosk_args[@]}" 2>&1 | tee -a "$LOG_FILE"
      local code=${PIPESTATUS[0]}
      set -e
      return $code
    fi
  }

  attempt() {
    local as_root="$1"
    local backend="$2"
    local label="$3"
    local start_line
    start_line="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"

    if ! run_comp "$as_root" "$backend"; then
      local code=$?
      log_msg "Attempt $label exited with status $code"
      log_msg "Dumping debug state..."
      dump_debug_state "$card"
      return 1
    fi

    # Detect drm-master failure even if exit code is 0
    if tail -n +"$((start_line + 1))" "$LOG_FILE" | grep -Fq "Unable to become drm master"; then
      log_msg "Attempt $label detected: Unable to become drm master"
      log_msg "Dumping debug state..."
      dump_debug_state "$card"
      return 1
    fi
    if tail -n +"$((start_line + 1))" "$LOG_FILE" | grep -Fq "Failed to acquire session"; then
      log_msg "Attempt $label detected: Failed to acquire session"
      log_msg "Dumping debug state..."
      dump_debug_state "$card"
      return 1
    fi
    if tail -n +"$((start_line + 1))" "$LOG_FILE" | grep -Fq "Couldn't get a file descriptor referring to the console"; then
      log_msg "Attempt $label detected: No controlling console"
      log_msg "Dumping debug state..."
      dump_debug_state "$card"
      return 1
    fi

    return 0
  }

  if [[ "$RUN_AS_ROOT" == "1" ]]; then
    attempt "1" "$ROOT_LIBSEAT_BACKEND" "root-$ROOT_LIBSEAT_BACKEND" || exit 1
  else
    attempt "0" "$USER_LIBSEAT_BACKEND" "user-$USER_LIBSEAT_BACKEND" || {
      if [[ "$USER_LIBSEAT_BACKEND_ALT" != "$USER_LIBSEAT_BACKEND" ]]; then
        log_msg "Retrying as user with backend $USER_LIBSEAT_BACKEND_ALT..."
        attempt "0" "$USER_LIBSEAT_BACKEND_ALT" "user-$USER_LIBSEAT_BACKEND_ALT" || true
      fi
      if [[ "$FALLBACK_ROOT" == "1" ]]; then
        log_msg "Retrying as root (fallback) with backend $ROOT_LIBSEAT_BACKEND..."
        attempt "1" "$ROOT_LIBSEAT_BACKEND" "root-$ROOT_LIBSEAT_BACKEND" || exit 1
      else
        exit 1
      fi
    }
  fi
}

cmd_stop() {
  if pgrep -x cosmic-comp >/dev/null 2>&1; then
    echo "Stopping cosmic-comp..."
    sudo pkill -x cosmic-comp || true
    sudo pkill -x cosmic-term || true
    sleep 1
  fi

  if [[ "$NUCLEAR" == "1" ]]; then
    echo "Restoring graphical.target..."
    sudo systemctl isolate graphical.target || true
  fi

  if [[ -f "$SEATD_STOPPED_FLAG" ]]; then
    echo "Restarting seatd.service..."
    sudo systemctl start seatd || true
    rm -f "$SEATD_STOPPED_FLAG" || true
  fi

  start_greeter
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
