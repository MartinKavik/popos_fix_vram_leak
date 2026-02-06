#!/usr/bin/env bash
set -euo pipefail

SNAPSHOT_CMD="${SNAPSHOT_CMD:-/home/martinkavik/bin/cosmic-vram-snapshot.sh}"
CYCLES="${CYCLES:-3}"
WINDOWS_TARGET="${WINDOWS_TARGET:-20}"
OPEN_CMD="${OPEN_CMD:-cosmic-term}"
SLEEP_OPEN="${SLEEP_OPEN:-5}"
SLEEP_CLOSE="${SLEEP_CLOSE:-5}"
OPEN_DELAY="${OPEN_DELAY:-0.2}"
MAX_VRAM_MB="${MAX_VRAM_MB:-5000}"
LOG_FILE="${LOG_FILE:-/home/martinkavik/cosmic-vram-plateau-auto.log}"
TAG_ENV_NAME="COSMIC_VRAM_TAG"
TARGET_WINDOWS_AFTER="${TARGET_WINDOWS_AFTER:-2}"
WAIT_WINDOWS_TIMEOUT="${WAIT_WINDOWS_TIMEOUT:-3}"
WAIT_WINDOWS_POLL="${WAIT_WINDOWS_POLL:-1}"

if [[ -z "$OPEN_CMD" ]]; then
  echo "OPEN_CMD is required." | tee -a "$LOG_FILE"
  exit 1
fi

if [[ ! -x "$SNAPSHOT_CMD" ]]; then
  echo "Snapshot script not found or not executable: $SNAPSHOT_CMD" | tee -a "$LOG_FILE"
  exit 1
fi

run_snapshot() {
  "$SNAPSHOT_CMD" | tee -a "$LOG_FILE"
}

extract_vram_mb() {
  sed -n 's/.*VRAM_MB=\([0-9]\+\).*/\1/p'
}

extract_smithay_stats() {
  sed -n 's/.*smithay gles cleanup cache stats //p'
}

find_tagged_pids() {
  local tag_value="$1"
  local envfile pid env_content
  for envfile in /proc/[0-9]*/environ; do
    {
      [[ -r "$envfile" ]] || continue
      env_content="$(tr '\0' '\n' <"$envfile" || true)"
      if [[ -n "$env_content" ]] && printf '%s\n' "$env_content" | grep -qx "${TAG_ENV_NAME}=${tag_value}"; then
        pid="${envfile#/proc/}"
        pid="${pid%/environ}"
        echo "$pid"
      fi
    } 2>/dev/null
  done
}

current_vram_mb() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -n 1 | tr -d ' ' || true
  else
    echo ""
  fi
}

maybe_abort_for_vram() {
  local vram_now
  if [[ "$MAX_VRAM_MB" -gt 0 ]]; then
    vram_now="$(current_vram_mb)"
    if [[ -n "$vram_now" && "$vram_now" -ge "$MAX_VRAM_MB" ]]; then
      echo "Safety stop: VRAM ${vram_now}MB >= MAX_VRAM_MB ${MAX_VRAM_MB}" | tee -a "$LOG_FILE"
      return 0
    fi
  fi
  return 1
}

print_cycle_delta() {
  local label="$1"
  local base_vram="$2"
  local base_stats="$3"
  local after_vram="$4"
  local after_stats="$5"
  if [[ -n "$base_vram" && -n "$after_vram" ]]; then
    local delta=$((after_vram - base_vram))
    echo "${label} delta: VRAM_MB ${after_vram} (Δ ${delta})" | tee -a "$LOG_FILE"
  else
    echo "${label} delta: VRAM_MB unknown" | tee -a "$LOG_FILE"
  fi
  if [[ -n "$base_stats" || -n "$after_stats" ]]; then
    echo "${label} smithay stats baseline: ${base_stats:-<none>}" | tee -a "$LOG_FILE"
    echo "${label} smithay stats after:    ${after_stats:-<none>}" | tee -a "$LOG_FILE"
  fi
}

last_windows_count() {
  local cmd_basename
  cmd_basename="$(basename "$OPEN_CMD")"
  local count
  count="$(pgrep -c -x "$cmd_basename" 2>/dev/null || echo "0")"
  echo "$count"
}

stamp() {
  date +'%F %T %z'
}

{
  echo "---- plateau auto start $(stamp) ----"
  echo "CYCLES=$CYCLES WINDOWS_TARGET=$WINDOWS_TARGET"
  echo "OPEN_CMD=$OPEN_CMD"
  echo "SLEEP_OPEN=$SLEEP_OPEN SLEEP_CLOSE=$SLEEP_CLOSE OPEN_DELAY=$OPEN_DELAY"
  echo "MAX_VRAM_MB=$MAX_VRAM_MB (0 = disabled)"
  echo "TARGET_WINDOWS_AFTER=$TARGET_WINDOWS_AFTER WAIT_WINDOWS_TIMEOUT=$WAIT_WINDOWS_TIMEOUT WAIT_WINDOWS_POLL=$WAIT_WINDOWS_POLL"
} | tee -a "$LOG_FILE"

echo "Baseline snapshot..." | tee -a "$LOG_FILE"
baseline_out="$(run_snapshot)"
baseline_vram="$(printf '%s\n' "$baseline_out" | extract_vram_mb | tail -n 1)"
baseline_stats="$(printf '%s\n' "$baseline_out" | extract_smithay_stats | tail -n 1)"

echo "" | tee -a "$LOG_FILE"

for i in $(seq 1 "$CYCLES"); do
  echo "Cycle $i/$CYCLES: opening $WINDOWS_TARGET windows..." | tee -a "$LOG_FILE"
  tag_value="vram-${RANDOM}-${RANDOM}-${i}"
  abort_cycle=0
  for _ in $(seq 1 "$WINDOWS_TARGET"); do
    env "${TAG_ENV_NAME}=${tag_value}" $OPEN_CMD >/dev/null 2>&1 &
    sleep "$OPEN_DELAY"
    if maybe_abort_for_vram; then
      echo "Aborting window creation early due to VRAM safety stop." | tee -a "$LOG_FILE"
      abort_cycle=1
      break
    fi
  done

  sleep "$SLEEP_OPEN"
  if [[ "$abort_cycle" == "0" ]]; then
    echo "Snapshot (peak)" | tee -a "$LOG_FILE"
    peak_out="$(run_snapshot)"
    peak_vram="$(printf '%s\n' "$peak_out" | extract_vram_mb | tail -n 1)"
  else
    echo "Skipping peak snapshot due to safety stop." | tee -a "$LOG_FILE"
  fi

  echo "Closing windows..." | tee -a "$LOG_FILE"
  tagged_pids=()
  while read -r pid; do
    tagged_pids+=("$pid")
  done < <(find_tagged_pids "$tag_value")
  echo "Found ${#tagged_pids[@]} tagged processes" | tee -a "$LOG_FILE"

  for pid in "${tagged_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  sleep "$SLEEP_CLOSE"
  for pid in "${tagged_pids[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  sleep 1

  if [[ "$WAIT_WINDOWS_TIMEOUT" -gt 0 ]]; then
    echo "Waiting for windows to drop to <= $TARGET_WINDOWS_AFTER ..." | tee -a "$LOG_FILE"
    waited=0
    while [[ "$waited" -lt "$WAIT_WINDOWS_TIMEOUT" ]]; do
      count="$(last_windows_count || true)"
      if [[ -n "$count" && "$count" -le "$TARGET_WINDOWS_AFTER" ]]; then
        echo "Windows count reached $count" | tee -a "$LOG_FILE"
        break
      fi
      if maybe_abort_for_vram; then
        echo "Safety stop during close wait (VRAM high). Forcing exit." | tee -a "$LOG_FILE"
        exit 1
      fi
      sleep "$WAIT_WINDOWS_POLL"
      waited=$((waited + WAIT_WINDOWS_POLL))
    done
    if [[ "$waited" -ge "$WAIT_WINDOWS_TIMEOUT" ]]; then
      echo "Window count did not drop in time. Aborting to avoid VRAM exhaustion." | tee -a "$LOG_FILE"
      exit 1
    fi
  fi

  echo "Snapshot (after close)" | tee -a "$LOG_FILE"
  after_out="$(run_snapshot)"
  after_vram="$(printf '%s\n' "$after_out" | extract_vram_mb | tail -n 1)"
  after_stats="$(printf '%s\n' "$after_out" | extract_smithay_stats | tail -n 1)"
  print_cycle_delta "Cycle $i" "$baseline_vram" "$baseline_stats" "$after_vram" "$after_stats"
  echo "" | tee -a "$LOG_FILE"

  if [[ "$abort_cycle" == "1" ]]; then
    echo "Aborting remaining cycles due to safety stop." | tee -a "$LOG_FILE"
    break
  fi

done

echo "---- plateau auto end $(stamp) ----" | tee -a "$LOG_FILE"
