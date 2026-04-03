# NVIDIA Render Busy-Loop Fix

**Date:** 2026-03-01
**Status:** Deployed for testing

---

## Problem

cosmic-comp uses **80% CPU** while the GPU sits idle at P8/15W. The lag recurs after hours of use and worsens after suspend/resume. All previous CPU optimizations (screencopy throttling, fence fixes, render coalescing, overload detection) were deployed but insufficient.

## Root Cause: NVIDIA `next_render_time()` Returns `Duration::ZERO`

**File:** `~/repos/cosmic-comp/src/backend/kms/surface/timings.rs:409-412`

The upstream cosmic-comp has a hack for NVIDIA GPUs:

```rust
// HACK: Nvidia returns `page_flip`/`commit` early, so we have no
// information to optimize latency on submission.
if self.vendor == Some(0x10de) {
    return Duration::ZERO;
}
```

### How This Causes a Busy-Loop

1. `next_render_time()` returns `Duration::ZERO` for NVIDIA (vendor 0x10de)
2. `queue_redraw_with_delay()` converts zero to `Timer::immediate()` (fires on next event loop iteration)
3. `redraw()` runs immediately, submits frame to DRM
4. VBlank arrives, `on_vblank()` checks `animations_going()` or `redraw_needed`
5. If either is true, calls `queue_redraw()` which again creates `Timer::immediate()`
6. **The surface thread never sleeps between frames**

On Intel/AMD, `next_render_time()` returns a positive duration (~10-14ms at 60Hz), so the surface thread sleeps between frames. On NVIDIA, it's a CPU busy-loop at maximum speed.

### Code Path Trace

```
queue_redraw_with_delay(force=false, retry_delay=None)
  -> next_render_time() returns Duration::ZERO for NVIDIA
  -> Timer::immediate() (no sleep)
  -> callback fires: redraw(estimated_presentation)
  -> queue_frame(ok)
  -> state = WaitingForVBlank { redraw_needed }
  -> on_vblank()
  -> animations_going()? or redraw_needed?
  -> queue_redraw(false)
  -> Timer::immediate() again
  -> LOOP WITH ZERO SLEEP
```

## Fix Applied

**File:** `~/repos/cosmic-comp/src/backend/kms/surface/timings.rs`

Changed the NVIDIA branch from `Duration::ZERO` to use the same fallback as GPUs without enough frame history:

```rust
// Before (busy-loop):
if self.vendor == Some(0x10de) {
    return Duration::ZERO;
}

// After (sleeps until near VBlank):
if self.vendor == Some(0x10de) {
    return estimated_presentation_time.saturating_sub(baseline + BASE_SAFETY_MARGIN);
}
```

`baseline` = max(3ms, refresh_interval/2), `BASE_SAFETY_MARGIN` = 3ms. The surface thread now sleeps ~10ms per frame at 60Hz instead of 0ms.

## Additional Fixes Applied

### Per-Output Animation Scheduling

**Files:** `~/repos/cosmic-comp/src/lib.rs`, `~/repos/cosmic-comp/src/shell/mod.rs`

The main event loop called `animations_going()` globally and scheduled renders for ALL outputs if any animation existed. Changed to per-output: `animations_going_for_output(&output)` checks only the workspace set for that specific output.

### Process Priority (PAM Limits)

Created `/etc/security/limits.d/99-compositor-nice.conf`:
```
martinkavik  -  nice  -10
```

The existing nice elevation calls in the compositor code were silently failing because `RLIMIT_NICE=0` on the session scope. After relogin, the limit changes to `-10`, allowing the priority calls to succeed. Target nice bumped from -5 to -10 (v2 deploy) for better responsiveness under heavy system load.

**v2 update (2026-03-02):** After deploy, compositor ran at nice -3 (not -5). Root cause unclear — possibly COSMIC session manager overrides. Changed target to -10 and added `warn!()` level logging for priority elevation success/failure to diagnose. Also changed all perf logging from `info!()` to `warn!()` since cosmic-comp filters `info` by default.

### Commit Filter Overhead

Changed `COSMIC_DEBUG_COMMIT_FILTER` default from `true` to `false`. The per-commit diagnostic counters add overhead to every Wayland surface commit with no benefit in production.

## Built-in Performance Logging

Always-on logging added (no env vars needed). Every 60 seconds, each surface thread and the main loop log performance stats:

**Surface thread:**
```
[perf] surface thread stats (60s interval)
  output=DP-1 frames=3600 fps=60.0 immediate_timers=0
  animations_true=0 screencopy_skips=0 overload_transitions=0
  render_requests=3600 render_coalesced=1200
```

**Main loop:**
```
[perf] main loop stats (60s interval)
  loop_iterations=12000 loops_per_sec=200.0
  anim_schedule_renders=0
```

### What to Look For If Lag Returns

- `immediate_timers > 0` -- NVIDIA timing fix regressed
- `animations_true` growing steadily -- something keeping animations alive
- `screencopy_skips` high -- CPU still overloaded
- `fps` much higher than refresh rate -- busy-loop still happening
- `loops_per_sec` extremely high (>10000) -- main loop busy-spinning

## Expected Impact

- CPU usage: 80% -> <15% (surface threads sleep ~10ms between frames instead of 0ms)
- GPU: remains P8/low power (no change, work was always CPU-bound)
- Context switches: dramatic reduction (no more busy-polling)
- Frame timing: should improve (timer-based scheduling vs hot-loop)

## Verification

```bash
# CPU should be <15% idle
top -bn5 -d1 -p $(pgrep cosmic-comp) | grep cosmic-comp

# Per-thread -- surface threads should be <5% each
ps -p $(pgrep -x cosmic-comp) -T -o spid,pcpu,comm --sort=-pcpu

# Check perf logs
journalctl --user -u cosmic-comp --since "5 min ago" | grep perf
```

Long-duration test: use normally 8+ hours with suspend/resume. Perf logs will capture any regression.

---

## v2 Fixes (2026-03-02) — Main Loop Write Lock Throttling

### Problem: Main Thread at 38% CPU, Growing Over Time

After the NVIDIA timing fix reduced total CPU from 80% to 30%, the remaining CPU was **95% on the main thread**. The main thread processes Wayland client events at ~444 dispatches/sec. Each dispatch called:

1. `shell.write().update_animations()` — acquires **write lock** (blocks all surface thread renders)
2. `refresh(state)` — layout work (throttled to 150ms, usually a no-op)
3. `shell.read().animations_going_for_output()` — acquires read lock per output

The write lock at 444 Hz caused severe contention with surface threads trying to read the shell during rendering.

### Fix: Throttle Expensive Operations to 60 Hz

**File:** `~/repos/cosmic-comp/src/lib.rs`

Wrapped `update_animations()`, `refresh()`, and `animations_going_for_output()` in a 16ms throttle:

```rust
let now = Instant::now();
if now.duration_since(last_animation_update) >= Duration::from_millis(16) {
    last_animation_update = now;
    // ... expensive shell operations here
}
```

Write lock acquired 60x/sec instead of 444x/sec — **7x less lock contention**.

### Additional v2 Changes

- **Nice target -10** (was -5 which silently failed → actually ran at -3)
- **Priority elevation logs at `warn!()` level** — will show success/failure in journalctl
- **All perf logging at `warn!()` level** — `info!()` was filtered by cosmic-comp's default log level

### Pre-Reboot Measurements (2026-03-02 22:04 CET, 21h uptime)

```
Main thread CPU ticks: 2,773,484 (95% of total)
Surface HDMI ticks:       92,095 (3.1%)
Surface DP ticks:         62,769 (2.1%)
RSS:            400 MB (grew from 320 MB over ~8h)
FDs:            331 (71 deleted)
Ctx switches:   9.3M voluntary, 1.2M involuntary
GPU:            P5/810MHz/3% utilization/2578 MiB VRAM
Load:           1.46 (8 cores)
RAM:            13 GB used, 24 GB free, 0 swap
```

---

## v2 System Configuration Applied

### GPU Clock Lock (prevents P8/420MHz idle state)

NVIDIA may drop to P8/420MHz between frames, causing slow GPU rendering when it doesn't clock back up fast enough.

**One-time (until reboot):**
```bash
sudo nvidia-smi -pm 1                 # Enable persistence mode
sudo nvidia-smi -lgc 800,1440         # Lock GPU clocks: min 800 MHz, max 1440 MHz
```

**Persistent (survives reboot) — systemd service:**
```bash
sudo tee /etc/systemd/system/nvidia-gpu-clock.service << 'EOF'
[Unit]
Description=Lock NVIDIA GPU clocks for compositor responsiveness
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStart=/usr/bin/nvidia-smi -lgc 800,1440
RemainAfterExit=yes
ExecStop=/usr/bin/nvidia-smi -rgc

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nvidia-gpu-clock.service
```

**To verify:**
```bash
nvidia-smi --query-gpu=pstate,clocks.gr --format=csv,noheader
# Should show P5 or higher, 810+ MHz (not P8/420 MHz)
```

**To remove:**
```bash
sudo systemctl disable nvidia-gpu-clock.service
sudo rm /etc/systemd/system/nvidia-gpu-clock.service
sudo nvidia-smi -rgc   # Reset GPU clocks to default
```

### PAM Nice Limits

**File:** `/etc/security/limits.d/99-compositor-nice.conf`
```
martinkavik  -  nice  -10
```

Allows compositor to set nice to -10. Requires relogin to take effect.

### All System Config Files

| File | Purpose | Survives reboot? |
|------|---------|-----------------|
| `/etc/security/limits.d/99-compositor-nice.conf` | Allow compositor nice -10 | Yes |
| `/etc/systemd/system/nvidia-gpu-clock.service` | Lock GPU min clock to 800 MHz | Yes (after `systemctl enable`) |
| `/etc/systemd/system/disable-usb1-port6.service` | Legacy boot-time USB port disable service; now intentionally disabled because `usb 1-6` hosts the Superlux L401U mic/headset | No |
| `/lib/systemd/system-sleep/20-disable-usb1-port6` | Disable `usb 1-6` only during suspend entry, then re-enable on resume | Yes (from suspend fix) |
| `/etc/systemd/sleep.conf.d/10-force-deep.conf` | Force deep sleep mode | Yes (from suspend fix) |

---

## v3 Fixes (2026-03-03) — Commit Handler Write Lock Downgrade

### Problem: FPS Degrades Over Hours (Write-Lock Starvation)

After 14+ hours of uptime, DP-1 dropped from 45fps to 2.4fps. HDMI degraded from 17 to 9fps. Main thread used 50% CPU even with zero user input (1748 wakeups/sec from idle Wayland clients).

**Root cause:** The `commit()` handler in `src/wayland/handlers/compositor.rs` took a **WRITE lock** on the shell for **every** Wayland surface commit (~1748/sec). The lock held `visible_output_for_surface()` (read-only O(N) search) and `schedule_render()` (just sends a channel message). Since `parking_lot::RwLock` is write-preferring, surface render threads needing READ locks got starved — they woke up but couldn't acquire the lock. As internal state grew over hours, each commit got slower (0.5ms → 5.5ms), compounding the starvation.

Previous fixes (v1 NVIDIA timing, v2 main loop 60Hz throttle + per-output animations) are still in place. This is the next bottleneck.

### Fix: Split into READ fast path + WRITE slow path

**File:** `src/wayland/handlers/compositor.rs` — `commit()`

| Path | Lock type | When | Frequency |
|------|-----------|------|-----------|
| Fast path | READ | `visible_output_for_surface()` + `schedule_render()` + diagnostics | ~1748/sec (every commit) |
| Early return | None | `mapped` commits, popup commits | Common |
| Slow path | WRITE | null-buffer handling, resize grabs, layer surface rearrangement | ~60-70/sec |

The key change: `shell.write()` → `shell.read()` for the common path, with `.cloned()` on the output reference. The write lock is only taken when actual mutations are needed (null-buffer handling, resize grabs, layer surface arrangement).

### New Diagnostics

**File:** `src/wayland/handlers/compositor.rs` — new counters:
- `COMMIT_WRITE_COUNT` — commits that actually take the write lock
- `COMMIT_WRITE_NANOS` — total time in write lock

**File:** `src/lib.rs` — logged in main loop perf output (every 60s):
- `write_commits` — write lock frequency (should be << `commits`)
- `write_lock_ms` — total write lock duration

### What to Look For

- `write_commits` should be << `commits` (most commits use read lock only)
- FPS should stay stable over hours (no degradation)
- Main thread CPU should be lower (read locks don't contend with render threads)

### How to Rebuild and Deploy cosmic-comp

```bash
cd ~/repos/cosmic-comp
cargo build --release
sudo cp target/release/cosmic-comp /usr/bin/cosmic-comp.new
sudo mv /usr/bin/cosmic-comp.new /usr/bin/cosmic-comp
# Reboot or restart COSMIC session
```
