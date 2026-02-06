#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="${1:-/home/martinkavik/cosmic-kms-debug.log}"
STAMP="$(date +'%F %T %z')"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[$STAMP] nvidia-smi not found"
  exit 1
fi
VRAM_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -n 1 | tr -d ' ')
if [[ -f "$LOG_FILE" ]]; then
  LAST_LOG=$(sed -r 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" | grep "backend::render: vram_log" | tail -n 1 || true)
  LAST_SMITHAY=$(sed -r 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" | grep "smithay gles cleanup cache stats" | tail -n 1 || true)
else
  LAST_LOG="(log not found: $LOG_FILE)"
  LAST_SMITHAY=""
fi

printf '[%s] VRAM_MB=%s\n' "$STAMP" "$VRAM_USED"
printf '%s\n' "$LAST_LOG"
if [[ -n "$LAST_SMITHAY" ]]; then
  printf '%s\n' "$LAST_SMITHAY"
fi
