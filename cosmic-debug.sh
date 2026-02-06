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
  LOG_FILE         Log output        (default: ~/cosmic-debug.log)
  VT_TARGET        VT to switch to   (default: 3)
  RUST_LOG         Log filter        (default: info,smithay=info)
  LIBSEAT_BACKEND  Seat backend      (default: seatd)
EOF
}

COSMIC_COMP_BIN="${COSMIC_COMP_BIN:-$HOME/repos/cosmic-comp/target/release/cosmic-comp}"
LOG_FILE="${LOG_FILE:-/tmp/cosmic-debug.log}"
VT_TARGET="${VT_TARGET:-3}"
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
  echo "  VT_TARGET=$VT_TARGET"
  echo "  RUST_LOG=$RUST_LOG"
  echo "  LIBSEAT_BACKEND=$LIBSEAT_BACKEND"
  echo ""

  # Truncate log
  : > "$LOG_FILE"

  # Switch to target VT
  echo "Switching to VT $VT_TARGET..."
  sudo chvt "$VT_TARGET"

  # Stop all graphical services (greeter, compositor, display manager)
  echo "Isolating to multi-user.target..."
  sudo systemctl isolate multi-user.target
  sleep 2

  # Safety kill any leftover cosmic-comp
  sudo pkill -x cosmic-comp 2>/dev/null || true

  # Ensure runtime dir and seatd
  sudo mkdir -p /run/user/0
  sudo chmod 700 /run/user/0
  sudo systemctl start seatd || true

  # Launch cosmic-comp as root
  echo "Starting cosmic-comp..."
  echo "Log: $LOG_FILE"
  echo ""
  sudo env \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    RUST_LOG="$RUST_LOG" \
    RUST_BACKTRACE=1 \
    LIBSEAT_BACKEND="$LIBSEAT_BACKEND" \
    XDG_RUNTIME_DIR=/run/user/0 \
    SMITHAY_CACHE_LOG=1 \
    "$COSMIC_COMP_BIN" 2>&1 | tee -a "$LOG_FILE"
}

cmd_stop() {
  echo "Stopping cosmic-comp..."
  sudo pkill -x cosmic-comp 2>/dev/null || true
  sleep 1

  echo "Restoring graphical.target..."
  sudo systemctl isolate graphical.target
}

case "${1:-}" in
  start) cmd_start ;;
  stop)  cmd_stop ;;
  -h|--help) usage ;;
  *) usage; exit 1 ;;
esac
