#!/usr/bin/env bash
set -euo pipefail

# Open/close windows in cycles, measure VRAM deltas.
# Run from a terminal inside the cosmic-debug.sh session.

CYCLES="${CYCLES:-3}"
WINDOWS="${WINDOWS:-20}"
OPEN_CMD="${OPEN_CMD:-cosmic-term}"
SLEEP_OPEN="${SLEEP_OPEN:-5}"
SLEEP_CLOSE="${SLEEP_CLOSE:-5}"
MAX_VRAM_MB="${MAX_VRAM_MB:-5000}"
COMPOSITOR_LOG="${COMPOSITOR_LOG:-/tmp/cosmic-debug.log}"
TAG_ENV_NAME="COSMIC_VRAM_TAG"

# --- helpers ---

vram_mb() {
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits \
    | head -n 1 | tr -d ' '
}

smithay_stats() {
  if [[ ! -f "$COMPOSITOR_LOG" ]]; then
    return
  fi
  # Strip ANSI codes, grab last smithay cache stats line
  sed -r 's/\x1b\[[0-9;]*m//g' "$COMPOSITOR_LOG" \
    | grep "smithay gles cleanup cache stats" \
    | tail -n 1 || true
}

find_tagged_pids() {
  local tag_value="$1"
  local envfile pid
  for envfile in /proc/[0-9]*/environ; do
    {
      [[ -r "$envfile" ]] || continue
      if tr '\0' '\n' < "$envfile" | grep -qx "${TAG_ENV_NAME}=${tag_value}"; then
        pid="${envfile#/proc/}"
        pid="${pid%/environ}"
        echo "$pid"
      fi
    } 2>/dev/null
  done
}

kill_tagged() {
  local tag_value="$1"
  local pids=()
  while read -r pid; do
    pids+=("$pid")
  done < <(find_tagged_pids "$tag_value")

  echo "  Found ${#pids[@]} tagged processes"
  if [[ ${#pids[@]} -eq 0 ]]; then
    return
  fi

  # SIGTERM first
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 2
  # SIGKILL stragglers
  for pid in "${pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

check_vram_safety() {
  if [[ "$MAX_VRAM_MB" -le 0 ]]; then
    return 1
  fi
  local now
  now="$(vram_mb)"
  if [[ "$now" -ge "$MAX_VRAM_MB" ]]; then
    echo "SAFETY ABORT: VRAM ${now} MB >= limit ${MAX_VRAM_MB} MB"
    return 0
  fi
  return 1
}

# --- main ---

echo "=== VRAM Leak Test ==="
echo "  CYCLES=$CYCLES  WINDOWS=$WINDOWS  OPEN_CMD=$OPEN_CMD"
echo "  SLEEP_OPEN=$SLEEP_OPEN  SLEEP_CLOSE=$SLEEP_CLOSE"
echo "  MAX_VRAM_MB=$MAX_VRAM_MB (0=disabled)"
echo "  COMPOSITOR_LOG=$COMPOSITOR_LOG"
echo ""

baseline_vram="$(vram_mb)"
baseline_stats="$(smithay_stats)"
echo "Baseline: ${baseline_vram} MB VRAM"
if [[ -n "$baseline_stats" ]]; then
  echo "  smithay: $baseline_stats"
fi
echo ""

for cycle in $(seq 1 "$CYCLES"); do
  echo "--- Cycle $cycle/$CYCLES ---"

  # Open windows with unique env tag
  tag="vram-${RANDOM}-${RANDOM}-${cycle}"
  echo "  Opening $WINDOWS windows..."
  for _ in $(seq 1 "$WINDOWS"); do
    env "${TAG_ENV_NAME}=${tag}" $OPEN_CMD >/dev/null 2>&1 &
    sleep 0.2
    if check_vram_safety; then
      exit 1
    fi
  done

  # Snapshot at peak
  sleep "$SLEEP_OPEN"
  peak_vram="$(vram_mb)"
  echo "  Peak: ${peak_vram} MB VRAM"

  # Close windows
  echo "  Closing windows..."
  kill_tagged "$tag"
  sleep "$SLEEP_CLOSE"

  # Snapshot after close
  after_vram="$(vram_mb)"
  after_stats="$(smithay_stats)"
  delta=$((after_vram - baseline_vram))
  echo "  After close: ${after_vram} MB VRAM (delta: ${delta} MB from baseline)"
  if [[ -n "$after_stats" ]]; then
    echo "  smithay: $after_stats"
  fi
  echo ""

  if check_vram_safety; then
    exit 1
  fi
done

# Final summary
final_vram="$(vram_mb)"
total_delta=$((final_vram - baseline_vram))
echo "=== Summary ==="
echo "  Baseline: ${baseline_vram} MB"
echo "  Final:    ${final_vram} MB"
echo "  Total delta: ${total_delta} MB after $CYCLES cycles of $WINDOWS windows"
echo ""
if [[ "$total_delta" -le 10 ]]; then
  echo "  PASS - VRAM is stable (delta <= 10 MB)"
else
  echo "  FAIL - VRAM grew by ${total_delta} MB (likely leaking)"
fi
