#!/usr/bin/env bash
set -euo pipefail

# Start/stop a custom cosmic-comp binary on KMS.
# Designed for Pop!_OS with NVIDIA GPU, root + seatd.

usage() {
  cat <<'EOF'
Usage:
  cosmic-debug.sh start   # stop desktop, run custom cosmic-comp on KMS
  cosmic-debug.sh stop    # stop cosmic-comp, restore desktop

Environment variables (all optional):
  COSMIC_COMP_BIN  Path to binary    (default: ~/repos/cosmic-comp/target/release/cosmic-comp)
  LOG_FILE         Log output        (default: /tmp/cosmic-debug.log)
  RUST_LOG         Log filter        (default: info,smithay=info)
  LIBSEAT_BACKEND  Seat backend      (default: seatd)
EOF
}

COSMIC_COMP_BIN="${COSMIC_COMP_BIN:-$HOME/repos/cosmic-comp/target/release/cosmic-comp}"
LOG_FILE="${LOG_FILE:-/tmp/cosmic-debug.log}"
RUST_LOG="${RUST_LOG:-info,smithay=info}"
LIBSEAT_BACKEND="${LIBSEAT_BACKEND:-seatd}"

cmd_start() {
  if [[ ! -x "$COSMIC_COMP_BIN" ]]; then
    echo "Error: binary not found or not executable: $COSMIC_COMP_BIN" >&2
    exit 1
  fi

  echo "Config:"
  echo "  COSMIC_COMP_BIN=$COSMIC_COMP_BIN"
  echo "  LOG_FILE=$LOG_FILE"
  echo "  RUST_LOG=$RUST_LOG"
  echo "  LIBSEAT_BACKEND=$LIBSEAT_BACKEND"
  echo ""

  # Truncate log and make writable by non-root users
  sudo sh -c ": > '$LOG_FILE' && chmod 666 '$LOG_FILE'"

  # Stop all graphical services (greeter, compositor, display manager)
  echo "Isolating to multi-user.target..."
  sudo systemctl isolate multi-user.target
  sleep 2

  # Safety kill any leftover cosmic-comp (including renamed binaries like cosmic-comp-A)
  sudo pkill -x "cosmic-comp-[A-Z]" 2>/dev/null || true
  sudo pkill -x cosmic-comp 2>/dev/null || true

  # Ensure runtime dir
  sudo mkdir -p /run/user/0
  sudo chmod 700 /run/user/0

  # Stop system seatd and clean socket — seatd-launch will start a fresh instance
  sudo systemctl stop seatd 2>/dev/null || true
  sudo rm -f /run/seatd.sock

  # Launch cosmic-comp via seatd-launch (provides a clean seatd session)
  echo "Starting cosmic-comp..."
  echo "Log: $LOG_FILE"
  echo ""
  sudo -E env \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    RUST_LOG="$RUST_LOG" \
    RUST_BACKTRACE=1 \
    LIBSEAT_BACKEND="$LIBSEAT_BACKEND" \
    XDG_RUNTIME_DIR=/run/user/0 \
    SMITHAY_CACHE_LOG=1 \
    seatd-launch -- "$COSMIC_COMP_BIN" 2>&1 | tee -a "$LOG_FILE"
}

cmd_stop() {
  echo "Stopping compositor and restoring desktop..."

  # Run stop sequence detached — if run from inside the compositor,
  # killing cosmic-comp kills the terminal and this script with it.
  # setsid + nohup ensures the sequence completes regardless.
  sudo setsid nohup bash -c '
    sleep 0.5
    pkill -x "cosmic-comp-[A-Z]" 2>/dev/null || true
    pkill -x cosmic-comp 2>/dev/null || true
    pkill -x seatd-launch 2>/dev/null || true
    rm -f /run/seatd.sock
    sleep 1
    systemctl start seatd || true
    systemctl isolate graphical.target
  ' &>/dev/null &
}

case "${1:-}" in
  start) cmd_start ;;
  stop)  cmd_stop ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
