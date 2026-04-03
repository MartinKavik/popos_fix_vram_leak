#!/usr/bin/env bash
set -euo pipefail

# CPU usage test for cosmic-comp screencopy fix.
# Run from a terminal inside the cosmic-debug.sh session.

COMP_PID="${COMP_PID:-}"
WINDOWS="${WINDOWS:-5}"
CYCLES="${CYCLES:-10}"
OPEN_CMD="${OPEN_CMD:-cosmic-term}"
SAMPLE_SECS="${SAMPLE_SECS:-5}"
IDLE_WAIT="${IDLE_WAIT:-10}"
PASS_THRESHOLD="${PASS_THRESHOLD:-15}"

# --- helpers ---

find_comp_pid() {
  if [[ -n "$COMP_PID" ]]; then
    echo "$COMP_PID"
    return
  fi
  pgrep -x cosmic-comp | head -1
}

# Average CPU% over $1 seconds for PID $2
avg_cpu() {
  local secs="$1" pid="$2"
  local samples=()
  for _ in $(seq 1 "$secs"); do
    # ps %cpu is cumulative; top -bn1 gives instantaneous
    local cpu
    cpu=$(top -bn1 -p "$pid" 2>/dev/null | awk -v p="$pid" '$1==p {print $9}')
    if [[ -n "$cpu" ]]; then
      samples+=("$cpu")
    fi
    sleep 1
  done
  if [[ ${#samples[@]} -eq 0 ]]; then
    echo "0"
    return
  fi
  # Average using awk
  printf '%s\n' "${samples[@]}" | awk '{s+=$1} END {printf "%.1f", s/NR}'
}

open_windows() {
  local n="$1" tag="$2"
  for _ in $(seq 1 "$n"); do
    env COSMIC_CPU_TAG="$tag" $OPEN_CMD >/dev/null 2>&1 &
    sleep 0.3
  done
  sleep 3
}

kill_tagged() {
  local tag="$1"
  for envfile in /proc/[0-9]*/environ; do
    {
      [[ -r "$envfile" ]] || continue
      if tr '\0' '\n' < "$envfile" | grep -qx "COSMIC_CPU_TAG=$tag"; then
        local pid="${envfile#/proc/}"
        pid="${pid%/environ}"
        kill "$pid" 2>/dev/null || true
      fi
    } 2>/dev/null
  done
  sleep 2
}

# --- test modes ---

test_overview() {
  local pid
  pid=$(find_comp_pid)
  echo "=== CPU Test: Workspace Overview Recovery ==="
  echo "  cosmic-comp PID: $pid"
  echo "  WINDOWS=$WINDOWS  SAMPLE_SECS=$SAMPLE_SECS  IDLE_WAIT=$IDLE_WAIT"
  echo ""

  echo "1. Measuring baseline CPU (${SAMPLE_SECS}s)..."
  local baseline
  baseline=$(avg_cpu "$SAMPLE_SECS" "$pid")
  echo "   Baseline: ${baseline}%"

  echo "2. Opening $WINDOWS windows..."
  local tag="cpu-$$-${RANDOM}"
  open_windows "$WINDOWS" "$tag"
  local with_windows
  with_windows=$(avg_cpu "$SAMPLE_SECS" "$pid")
  echo "   With windows: ${with_windows}%"

  echo "3. Workspace overview should be opened now (press Super+W)..."
  echo "   Measuring peak CPU in 10 seconds..."
  sleep 2
  local during_overview
  during_overview=$(avg_cpu "$SAMPLE_SECS" "$pid")
  echo "   During overview: ${during_overview}%"

  echo "4. Close the overview (press Super+W or Escape)..."
  echo "   Waiting ${IDLE_WAIT}s for sessions to go idle..."
  sleep "$IDLE_WAIT"
  local after_overview
  after_overview=$(avg_cpu "$SAMPLE_SECS" "$pid")
  echo "   After overview close: ${after_overview}%"

  echo "5. Cleaning up windows..."
  kill_tagged "$tag"

  echo ""
  echo "=== Summary ==="
  echo "  Baseline:        ${baseline}%"
  echo "  With windows:    ${with_windows}%"
  echo "  During overview: ${during_overview}%"
  echo "  After overview:  ${after_overview}%"

  local delta
  delta=$(awk "BEGIN {printf \"%.1f\", $after_overview - $with_windows}")
  echo "  Delta (after - with_windows): ${delta}%"
  echo ""

  if awk "BEGIN {exit !($delta > $PASS_THRESHOLD)}"; then
    echo "  FAIL - CPU did not recover after closing overview (delta ${delta}% > ${PASS_THRESHOLD}%)"
    exit 1
  else
    echo "  PASS - CPU recovered after closing overview (delta ${delta}% <= ${PASS_THRESHOLD}%)"
  fi
}

test_stability() {
  local pid
  pid=$(find_comp_pid)
  echo "=== CPU Test: Long Session Stability ==="
  echo "  cosmic-comp PID: $pid"
  echo "  CYCLES=$CYCLES  WINDOWS=$WINDOWS  IDLE_WAIT=$IDLE_WAIT"
  echo ""

  echo "Measuring baseline CPU (${SAMPLE_SECS}s)..."
  local baseline
  baseline=$(avg_cpu "$SAMPLE_SECS" "$pid")
  echo "Baseline: ${baseline}%"
  echo ""

  local last_idle="$baseline"
  for cycle in $(seq 1 "$CYCLES"); do
    echo "--- Cycle $cycle/$CYCLES ---"
    local tag="cpu-$$-${RANDOM}-${cycle}"

    echo "  Opening $WINDOWS windows..."
    open_windows "$WINDOWS" "$tag"

    echo "  Simulating overview interaction (user should press Super+W, wait 2s, close)..."
    sleep 5

    echo "  Closing windows..."
    kill_tagged "$tag"

    echo "  Waiting ${IDLE_WAIT}s for idle..."
    sleep "$IDLE_WAIT"

    last_idle=$(avg_cpu "$SAMPLE_SECS" "$pid")
    echo "  Idle CPU: ${last_idle}%"
    echo ""
  done

  echo "=== Summary ==="
  echo "  Baseline:   ${baseline}%"
  echo "  Final idle: ${last_idle}%"

  local delta
  delta=$(awk "BEGIN {printf \"%.1f\", $last_idle - $baseline}")
  echo "  Delta: ${delta}%"
  echo ""

  if awk "BEGIN {exit !($delta > $PASS_THRESHOLD)}"; then
    echo "  FAIL - CPU grew over time (delta ${delta}% > ${PASS_THRESHOLD}%)"
    exit 1
  else
    echo "  PASS - CPU is stable (delta ${delta}% <= ${PASS_THRESHOLD}%)"
  fi
}

# --- main ---

case "${1:-}" in
  overview)  test_overview ;;
  stability) test_stability ;;
  *)
    echo "Usage: $0 {overview|stability}"
    echo ""
    echo "  overview   - Test CPU recovery after closing workspace overview"
    echo "  stability  - Test CPU stability over repeated workspace interactions"
    echo ""
    echo "Environment variables:"
    echo "  COMP_PID        cosmic-comp PID (auto-detected if not set)"
    echo "  WINDOWS          Number of windows per cycle (default: 5)"
    echo "  CYCLES           Number of cycles for stability test (default: 10)"
    echo "  OPEN_CMD         Command to open windows (default: cosmic-term)"
    echo "  SAMPLE_SECS      Seconds to sample CPU (default: 5)"
    echo "  IDLE_WAIT        Seconds to wait for idle after overview (default: 10)"
    echo "  PASS_THRESHOLD   Max acceptable CPU delta % (default: 15)"
    exit 1
    ;;
esac
