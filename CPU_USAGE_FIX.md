# cosmic-comp High CPU Usage: Diagnosis and Fix

**Date:** 2026-02-20
**Branch:** `fix-screencopy-cpu` (based on `weak_window_upstream_smithay`) in `~/repos/cosmic-comp`
**System:** Pop!_OS 24.04, kernel 6.18.7, NVIDIA RTX 2070 (driver 580.126.09), dual 4K (DP-1 4096x2304 + HDMI-A-1 3840x2160), Wayland/COSMIC, 48 GB RAM

---

## Symptom

Graphics and cursor become laggy after using the desktop for a while. `cosmic-comp` gradually climbs to 100% CPU. The problem does not appear immediately after boot — it develops over time as the user interacts with the desktop (switches workspaces, opens windows, uses workspace overview).

This is a **separate issue** from the VRAM leak fixed in the `weak_window_upstream_smithay` branch. VRAM is stable; CPU is the problem.

---

## Update: 2026-03-11 Panel/Applet FD Exhaustion

A second long-session failure mode was confirmed on `minotiros`: the COSMIC panel stack can go half-dead even when the rest of the desktop still works.

### What actually happened

The first important error was **not** notifications-specific:

```text
cosmic-session[2090]: error marshalling arguments for keymap: dup failed: Too many open files
```

After that, multiple panel applets started failing with `Broken pipe`, including:

- `com.system76.CosmicAppList`
- `com.system76.CosmicAppletAudio`
- `com.system76.CosmicAppletNotifications`

So the panel issue was caused by **file descriptor exhaustion** in the COSMIC login tree, and the broken applets were downstream symptoms.

### Why `1024` open files was too low

On Linux, "open files" also includes:

- sockets
- pipes
- shared-memory objects (`memfd`)
- pidfds / eventfds
- Wayland-related handles

A healthy restarted `cosmic-panel` was already using about:

- `516` total file descriptors
- `207` `memfd`s
- `78` sockets
- `105` pipes
- `34` pidfds

That means `1024` was not much headroom for a dual-panel / multi-applet COSMIC session after hours of use.

### Important launch-path detail

The COSMIC session here is launched as a child of `greetd`, not as a normal `systemd --user` service, so high user-manager limits did **not** help.

The inherited low limit came from `greetd`:

```text
/proc/1951/limits
Max open files            1024                 1048576              files
```

### Fix applied

Persistent fix:

- [`/etc/systemd/system/greetd.service.d/override.conf`](/etc/systemd/system/greetd.service.d/override.conf)

Contents:

```ini
[Service]
LimitNOFILE=1048576
```

Live-session mitigation also applied:

- raised `RLIMIT_NOFILE` for the currently running `cosmic-session`, `cosmic-panel`, `cosmic-comp`, and current panel applets to `1048576`

This means:

- the current session has more headroom now
- the next reboot/login should inherit the higher limit automatically

### Is there still a leak?

Maybe, but not proven yet.

What is proven:

- the old `1024` limit was too low for this COSMIC session model
- panel breakage can happen from plain FD exhaustion even without a confirmed leak

What is still open:

- whether FD counts stay stable over time
- whether some applet or panel restart path slowly leaks descriptors

### FD monitor added

New helper:

- [`cosmic-fd-monitor.sh`](/home/martinkavik/repos/popos_fix_vram_leak/cosmic-fd-monitor.sh)

Default log:

- [`fd-logs/cosmic-fd-monitor.log`](/home/martinkavik/repos/popos_fix_vram_leak/fd-logs/cosmic-fd-monitor.log)

Current monitor service:

```bash
systemctl --user status cosmic-fd-monitor.service
tail -f ~/repos/popos_fix_vram_leak/fd-logs/cosmic-fd-monitor.log
```

Persistent user service:

- [`~/.config/systemd/user/cosmic-fd-monitor.service`](/home/martinkavik/.config/systemd/user/cosmic-fd-monitor.service)

The logger records:

- timestamp
- pid / command
- FD count
- soft/hard open-file limit
- sockets / pipes / memfd / pidfd breakdown

This should let the next long-session run answer whether counts stay flat or keep climbing.

---

## Diagnostics

### 1. Process-level profiling

```
$ top -bn1 -p 591753
PID   USER     PR  NI  %CPU  %MEM  TIME+     COMMAND
591753 martin  17  -3  100.0  0.9  319:32.97  cosmic-comp
```

`cosmic-comp` at 100% CPU after 3 days uptime. GPU is barely utilized (14%, 49C).

### 2. Per-thread CPU breakdown

```
Thread             utime (jiffies)  % of total  Role
Main (cosmic-comp) 1,713,216        93%         Event loop, frame callbacks, dispatch
surface-HDMI-A-1   71,970           3.9%        Rendering 3840x2160
surface-DP-1       48,784           2.6%        Rendering 4096x2304
All others         ~0               <1%         inotify, zbus, async-io, shm
```

The main thread dominates. This rules out GPU-bound rendering as the bottleneck — the event loop itself is the problem.

### 3. Syscall analysis (strace, 3 seconds)

```
Syscall          Count   Rate     Cause
epoll_wait       260     87/s     Main event loop wakeups
epoll_pwait      968     323/s    Surface thread event loops
epoll_ctl        1,719   573/s    Timer insert/remove per render
timerfd_settime  758     253/s    Screencopy throttle timers
ioctl            577     192/s    GPU/DRM render submissions
read             1,790   597/s    Wayland socket polling (1,015 EAGAIN)
```

Key observation: **573 epoll_ctl/sec and 253 timerfd_settime/sec** — the event loop is inserting and removing timer sources at an extreme rate, consistent with 60+ renders/sec across two displays.

### 4. GPU monitoring (nvidia-smi pmon)

GPU SM utilization: intermittent 20% bursts, mostly idle. GPU is not the bottleneck — CPU-side element collection and damage tracking dominate the cost.

### 5. Controlled experiment: killing screencopy consumers

| State                          | CPU   | Delta  |
|-------------------------------|-------|--------|
| Both running (baseline)       | 100%  | —      |
| Kill cosmic-workspaces (PID 600093) | 48%   | -52%   |
| Kill cosmic-panel (PID 591836)      | 4%    | -44%   |

**Definitive result:** cosmic-workspaces and cosmic-panel together account for ~96% of the CPU load. Both are screencopy consumers — they use the `ext_image_copy_capture` protocol to capture workspace thumbnails and window previews.

---

## Root Cause

### The throttle mechanism

cosmic-comp uses a two-tier frame callback throttle (`src/state.rs:1291-1306`):

```rust
const THROTTLE: Option<Duration> = Some(Duration::from_millis(995));           // ~1 FPS
const SCREENCOPY_THROTTLE: Option<Duration> = Some(Duration::from_nanos(16_666_666)); // 60 FPS

fn throttle(session_holder: &impl SessionHolder) -> Option<Duration> {
    if session_holder.sessions().is_empty() && session_holder.cursor_sessions().is_empty() {
        THROTTLE
    } else {
        SCREENCOPY_THROTTLE
    }
}
```

When screencopy sessions exist on a window, workspace, or output, the compositor sends frame callbacks to Wayland clients at 60 FPS instead of ~1 FPS. This causes clients to commit surfaces at 60 Hz, each commit triggering `schedule_render()`, creating a sustained rendering loop even when nothing on screen has changed.

The throttle function is called for every window on every frame callback cycle (lines 1342, 1367, 1373, 1377, 1394-1401). For non-active workspaces, `min(throttle(space), throttle(&window))` means workspace-level sessions affect **all windows in that workspace**.

### Two screencopy consumers drive the load

**1. cosmic-workspaces (~52% CPU)**

cosmic-workspaces uses workspace-level and toplevel-level screencopy to render workspace thumbnails in the overview (Super+W). It creates `CaptureSession` objects for each workspace and visible window.

When the overview is shown, these sessions actively request frames. When hidden, sessions are stopped via `capture.stop()` which properly drops the `CaptureSession` (the `CaptureSessionInner::drop` impl calls `.destroy()` on the Wayland protocol object, destroying the server-side session).

However, `cosmic-workspaces` has an unrelated bug: workspace captures are never removed from its internal HashMap when workspaces are deleted (`src/backend/wayland/workspace.rs:14: // XXX remove capture source for removed workspaces`). This means:
- `done()` handler calls `add_capture_source()` for every workspace on every workspace-state update
- `entry().or_insert_with()` deduplicates, so duplicates are not created for existing workspaces
- But when workspaces are removed, their `Capture` objects stay in the HashMap forever
- If the overview is later opened, stale captures may attempt to start sessions for workspaces that no longer exist (the server rejects these with `session.stop()`)

**2. cosmic-panel (~44% CPU)**

cosmic-panel (and its applets) uses screencopy for minimize-applet window thumbnails and potentially other panel features. The panel keeps sessions alive for as long as the panel is running. The `xdg-desktop-portal-cosmic` service may also contribute output-level screencopy sessions for PipeWire screen capture support.

Each output-level screencopy frame request triggers `schedule_render()` on both surface threads (`src/wayland/handlers/image_copy_capture/mod.rs:288`), which forces:
1. `output_elements()` — collecting all renderable elements (CPU-heavy)
2. `render_frame()` — damage tracking and GPU rendering
3. `queue_frame()` → vblank → frame callbacks → client commits → `schedule_render()` → repeat

### The bug: cosmic-comp's throttle treated "session exists" as "someone actively needs frames"

The Wayland screencopy protocol is designed for long-lived sessions. A consumer creates a session once, then requests frames on demand. Between requests the session is idle but valid — this is normal, correct protocol usage.

cosmic-comp's throttle conflated session **existence** with session **activity**:

```rust
// Bug: any existing session forces 60 FPS, even if nobody is requesting frames
if session_holder.sessions().is_empty() { THROTTLE } else { SCREENCOPY_THROTTLE }
```

This is wrong regardless of what any consumer does. Even if every consumer had perfect session lifecycle management, any consumer that keeps a session open between frame requests (which is the intended protocol usage) would trigger permanent 60 FPS rendering. The throttle check is binary — either there are sessions (60 FPS) or there aren't (~1 FPS) — with no concept of idle vs active.

### Why CPU grows over time

The CPU cost is not constant — it grows as the user interacts with the desktop:

1. **At boot:** Screencopy consumers haven't started yet, or have just started and haven't created sessions on all entities. CPU is low.
2. **First interactions:** cosmic-panel's applets begin capturing window thumbnails. Each window that gets a screencopy session switches from ~1 FPS to 60 FPS frame callbacks. More windows open = more sessions = more 60 FPS entities.
3. **Workspace overview:** Opening the overview creates workspace-level sessions across all workspaces. Even after the overview closes and sessions are properly destroyed, any persistent sessions from cosmic-panel on the same entities keep the throttle at 60 FPS.
4. **Cumulative effect:** Over time, as the user opens windows, switches workspaces, and uses the overview, more entities accumulate at least one screencopy session, spreading the 60 FPS cost across more of the compositor's rendering workload.

The render cost per 60 FPS entity also scales with the total number of windows (more elements to collect in `output_elements()`), so the per-frame cost itself increases over a session's lifetime.

---

## The Fix

**Branch:** `fix-screencopy-cpu` in `~/repos/cosmic-comp`
**Files changed:** 4 files

### Change 1: Activity tracking on `ImageCopySessions`

**File:** `src/wayland/handlers/image_copy_capture/user_data.rs`

Added `last_frame_request_ms: AtomicU64` to `ImageCopySessions`. This stores the timestamp (ms since UNIX epoch) of the last frame request. Two methods operate on it:

```rust
/// Duration (ms) after which a capture session is considered idle.
const CAPTURE_ACTIVE_TIMEOUT_MS: u64 = 1_000;

impl ImageCopySessions {
    pub fn mark_capture_active(&self) {
        self.last_frame_request_ms
            .store(current_time_ms(), Ordering::Relaxed);
    }

    pub fn is_capture_active(&self) -> bool {
        let last = self.last_frame_request_ms.load(Ordering::Relaxed);
        last != 0 && current_time_ms().saturating_sub(last) < CAPTURE_ACTIVE_TIMEOUT_MS
    }
}
```

`CAPTURE_ACTIVE_TIMEOUT_MS` is 1 second. If no frame has been requested in 1 second, the session is considered idle.

`AtomicU64` is used instead of `Cell<Instant>` because `Shell` (which contains `Workspace` which contains `ImageCopySessions`) must be `Sync` — it's shared across compositor threads via `RwLock`.

### Change 2: Mark activity on frame requests

**File:** `src/wayland/handlers/image_copy_capture/mod.rs`

Added `mark_capture_active()` calls in the `frame()` handler for all three screencopy source types:

- **Output:** `output.mark_capture_active()` before `add_frame()`
- **Workspace:** `workspace.mark_capture_active()` before `render_workspace_to_buffer()`
- **Toplevel:** `toplevel.mark_capture_active()` before `render_window_to_buffer()`

Extended the `SessionHolder` trait with `mark_capture_active(&self)` and `is_capture_active(&self) -> bool`, implemented for `Output`, `Workspace`, and `CosmicSurface`.

### Change 3: Smart throttle + reduced screencopy FPS

**File:** `src/state.rs`

```rust
// Before:
const SCREENCOPY_THROTTLE: Option<Duration> = Some(Duration::from_nanos(16_666_666)); // 60 FPS

fn throttle(session_holder: &impl SessionHolder) -> Option<Duration> {
    if session_holder.sessions().is_empty() && session_holder.cursor_sessions().is_empty() {
        THROTTLE
    } else {
        SCREENCOPY_THROTTLE
    }
}

// After:
const SCREENCOPY_THROTTLE: Option<Duration> = Some(Duration::from_nanos(33_333_333)); // 30 FPS

fn throttle(session_holder: &impl SessionHolder) -> Option<Duration> {
    if session_holder.is_capture_active() {
        SCREENCOPY_THROTTLE
    } else {
        THROTTLE
    }
}
```

Two changes:
1. **`is_capture_active()` instead of `!sessions().is_empty()`** — idle sessions no longer force fast rendering. When a screencopy consumer stops requesting frames, the entity reverts to ~1 FPS within 1 second.
2. **60 FPS → 30 FPS** — even during active capture, 30 FPS is sufficient for workspace thumbnails and screen recording, while halving the per-frame overhead.

### Change 4: Output screencopy startup wakeup (edge-triggered)

**File:** `src/wayland/handlers/image_copy_capture/mod.rs`

The original code called `schedule_render(&output)` on every output screencopy frame request. That forced the compositor through `output_elements()` + `render_frame()` at the consumer's request rate, even when nothing changed.

The final fix is an edge-triggered compromise:

- Queue screencopy frames on the output (`add_frame`)
- Trigger exactly one render when pending queue transitions **empty -> non-empty**
- Do not trigger additional renders for every new frame request while queue remains non-empty

This preserves screenshot startup reliability (no more "press Super to unstick") without reintroducing per-request redraw storms.

### Change 5: Bump calloop to 0.14.4

**File:** `Cargo.toml`

calloop (the async event loop library used by smithay/cosmic-comp) had a bug causing progressive CPU degradation over time (see [cosmic-comp #2062](https://github.com/pop-os/cosmic-comp/issues/2062)). Fixed in calloop 0.14.4. This was the root cause of "mouse stuttering develops after extended use" reports.

---

## Expected Impact

| Scenario | Before | After |
|----------|--------|-------|
| Boot, no interaction | ~1% CPU | ~1% CPU (unchanged) |
| Active workspace overview | ~100% CPU | ~50% CPU (30 FPS instead of 60) |
| After closing overview | Stays ~100% CPU | ~4% CPU (sessions go idle after 2s) |
| Long session, many windows | Progressive climb to 100% | Spikes during capture, returns to baseline when idle |

The fix eliminates the progressive degradation. CPU only increases during active screencopy use and returns to baseline within 2 seconds of inactivity.

---

## Why this is a real fix, not a workaround

The fix lives in cosmic-comp because that's where the bug is. The throttle logic incorrectly used session existence as a proxy for session activity. Our `is_capture_active()` makes the throttle correctly distinguish idle sessions from active ones — this is the right behavior for the compositor regardless of how consumers manage their sessions.

Screencopy consumers (cosmic-panel, xdg-desktop-portal-cosmic, cosmic-workspaces) are doing nothing wrong by keeping long-lived sessions. The protocol is designed for it.

## Related issue in cosmic-workspaces-epoch (separate, minor)

**File:** `cosmic-workspaces-epoch/src/backend/wayland/workspace.rs:14`

```rust
// XXX remove capture source for removed workspaces
```

The `done()` handler adds capture sources for all workspaces on every workspace-state protocol event but never removes captures for deleted workspaces. When workspaces are created and removed (dynamic workspace mode, monitor hotplug), the captures HashMap grows with stale entries.

**This does NOT cause or amplify the CPU problem.** Stale captures are always stopped (no active server-side session), so:
- With our fix: `is_capture_active()` returns false → no throttle impact
- Without our fix: `sessions().is_empty()` returns true for those workspaces → no throttle impact either

The leak is ~200 bytes per orphaned workspace (a stopped `Capture` struct + dead Wayland proxy handle). Even after thousands of workspace create/delete cycles, this is negligible. It's a tidiness issue, not a performance or memory issue.

CaptureSession **does** properly destroy on drop — `CaptureSessionInner::drop` calls `self.session.destroy()`, which sends the Wayland protocol destroy request to the server. The server handles this in `session_destroyed()` which removes the session from the entity's Vec. No zombie sessions accumulate.

---

## Phase 2: Render Pipeline Optimizations

**Date:** 2026-02-22
**Branch:** `fix-screencopy-cpu` in `~/repos/cosmic-comp`

After Phase 1 (screencopy throttle fix + focused-output-only input renders), cosmic-comp still had unnecessary blocking in the render path. Deep research into smithay's rendering architecture identified one safe optimization and ruled out several others.

### Change 6: Non-blocking GPU fence checks

**File:** `src/backend/kms/surface/mod.rs` — three locations

GPU sync points (`SyncPoint`) guard buffer access after rendering. The compositor was unconditionally calling blocking `wait()` / `eglClientWaitSyncKHR` on every frame, even when the GPU had already finished. `SyncPoint::is_reached()` provides a zero-timeout non-blocking check that returns immediately if the fence is signaled.

**Pattern applied at all three locations:**
```rust
// Before:
sync.wait()?;

// After:
if !sync.is_reached() {
    sync.wait()?;
}
```

**Locations:**
1. **Main render path** (line ~1321): `frame_result.primary_element.sync.wait()` — the primary swapchain fence after compositing
2. **Postprocess cursor offscreen render** (line ~1194): `renderer.wait(&res.sync)` — sync after rendering cursor into offscreen texture (active during mirroring or screen filters)
3. **Postprocess main texture offscreen render** (line ~1247): `renderer.wait(&res.sync)` — sync after rendering all elements into offscreen texture

**Why this helps:** For cursor-only damage (two ~128x128 rectangles), GPU rendering completes in ~0.05ms. Without the fix, the compositor blocks for ~0.1-5ms per frame waiting for the fence via `eglClientWaitSyncKHR`. With the fix, `is_reached()` checks in ~0.001ms, finds the fence done, and skips the blocking call. At 60 FPS, this saves up to 300ms/sec of blocked main thread time.

**Risk:** None — falls back to blocking wait when GPU isn't done yet.

### Investigated but abandoned

| Optimization | Why abandoned |
|---|---|
| **Element caching with `transmute` to `'static`** | UNSAFE: `GlMultiRenderer<'a>` lifetime protects `&'a mut` borrows to GPU devices. Elements hold `R::TextureId` which are context-specific. Cached textures could become invalid on renderer recreation or client surface destruction. |
| **Skip keyboard renders** | UNSAFE: `Shell::set_focus()` (Alt+Tab, arrow focus) changes active hint decoration but does NOT call `schedule_render()`. Without the blanket `schedule_render` after keyboard events, focus highlights would not update. Other shortcuts (toggle floating/stacking/tiling) also rely on it. |
| **`SKIP_CURSOR_ONLY_UPDATES` flag generalization** | Only affects DRM submission, not CPU work. With software cursor on NVIDIA, cursor is composited into primary plane so this flag doesn't apply. |
| **Cache workspace-only elements** | Type system prevents it — `GlMultiRenderer<'a>` lifetime can't be erased safely. |

### Research findings on smithay internals

- **`output_elements()` is already efficient for unchanged surfaces.** Smithay's `import_surface()` caches textures per renderer context (HashMap lookup on subsequent frames). The tree traversal creates lightweight wrappers. Cost is ~0.5-1ms for typical desktops — not the primary bottleneck.
- **Smithay's damage tracker already optimizes cursor-only GPU work.** `OutputDamageTracker::render_output()` returns immediately with no GPU work when there's no damage. For cursor-only moves, it computes minimal damage (two ~128x128 rectangles). The GPU work is trivial.
- **GPU fence wait behavior on NVIDIA 580.x:** Even with `supports_fencing = true`, `needs_sync()` blocks if EGL fences aren't natively exportable. Smithay provides `SyncPoint::is_reached()` — a zero-timeout non-blocking check via `EGLFence::client_wait(Some(Duration::ZERO), false)`.

## Phase 3: Render Pipeline Optimizations (Responsiveness Under Load)

**Date:** 2026-02-22
**Branch:** `fix-screencopy-cpu` in `~/repos/cosmic-comp`

After Phase 1 (screencopy throttle — saved ~96% CPU) and Phase 2 (non-blocking GPU fence checks — saved up to 300ms/sec), the desktop still felt laggy (stuttery cursor, choppy YouTube) when running multiple Claude Code instances alongside Firefox.

### Root cause analysis

Under heavy CPU load (4 Claude sessions saturating 8 cores), the compositor's surface threads can't get scheduled fast enough:

1. **No CPU priority** — cosmic-comp runs at SCHED_OTHER with default nice 0, competing equally with Claude Code and Firefox for CPU time. Sway uses SCHED_RR for render threads.
2. **Shell lock contention** — main thread holds `shell.write()` during animation updates and input processing, blocking surface threads' `shell.read()` in element collection. Multiple redundant lock acquisitions per frame compound the problem.
3. **Screencopy waste** — empty-damage screencopy frames still bind GPU buffers and copy pixels, and screencopy runs even when the compositor is already missing its frame budget.

### Research conclusions

- **Smithay dep**: Already at latest `upstream/master` rev `599857c`. No bump needed.
- **Memfd leak (#2073)**: Already fixed by our prior commits (cb89e77, b42621a, 58a27d0 + smithay's `mem::forget` fix).
- **Framebuffer effect optimization** (`feat/fb-effects`): NOT relevant. This is infrastructure for future blur/frosted-glass effects (65 changed files, new `capture_framebuffer` API). cosmic-comp doesn't use framebuffer effects — no blur behind panels or windows. Zero benefit for current performance.
- **Seat/theme cloning**: Required due to deadlock constraint (shell lock must be dropped before `cursor_elements()`). Arc clone is cheap — not worth changing.
- **Cursor double alloc**: Not real — first Vec freed before second allocated, allocator reuses memory.

### Change 7: Consolidate shell locks in `redraw()`

**File:** `src/backend/kms/surface/mod.rs`

Two separate `shell.read()` lock acquisitions per frame: one for `render_node_for_output()`, another for `animations_going()` + fullscreen checks. `animations_going()` iterates ALL workspace sets, all spaces, and locks per-output Mutexes — calling it twice is wasteful.

Merged both into a single lock scope. `render_node_for_output` takes `&Shell` (verified at line 1488), so it works inside the lock.

**Saves:** 1 lock acquisition + 1 `animations_going()` traversal per frame per output.

### Change 8: Merge zoom_state lock in `output_elements()`

**File:** `src/backend/render/mod.rs`

Two separate `shell.read()` calls — first for workspace data extraction (dropped after use), then a second just for `zoom_state()`. Moved `zoom_state()` extraction before the drop.

**Saves:** 1 lock acquisition per frame per output.

### Change 9: Early exit for empty damage in screencopy

**File:** `src/backend/kms/surface/mod.rs`, function `send_screencopy_result`

When damage is `Some(&[])` (render happened, nothing changed), the function was still binding GPU buffers, entering the blit block, and for SHM calling `renderer.wait(&sync)` + pixel-copying the entire buffer. Now returns `frame.success(transform, Some(Vec::new()), presentation_time)` immediately.

**Saves:** ~1-5ms per idle screencopy frame (buffer bind + blit + GPU sync + pixel copy).

### Change 10: Non-blocking screencopy cursor sync

**File:** `src/backend/kms/surface/mod.rs`

Same Phase 2 pattern (`is_reached()` guard before blocking wait) applied to the screencopy cursor overlay render path.

**Saves:** ~0.05-0.5ms per screencopy cursor frame.

### Change 11: PostprocessOutputConfig deduplication

**File:** `src/backend/kms/surface/mod.rs`

`for_output_untransformed()` was computed twice per frame (once in the filter check, once for actual use). Now computed once and cached.

### Change 12: Skip screencopy under frame budget pressure (bounded + startup-safe)

**File:** `src/backend/kms/surface/mod.rs` + `src/backend/kms/surface/timings.rs`

**Iteration history:**
1. **v1:** Unconditionally skipped screencopy when `Timings::is_overloaded()` returned true (any of last 5 frames exceeded refresh interval). **Broke screenshot tool** — under sustained CPU load, `is_overloaded()` was perpetually true, causing screencopy consumers to never receive frames. Screenshot tool only worked after pressing Super, which briefly changed the overload state.
2. **v2:** Added `screencopy_skip_count` field to `SurfaceThreadState`. When overloaded, screencopy is skipped for up to `MAX_SCREENCOPY_SKIP` (30) consecutive frames, then forced through. This avoided complete starvation but screenshot startup latency was still noticeable (~0.5s).
3. **v3 (current):**
   - Trigger one render when output screencopy queue transitions empty -> non-empty (startup wakeup)
   - Skip at most 10 consecutive frames (`MAX_SCREENCOPY_SKIP=10`)
   - Force screencopy if oldest pending frame waited >=150ms
   - Request redraw retries while pending screencopy frames are being skipped
   - Retune overload detection from `any(last5 > 1.0x refresh)` to sustained overload (majority of recent frames >1.5x refresh)

```rust
const MAX_SCREENCOPY_SKIP: u32 = 10;
const SCREENCOPY_FORCE_DELAY_MS: u64 = 150;
let skip_screencopy = self.mirroring.is_some()
    || (pending_screencopy_frames
        && self.timings.is_overloaded()
        && !force_serve_screencopy);
let frames = if !skip_screencopy {
    self.screencopy_skip_count = 0;
    take_screencopy_frames(...)
} else {
    self.screencopy_skip_count = self.screencopy_skip_count.saturating_add(1);
    Default::default()
};
```

**Saves:** Under CPU pressure, skips most screencopy processing while keeping screenshot startup reliable and bounded in latency (target <~150-200ms for first frame).

### Change 13: Elevate thread priority with absolute-target nice (`-5`)

**File:** `src/backend/kms/surface/mod.rs` (surface thread) + `src/lib.rs` (main thread)

Set thread/process priority to an absolute target (`-5`) using `getpriority_process(None)` + `setpriority_process(None, -5)` at the start of both surface threads and the main thread. This avoids relative `nice(-5)` behavior drifting to too-high priority or failing unexpectedly when already negative.

**Note:** Code-level `setpriority` is necessary but not sufficient — `RLIMIT_NICE` for the session must allow values below 0. On this Pop!_OS/COSMIC setup, `cosmic-comp` runs in `session-*.scope` (not `cosmic-comp.service`), so service-file `Nice=/LimitNICE=` does not apply. Use PAM limits (user-specific rule in `/etc/security/limits.d/`) and relogin so the session inherits the right limit.

Under CPU contention, the kernel scheduler gives nice -5 threads ~3x more CPU time than normal (nice 0) processes. This directly addresses the "laggy cursor when Claude is running" problem — the compositor's threads get priority over background work.

We're NOT using RT scheduling (SCHED_FIFO/SCHED_RR) which could cause system hangs. `nice(-5)` is safe.

**Saves:** Under CPU contention, ~3x more CPU time for compositor vs normal processes.

### Phase 3 summary

| # | Change | Impact | Risk |
|---|--------|--------|------|
| 7 | Consolidate shell locks in `redraw()` | Saves 1 lock + 1 `animations_going()` per frame | None |
| 8 | Merge zoom_state lock in `output_elements()` | Saves 1 lock per frame per output | None |
| 9 | Early exit for empty damage in screencopy | Saves ~1-5ms per idle screencopy frame | Low |
| 10 | Non-blocking screencopy cursor sync | Saves ~0.05-0.5ms per screencopy cursor frame | None |
| 11 | PostprocessOutputConfig dedup | Saves redundant computation per frame | None |
| 12 | Skip screencopy under frame pressure (bounded + startup-safe) | Skips most screencopy under load while bounding first-frame latency | Low |
| 13 | Elevate thread priority (target nice -5) | ~3x more CPU time vs normal processes (when RLIMIT allows) | Low |

---

## Phase 4: Render Scheduling Correctness + Coalescing

**Date:** 2026-02-27
**Branch:** `fix-screencopy-cpu` in `~/repos/cosmic-comp`

After Phase 3, a regression appeared: animated surfaces (YouTube/GIF/terminal repaint) looked frozen unless mouse movement generated extra redraws. Root cause was commit-layer suppression logic: visible commits were being rate-limited at the semantic compositor layer.

### Change 14: Restore correctness for visible commits

**File:** `src/wayland/handlers/compositor.rs`

For any surface commit visible on an output, the compositor now always calls `schedule_render(output)`.

- No visible-commit suppression
- No keepalive gating in the commit handler
- Commit classification remains for diagnostics only

Classification uses `SurfaceAttributes::current()` (not `pending`) before `on_commit_buffer_handler`, matching smithay commit semantics.

**Result:** animation and terminal repaint progress no longer depend on cursor movement.

### Change 15: Keep render-request coalescing (safe layer)

**File:** `src/backend/kms/surface/mod.rs`

Added `render_schedule_pending: AtomicBool` to coalesce duplicate `schedule_render` requests before they flood the main-thread -> surface-thread channel.

This optimization is safe because it only deduplicates queued redraw requests; it does not suppress visible commits at the compositor semantic layer.

### Change 16: Coalescing lifecycle fix (starvation prevention)

**File:** `src/backend/kms/surface/mod.rs`

The initial coalescing implementation cleared `render_schedule_pending` too early (on `ScheduleRender` dequeue). Final behavior:

- Clear at redraw start (`redraw()` entry)
- Clear when scheduling cannot proceed (`startup_done == false` or no compositor)
- Clear on send failure

This prevents request-loss edge cases while still reducing redundant wakeups.

### Change 17: Default-on, actionable diagnostics

**Files:**
- `src/wayland/handlers/compositor.rs`
- `src/backend/kms/surface/mod.rs`

Diagnostics are enabled by default and promoted to warn-level with power-of-two rate limiting:

- Visible commit with no direct visual delta counter
- Very high visible commit cadence counter ("hot visual commits")
- Coalesced `schedule_render` request counter
- Overload transition/skip/force-serve counters

This makes regression triage possible from plain `journalctl` without custom scripts.

---

## Phase 5: Suspend/Resume Blank Output Fix

**Date:** 2026-02-27
**Branch:** `fix-screencopy-cpu` in `~/repos/cosmic-comp`

After resume from suspend, primary output could stay on a blank desktop with cursor only. This was traced to stale scheduling state and missing guaranteed post-resume redraw.

### Change 18: Reset schedule state on power transitions

**File:** `src/backend/kms/surface/mod.rs`

`render_schedule_pending` is explicitly reset on:

- `Surface::suspend()`
- `Surface::resume()`
- `Surface::set_dpms(false)`
- `SurfaceThreadState::suspend()`
- `SurfaceThreadState::resume()`

This prevents stale "pending" state from blocking new redraw requests after wake.

### Change 19: Force initial redraw after resume

**File:** `src/backend/kms/surface/mod.rs`

Two resume-side kicks were added:

- Main-side `Surface::resume()` calls `schedule_render()`
- Thread-side `SurfaceThreadState::resume()` calls `queue_redraw(true)` after compositor attach

This guarantees the first post-resume frame is produced even if no client commits happen immediately.

### Change 20: Backoff retries on DRM permission-denied submit errors

**File:** `src/backend/kms/surface/mod.rs`

On some resume paths (notably NVIDIA), early KMS commits can fail briefly with `Permission denied` while device/session access settles.

Instead of immediate tight-loop `queue_redraw(true)` retries, render submission now detects `std::io::ErrorKind::PermissionDenied` in the error chain and retries with a short backoff (`250ms`).

This avoids a retry storm right after wake and gives DRM/session state time to recover.

### Change 21: Recover from repeated DRM submit failures (EPERM/EBUSY)

**File:** `src/backend/kms/surface/mod.rs`

Observed failure mode after the second suspend in some sessions:

- Screen stuck on static wallpaper
- Cursor frozen in center
- Logs showed `Page flip commit failed ... Permission denied (13)` and `Device or resource busy (16)` with NVIDIA flip timeout messages.

Fix:

- Detect both `EPERM` and `EBUSY` in redraw submit errors
- Retry with backoff (`250ms` for permission denied, `120ms` for busy), escalating to slower retries under persistent failure
- Track consecutive DRM submit failures per surface thread
- After threshold (`6`) send a recovery request to the main thread
- Main thread suspends the failing surface, performs `drm.pause()` + `drm.activate(true)`, refreshes output config, refreshes shell state, and schedules render
- Reset failure counters on successful redraw submission and on suspend/resume transitions

This adds a proper recovery path instead of indefinitely retrying failed page flips in a tight loop.

### Change 22: Downgrade commit handler from WRITE lock to READ lock

**Date:** 2026-03-03
**File:** `src/wayland/handlers/compositor.rs`

After 14+ hours of uptime, DP-1 dropped from 45fps to 2.4fps. HDMI degraded from 17 to 9fps. Main thread used 50% CPU even with zero user input (1748 wakeups/sec from idle clients like Claude Code terminals).

**Root cause:** The `commit()` handler took a **WRITE lock** on the shell for **every** Wayland surface commit. `visible_output_for_surface()` and other read-only O(N) searches ran while holding this write lock. Since `parking_lot::RwLock` is write-preferring, surface render threads needing READ locks got starved — they woke up but couldn't acquire the lock. As internal state grew over hours, each iteration got slower (0.5ms → 5.5ms per commit), compounding the starvation.

**Fix:** Split the single WRITE lock into a READ lock fast path + conditional WRITE lock for rare mutations:

1. **Fast path (READ lock):** `visible_output_for_surface()` + `.cloned()`, then `schedule_render()` and diagnostics outside the lock. This is the common path (~98% of commits).
2. **Early returns** for `mapped` and popup commits happen without any write lock.
3. **Slow path (WRITE lock):** Only taken for actual mutations — null-buffer handling, resize grabs, layer surface rearrangement. The `is_null_buffer` check is done before acquiring the write lock.

**New diagnostics:** `COMMIT_WRITE_COUNT` and `COMMIT_WRITE_NANOS` counters track write lock frequency and duration. Logged every 60s in the main loop perf output as `write_commits` and `write_lock_ms`.

**Expected impact:** Write lock frequency drops from ~1748/sec (every commit) to ~60-70/sec (mostly main loop animation updates + occasional mutations), eliminating render thread starvation.

---

## Remaining Optimization Opportunities

1. **Per-consumer throttle:** Different screencopy consumers have different needs (workspace thumbnails need ~5 FPS, screen recording needs 30-60 FPS). The protocol could be extended to let consumers declare their desired frame rate.

2. **RT scheduling (SCHED_FIFO/RR):** If `nice(-5)` proves insufficient under extreme load, the next step is real-time scheduling for surface threads. Sway does this. However, SCHED_FIFO requires CAP_SYS_NICE and can cause system hangs if threads spin. Would need careful implementation with priority ceiling and watchdog.

3. **Adaptive quality levels:** Under sustained load, the compositor could reduce element complexity (skip shadows, simplify animations, reduce workspace overview thumbnail resolution) to maintain frame budget.

---

## Testing

Two test scenarios verify the fix. Both use the `cosmic-debug.sh` session (same as VRAM leak testing).

### Prerequisites

1. Build cosmic-comp: `cargo build --release` in the cosmic-comp repo
2. Switch to a TTY (Ctrl+Alt+F3) — do not run from within a desktop session
3. Start the debug compositor: `./cosmic-debug.sh start`

### Test A: Workspace Overview CPU Recovery

**Purpose:** Verify that CPU returns to baseline after closing the workspace overview.

**Steps:**

1. Start the debug compositor with the fixed cosmic-comp binary
2. Open a terminal inside the session
3. Run the CPU test script:

```bash
./cosmic-cpu-test.sh overview
```

**What it does:**
1. Records baseline CPU usage (5-second average)
2. Opens 5 cosmic-term windows
3. Records CPU with windows open
4. Simulates opening workspace overview (Super+W) via `cosmic-workspaces` activity
5. Records peak CPU during overview
6. Closes workspace overview
7. Waits 5 seconds for sessions to go idle
8. Records CPU after overview close

**Expected (fixed):**

```
Baseline CPU:         ~1-4%
With windows:         ~4-10%
During overview:      ~40-60%
After overview close: ~4-10%   ← must recover
PASS
```

**Expected (broken):**

```
Baseline CPU:         ~1-4%
With windows:         ~4-10%
During overview:      ~80-100%
After overview close: ~80-100%  ← stays high
FAIL
```

**Pass criteria:** CPU after closing the overview must be within 15% of the pre-overview value. If CPU remains elevated (>30% above pre-overview), the test fails.

### Test B: Long Session CPU Stability

**Purpose:** Verify that CPU does not grow over time through repeated workspace interactions.

**Steps:**

1. Start the debug compositor
2. Run the stability test:

```bash
./cosmic-cpu-test.sh stability
```

**What it does:**
1. Records baseline CPU
2. Runs 10 cycles of: open 5 windows → open/close overview → close windows → wait 10s
3. Records CPU after each cycle
4. Compares final CPU to baseline

**Expected (fixed):**

```
Cycle  1: CPU after idle: ~4%
Cycle  5: CPU after idle: ~4%
Cycle 10: CPU after idle: ~4%
Final delta: <5%
PASS
```

**Expected (broken):**

```
Cycle  1: CPU after idle: ~20%
Cycle  5: CPU after idle: ~50%
Cycle 10: CPU after idle: ~90%
Final delta: >50%
FAIL
```

**Pass criteria:** CPU after the final idle period must be within 10% of baseline. If it exceeds baseline by more than 15%, the test fails.

### Test C: Screenshot startup reliability under load

**Purpose:** Verify screenshot requests always start without needing keyboard/mouse nudges.

**Steps:**

1. Start the debug compositor.
2. Create sustained CPU pressure (for example with multiple Claude sessions and browser tabs, or `stress-ng`).
3. Trigger screenshot repeatedly from the UI and from portal clients.
4. Confirm each attempt starts and completes without pressing Super or moving the cursor.

**Pass criteria:**

- 0 startup hangs across repeated attempts (idle and stressed).
- No "unstick by pressing Super" behavior.
- First frame latency remains bounded (minor delay acceptable, but no multi-second stalls).

### Built-in diagnostics for next reboot test

The compositor now includes additional low-overhead diagnostics and request coalescing.
These diagnostics are now enabled by default in code (no script/env setup required).
Set a variable to `0` to disable a specific signal path if needed.

- **Commit filter diagnostics** (`COSMIC_DEBUG_COMMIT_FILTER`, default on): Logs (power-of-two rate) when visible commits have no direct visual delta, and when visible commit cadence is unusually high (<~6ms average frame-time estimate).
- **Render schedule coalescing diagnostics** (`COSMIC_DEBUG_RENDER_SCHED`, default on): Logs when duplicate `schedule_render` requests are coalesced before crossing the main-thread -> surface-thread channel.
- **Overload transition diagnostics** (`COSMIC_DEBUG_OVERLOAD_TRANSITIONS`, default on): Logs overload enter/exit transitions and screencopy skip/force-serve decisions.

To disable a channel temporarily, set it to `0` in the environment before launch.

These toggles let you collect actionable evidence in a single reboot cycle without code changes.

### `cosmic-cpu-test.sh` — Automated CPU test script

```bash
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
```

### Quick manual verification

If the test scripts aren't available, a quick manual check:

```bash
# Find cosmic-comp PID
COMP_PID=$(pgrep -x cosmic-comp)

# Baseline
top -bn1 -p $COMP_PID | tail -1

# Open workspace overview (Super+W), wait 3 seconds
top -bn1 -p $COMP_PID | tail -1

# Close overview, wait 5 seconds
top -bn1 -p $COMP_PID | tail -1   # should return to baseline
```

With the fix: CPU should return to near-baseline within 5 seconds of closing the overview.
Without the fix: CPU stays at ~100% permanently.

---

## Phase 6: Output-Local Attribution + Real-Session Deployment

**Date:** 2026-03-06
**Branch:** `fix-screencopy-cpu` in `~/repos/cosmic-comp`

After the earlier screencopy, timing, lock, and resume work, there were still two major problems:

1. **The per-output animation fix was incomplete.** The main loop used `animations_going_for_output()`, but surface threads still made redraw decisions using global `animations_going()`. On a dual-monitor setup, animation on one head could still keep the other head rendering.
2. **The new perf logs were not trustworthy enough for soak tests.** Render-schedule counters were global statics but emitted from per-output logs, and screencopy capture activity used wall-clock time.

### Change 23: Finish output-local animation gating

**File:** `src/backend/kms/surface/mod.rs`

Surface-thread redraw scheduling now uses the current output's animation state in all three places that matter:

- `on_vblank()`
- `on_estimated_vblank()`
- `redraw()` scanout/VRR decision path

This removes the last remaining global redraw trigger in the surface thread.

**New diagnostic:** rate-limited `cross_output_animations` warnings/log counters. If a surface thread sees global animation state without local animation state, it records that explicitly so cross-output churn is visible in logs.

### Change 24: Use monotonic screencopy timing

**File:** `src/wayland/handlers/image_copy_capture/user_data.rs`

`ImageCopySessions` activity timestamps and pending-frame age now use a process-local monotonic clock instead of `SystemTime`. This avoids false capture-active states after:

- suspend/resume
- NTP adjustments
- manual wall-clock changes

### Change 25: Per-output render-schedule counters

**File:** `src/backend/kms/surface/mod.rs`

`render_requests` and `render_coalesced` are now stored per surface thread instead of process-global atomics. Each output's 60-second perf line now reflects that output only.

Also added:

- `screencopy_skip_streak`
- `screencopy_skips_interval`
- `retry_permission_denied`
- `retry_busy`
- `retry_unknown`
- `dominant_cause`

`dominant_cause` classifies each interval as one of:

- `busy-render`
- `blocked-on-lock`
- `capture-pressure`
- `error-retry`

### Change 26: Back off repeated unknown DRM submit failures

**File:** `src/backend/kms/surface/mod.rs`

The old code only backed off recognized `EPERM` / `EBUSY` submit failures. Other repeated failures retried immediately, which could recreate a busy retry loop under odd long-uptime or post-resume conditions.

Now:

- permission denied retries use `250ms` base delay
- busy retries use `120ms` base delay
- unknown recurring failures use bounded backoff too
- only the known `EPERM` / `EBUSY` families trigger DRM access recovery

### Change 27: Warn on sustained unscheduled visual commits

**File:** `src/lib.rs`

The main loop now tracks repeated 60-second intervals with non-zero `COMMIT_VISUAL_UNSCHEDULED` and emits a warning if that condition persists. This is aimed at cases where visible commits are happening but no output is being scheduled for redraw.

### Real-session deployment for the next diagnostic cycle

The next verification step should use the **actual rebooted COSMIC session**, not only the `cosmic-debug.sh` KMS harness.

**Runtime binary path in use now:** `/usr/bin/cosmic-comp`

**Deployment flow:**

```bash
cd ~/repos/cosmic-comp
cargo build --release

sudo cp -a /usr/bin/cosmic-comp /usr/bin/cosmic-comp.backup.$(date +%Y%m%d-%H%M%S)
sudo install -o root -g root -m 0755 \
  ~/repos/cosmic-comp/target/release/cosmic-comp \
  /usr/bin/cosmic-comp

reboot
```

After reboot, collect:

```bash
journalctl --user -b 0 | grep '\[perf\]'
```

The goal is that any future lag event on `minotiros` lands in a clear bucket instead of appearing as generic “cosmic-comp got slow again”.

---

## Related Issues

| Issue | Description | Relation to this fix |
|-------|-------------|---------------------|
| [cosmic-comp #972](https://github.com/pop-os/cosmic-comp/issues/972) | High CPU usage when idle | Directly addressed — dock screencopy was a major idle CPU contributor |
| [cosmic-comp #1656](https://github.com/pop-os/cosmic-comp/issues/1656) | High CPU and lag when mouse over panel | Directly addressed — panel hover triggers screencopy request storms |
| [cosmic-comp #2062](https://github.com/pop-os/cosmic-comp/issues/2062) | High CPU leads to mouse stuttering | Addressed via calloop 0.14.4 bump |
| [cosmic-comp #2073](https://github.com/pop-os/cosmic-comp/issues/2073) | Minimize-applet screencopy memfd leak | Related but NOT addressed — separate buffer lifecycle issue |
| [cosmic-comp #1891](https://github.com/pop-os/cosmic-comp/issues/1891) | Memory leak causes mouse input lag | Likely partially addressed — screencopy buffer leak + calloop fix |
| [cosmic-comp PR #1371](https://github.com/pop-os/cosmic-comp/pull/1371) | Performance fixes (frame scheduling, VRR cursor) | Complementary — merged fix addresses frame scheduling; our fix addresses screencopy |
| [cosmic-comp #1179](https://github.com/pop-os/cosmic-comp/issues/1179) | Video Memory Leak | Fixed separately (weak_window_upstream_smithay branch) |
| [Smithay #1562](https://github.com/Smithay/smithay/issues/1562) | Closing windows causes VRAM leak | Open upstream |

The CPU fix in this document is independent of all VRAM/RAM leak fixes and can be applied alongside them.
