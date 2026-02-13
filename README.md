# Pop!_OS VRAM Leak Fix

Fixes a VRAM leak in the COSMIC compositor where GPU texture memory is never reclaimed when windows are closed. On an NVIDIA RTX 2070, this leaks ~4.8 MB of VRAM per cosmic-term window, accumulating indefinitely. Also fixes two smaller CPU RAM leaks (shader caches and activation tokens).

**The leak affects all Smithay-based compositors** — Niri has the same root cause ([YaLTeR/niri#1869](https://github.com/YaLTeR/niri/issues/1869)), not just cosmic-comp. Smithay maintainer cmeissl is actively working on upstream fixes.

## Forked Repositories

- **cosmic-comp:** [github.com/MartinKavik/cosmic-comp @ weak_window](https://github.com/MartinKavik/cosmic-comp/tree/weak_window) — [diff vs upstream master](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:weak_window)
  Structural fix: stores `Weak` references in `ToplevelHandleState`, making the VRAM leak impossible
- **cosmic-comp:** [github.com/MartinKavik/cosmic-comp @ fix_vram_leak](https://github.com/MartinKavik/cosmic-comp/tree/fix_vram_leak) — [diff vs upstream master](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:fix_vram_leak)
  Quick fix: explicitly clears stale references + fixes shader cache and activation token leaks
- **smithay:** [github.com/MartinKavik/smithay @ weak_window](https://github.com/MartinKavik/smithay/tree/weak_window) — [diff vs upstream master](https://github.com/Smithay/smithay/compare/master...MartinKavik:smithay:weak_window)
  Adds `WeakWindow` type — enables compositors to hold weak references to windows
- **smithay:** [github.com/MartinKavik/smithay @ fix_vram_leak](https://github.com/MartinKavik/smithay/tree/fix_vram_leak) — [diff vs upstream master](https://github.com/Smithay/smithay/compare/master...MartinKavik:smithay:fix_vram_leak)
  Workaround that confirmed the theory (clears `MultiTextureInternal` on surface destroy; breaks window closing animations — not for production merge)

## Overview

I have two working fixes for the VRAM leak, both tested with zero leakage:

1. **`weak_window` branches (recommended):** Stores `Weak` references in `ToplevelHandleState` instead of strong `Arc` clones. Makes the leak structurally impossible — no explicit cleanup needed. Requires a small smithay change (`WeakWindow` type). See [Structural Fix: WeakWindow](#structural-fix-weakwindow-tested-no-leak).

2. **`fix_vram_leak` branch (quick fix):** Explicitly sets `handle_state.window = None` on window removal. Also fixes shader cache and activation token leaks. Pure cosmic-comp change, no smithay changes needed.

Both approaches are proven and tested. The `weak_window` approach is architecturally cleaner; the `fix_vram_leak` approach is simpler to merge since it doesn't touch smithay.

### 1. VRAM Leak — ToplevelHandleState.window never cleared (cosmic-comp)

**Root cause of the VRAM leak.** When a window is destroyed, cosmic-comp's `remove_toplevel()` sends `closed` events to protocol clients and removes the window from its `toplevels` Vec, but never clears the `window: Option<CosmicSurface>` field in each `ZcosmicToplevelHandleV1` handle's user data (`ToplevelHandleState`).

Protocol handle objects persist until the **client** explicitly destroys them. Long-running clients (cosmic-panel, cosmic-workspaces — and even cosmic-term itself, which binds to `zcosmic_toplevel_info_v1`) keep handles alive indefinitely. Each handle retains a `CosmicSurface` clone that shares `Arc<WindowInner>`, preventing the inner window from being dropped.

**The leak chain:**
```
ZcosmicToplevelHandleV1 (protocol object, alive until client destroys it)
  -> ToplevelHandleState { window: Some(CosmicSurface) }
    -> Window(Arc<WindowInner>)             <- prevents Arc refcount from reaching 0
      -> ToplevelSurface { wl_surface, shell_surface }
        -> 3 WlSurface handles (via shell_surface user data)
          -> SurfaceUserData alive (wayland-server 0.31.x: lives as long as any handle)
            -> data_map alive
              -> Arc<Mutex<MultiTextureInternal>> alive -> GPU textures trapped
```

**Quick fix (`fix_vram_leak` branch):** Set `handle_state.window = None` in both `remove_toplevel()` and `refresh()` (dead-window safety-net path) in `src/wayland/protocols/toplevel_info.rs`. This drops the `CosmicSurface` clone immediately, allowing `Arc<WindowInner>` refcount to reach 0, which drops all `WlSurface` handles, which drops `SurfaceUserData` and its `data_map`, which drops `MultiTextureInternal` and frees GPU textures.

**Recommended fix (`weak_window` branches):** Store `Weak` references instead of strong clones — see [Structural Fix: WeakWindow](#structural-fix-weakwindow-tested-no-leak).

**Impact:** ~4.8 MB VRAM leaked per cosmic-term window (~97 MB per 20-window cycle). With the fix, VRAM stays flat.

**Files changed:**
- `src/wayland/protocols/toplevel_info.rs` — clear `ToplevelHandleState.window` to `None` on toplevel removal

### 2. Shader Cache Leak — CPU RAM only (cosmic-comp)

Shadow, Indicator, and Backdrop pixel shader elements are cached per-window in the EGL context's `user_data()` but never cleaned up when windows close. These caches store CPU-side data only (shader parameters, geometry, uniforms) — not GPU textures — so this is a RAM leak, not a VRAM leak. Each entry is small (a few hundred bytes), but they accumulate unbounded.

**Fix:** Added `remove_from_shader_caches()` called from the render loop via a deferred `pending_shader_cleanup` queue on `Shell`.

**Files changed:**
- `src/backend/render/mod.rs` — `remove_from_shader_caches()` function and render-loop integration
- `src/backend/render/shadow.rs` — `ShadowCache` visibility changed to `pub(super)` (accessible within render module)
- `src/shell/mod.rs` — `pending_shader_cleanup` queue, populated during `unmap_surface()`
- `src/shell/element/mod.rs` — `Debug` impl for `CosmicMappedKey`
- `src/backend/render/mod.rs` also contains the render-loop cleanup call in `render_output()`

### 3. Activation Token Leak — CPU RAM only (cosmic-comp)

`pending_activations` `HashMap` entries for destroyed windows were never removed. Tokens accumulate in CPU RAM indefinitely.

**Fix:** Clean up Wayland activation tokens in `toplevel_destroyed()` and X11 tokens in `destroyed_window()`.

**Files changed:**
- `src/wayland/handlers/xdg_shell/mod.rs` — remove activation token on Wayland toplevel destroy
- `src/xwayland.rs` — remove activation token on X11 window destroy

## Smithay-Side Investigation

I also investigated and confirmed the leak from the smithay side.

**My workaround:** Commit [`035e3c4`](https://github.com/MartinKavik/smithay/commit/035e3c4736a1fc4cc7fee5a184cd8fe54a4cdcfc) clears `MultiTextureInternal.textures` in the surface destruction hook in `src/backend/renderer/utils/wayland.rs`. Made `MultiTextureInternal` `pub(crate)`, added a `clear_textures()` method, and introduced a `MultiTextureUserData` type alias for the `Arc<Mutex<MultiTextureInternal>>`.

**Result:** VRAM leak is resolved in nvidia-smi when smithay is patched this way — confirms that the VRAM is trapped in `MultiTextureInternal` inside the surface's `data_map`.

**Problems:**
- **Breaks window closing animations** — textures are cleared before the compositor can render the final fade-out frames
- **Doesn't fix the root cause** — stale `Arc` references in cosmic-comp still prevent `WindowInner` from being dropped, so other resources (shader caches, activation tokens, `RendererSurfaceState`) continue to leak
- The smithay-side fix is treating the symptom (trapped textures), not the disease (stale references)

**Takeaway:** This workaround proves the VRAM is trapped in `MultiTextureInternal` inside `SurfaceUserData.data_map`, reachable through the stale `WlSurface` handle chain. The recommended fix is [WeakWindow](#structural-fix-weakwindow-tested-no-leak) — it eliminates the stale reference structurally, allowing the entire chain to be dropped naturally.

## Upstream Status & Cross-Compositor Context

**The leak is NOT cosmic-comp-specific — it affects all Smithay-based compositors.**

The root cause spans two layers:

**Compositor layer:** Stale references hold `WlSurface` handles past surface destruction. In cosmic-comp, it's `ToplevelHandleState.window`. In Niri, it was dead surface hooks being installed on already-destroyed surfaces.

**Library layer:** wayland-server 0.31.x keeps `SurfaceUserData` alive as long as **any** Rust `WlSurface` handle exists. This means `data_map` → `MultiTextureInternal` → GPU textures are trapped until every handle is dropped.

**Structural issue:** `UserDataMap` (smithay's `src/utils/user_data.rs`) is a lock-free **append-only** linked list — it has NO `clear()`, `remove()`, or any way to free individual entries. GPU textures stored in `data_map` are literally trapped until the entire `SurfaceData` is dropped.

### Affected compositors

- **Cosmic** — affected (my fix: [cosmic-comp @ weak_window](https://github.com/MartinKavik/cosmic-comp/tree/weak_window), also [@ fix_vram_leak](https://github.com/MartinKavik/cosmic-comp/tree/fix_vram_leak))
- **Niri** — affected, fixed via [YaLTeR/niri#3404](https://github.com/YaLTeR/niri/pull/3404) (merged)
- **River, Hyprland, Sway** — NOT affected (not Smithay-based)
- Confirmed on both AMD and NVIDIA GPUs

### cmeissl's upstream work

- [Smithay PR #1921](https://github.com/Smithay/smithay/pull/1921) (DRAFT) — prevent hooks/blockers on destroyed surfaces; "might fix #1562"
- [Smithay PR #1924](https://github.com/Smithay/smithay/pull/1924) (OPEN) — documents undefined destruction order for client disconnects
- [Niri PR #3404](https://github.com/YaLTeR/niri/pull/3404) (MERGED) — fixes Niri's variant by preventing dead surface hook installation

## Structural Fix: WeakWindow (Tested, No Leak)

> **Status: Implemented and tested — no VRAM leak observed. Needs confirmation from cosmic-comp maintainers.**
>
> This approach was suggested by cmeissl in [his comment on Smithay #1562](https://github.com/Smithay/smithay/issues/1562#issuecomment-3864200389), where he identified the reference cycle and recommended using `Weak` references. I explored several other approaches first (RAII guards with retained flags, Arc::strong_count checks, explicit texture clearing in destruction hooks) but weak references turned out to be the cleanest solution — minimal code, no explicit cleanup, structurally prevents the leak.

### The problem

`ToplevelHandleState` stores a strong `CosmicSurface` reference (which wraps `Arc<WindowInner>`). Wayland protocol handles (`ZcosmicToplevelHandleV1`) persist until the **client** explicitly destroys them — even after the compositor sends a `closed` event. This creates a reference cycle: the protocol handle keeps `Arc<WindowInner>` alive, which keeps `WlSurface` handles alive, which keeps `SurfaceUserData` and its `data_map` alive, which traps `MultiTextureInternal` and its GPU textures in VRAM.

The [cosmic-comp `fix_vram_leak` branch](https://github.com/MartinKavik/cosmic-comp/tree/fix_vram_leak) fixes this by explicitly setting `handle_state.window = None` on window removal. This works, but requires remembering to clear the reference at the right time. The `WeakWindow` approach makes the leak **structurally impossible** — no explicit cleanup needed.

### The fix: store `Weak` instead of strong references

Since `Window` is `Arc<WindowInner>`, we can store `Weak<WindowInner>` in the protocol handle's user data. When the compositor drops its last strong reference to a window, the weak reference becomes invalid automatically, and the entire resource chain is freed.

**Branches:**
- **smithay:** [MartinKavik/smithay @ weak_window](https://github.com/MartinKavik/smithay/tree/weak_window) — [diff vs upstream master](https://github.com/Smithay/smithay/compare/master...MartinKavik:smithay:weak_window)
- **cosmic-comp:** [MartinKavik/cosmic-comp @ weak_window](https://github.com/MartinKavik/cosmic-comp/tree/weak_window) — [diff vs upstream master](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:weak_window)

### Changes

**Smithay** (1 file):

| File | Change |
|---|---|
| `src/desktop/wayland/window.rs` | Add `WeakWindow` type wrapping `Weak<WindowInner>`, add `Window::downgrade()` method |

```rust
impl Window {
    pub fn downgrade(&self) -> WeakWindow {
        WeakWindow(Arc::downgrade(&self.0))
    }
}

#[derive(Debug, Clone)]
pub struct WeakWindow(Weak<WindowInner>);

impl WeakWindow {
    pub fn upgrade(&self) -> Option<Window> {
        self.0.upgrade().map(Window)
    }
}
```

**Cosmic-comp** (3 files):

| File | Change |
|---|---|
| `src/shell/element/surface.rs` | Add `WeakCosmicSurface` wrapping `WeakWindow`, add `CosmicSurface::downgrade()` |
| `src/wayland/protocols/toplevel_info.rs` | Add `Window::Weak` associated type and `Window::upgrade()` static method; change `ToplevelHandleStateInner.window` from `Option<W>` to `Option<W::Weak>`; store `window.downgrade()` in `from_window()`; use `W::upgrade()` in `window_from_handle()` |
| `src/wayland/handlers/toplevel_info.rs` | Implement `Window::Weak`, `Window::downgrade()` and `Window::upgrade()` for `CosmicSurface`/`WeakCosmicSurface` |

The key change is one line in `ToplevelHandleStateInner`:
```rust
// Before: strong reference keeps WindowInner alive
window: Option<W>,

// After: weak reference allows WindowInner to be dropped
window: Option<W::Weak>,
```

### Why this is better than explicit `None`-setting

| | Explicit `None` (`fix_vram_leak`) | `WeakWindow` (`weak_window`) |
|---|---|---|
| **Leak prevention** | Must remember to clear at the right time | Structural — impossible to leak via this path |
| **New code adding handles** | Could introduce the same bug | Automatically safe — weak refs can't keep resources alive |
| **Cleanup code needed** | Yes (`handle_state.window = None`) | No — dropping the last strong ref is enough |
| **Smithay changes** | None | 1 file (add `WeakWindow` type) |
| **Risk** | Low — proven fix | Low — standard `Arc`/`Weak` pattern |

### Relationship to other fixes

- The `WeakWindow` approach replaces the need for explicit `window = None` cleanup in `remove_toplevel()` for the VRAM leak. The shader cache and activation token fixes from the [`fix_vram_leak` branch](https://github.com/MartinKavik/cosmic-comp/tree/fix_vram_leak) are separate issues and still needed.
- cmeissl's [PR #1921](https://github.com/Smithay/smithay/pull/1921) (preventing hooks on destroyed surfaces) addresses a different leak variant (Niri's). Both fixes are complementary.
- The smithay workaround branch ([`fix_vram_leak`](https://github.com/MartinKavik/smithay/tree/fix_vram_leak)) that clears `MultiTextureInternal` in the destruction hook is NOT needed with this approach and is not recommended for merge (it breaks closing animations).

## Related Issues and PRs

### Smithay (library)

| Issue/PR | Title | Status | Relevance |
|---|---|---|---|
| [#1562](https://github.com/Smithay/smithay/issues/1562) | Closing windows causes VRAM leak | OPEN (cmeissl) | Root upstream issue |
| [PR #1921](https://github.com/Smithay/smithay/pull/1921) | Prevent hooks on destroyed surfaces | DRAFT | cmeissl's fix approach |
| [PR #1924](https://github.com/Smithay/smithay/pull/1924) | Document destruction order | OPEN | Related docs |
| [PR #1573](https://github.com/Smithay/smithay/pull/1573) | Session lock reference cycle fix | MERGED | Earlier ref-cycle leak (different root cause) |

### cosmic-comp

| Issue/PR | Title | Status | Relevance |
|---|---|---|---|
| [#1179](https://github.com/pop-os/cosmic-comp/issues/1179) | Video Memory Leak | OPEN | Main bug report |
| [#1133](https://github.com/pop-os/cosmic-comp/issues/1133) | Memory leaks upon closing | OPEN | Related RAM leak reports |

### Niri (also Smithay-based)

| Issue/PR | Title | Status | Relevance |
|---|---|---|---|
| [#1869](https://github.com/YaLTeR/niri/issues/1869) | Video memory not released | COMPLETED | Same root cause, fixed via PR #3404 |
| [#772](https://github.com/YaLTeR/niri/issues/772) | Memory leaking (screen locker) | COMPLETED | Different leak, fixed via smithay PR #1573 |
| [PR #3404](https://github.com/YaLTeR/niri/pull/3404) | Fix dead surface hook | MERGED | cmeissl's fix for Niri's variant |
| [#1742](https://github.com/YaLTeR/niri/issues/1742) | OOM crash on long sessions | OPEN | Potentially related |
| [#3295](https://github.com/YaLTeR/niri/issues/3295) | GPU memory climbing when screens off | OPEN | Niri-specific, different trigger |

### cosmic-epoch (same root cause)

| Issue/PR | Title | Status | Relevance |
|---|---|---|---|
| [#1591](https://github.com/pop-os/cosmic-epoch/issues/1591) | cosmic-comp VRAM growing | OPEN | Same issue as cosmic-comp #1179 |
| [#2122](https://github.com/pop-os/cosmic-epoch/issues/2122) | Memory increasing over time | OPEN | Likely partly caused by shader cache + activation token leaks |

### Other reported leaks (not investigated in this report)

| Issue | Title | Status | Notes |
|---|---|---|---|
| [#2073](https://github.com/pop-os/cosmic-comp/issues/2073) | Minimize-applet screencopy memfd buffers never freed | OPEN | Screencopy `memfd` shared memory buffers leak ~370/hour during normal use. 16+ GB Shmem observed. Different mechanism — buffer lifecycle, not window references. Workaround: disable "Minimized windows" applet |
| [#2080](https://github.com/pop-os/cosmic-comp/issues/2080) | Memory leak when running OBS | OPEN | cosmic-comp accumulates RAM while OBS screen-captures. Likely same screencopy buffer issue as #2073 but triggered by OBS. Linked to [Smithay #1925](https://github.com/Smithay/smithay/issues/1925) |

## How I Diagnosed the Leak

The VRAM leak was diagnosed through a systematic elimination process, narrowing from "something holds WlSurface handles" to the exact leaking clone of `Arc<WindowInner>`.

### Phase 1: Identify the symptom

VRAM grows ~4.8 MB per cosmic-term window and is never reclaimed. Smithay's `MultiTextureInternal` (GPU texture cache per surface) is trapped in the `data_map` of `SurfaceUserData`, which stays alive as long as any Rust `WlSurface` handle exists (wayland-server 0.31.x behavior). Something in cosmic-comp holds `WlSurface` handles after the client disconnects.

### Phase 2: Static analysis of all CosmicSurface storage locations

Audited every data structure in cosmic-comp that stores `CosmicSurface`, `CosmicMapped`, or `Window`:

- Workspace layouts (floating/tiling) — cleaned in `unmap_element()`
- Focus stacks — cleaned via `shift_remove` in `unmap_element()`
- Sticky layer — checked and removed
- Minimized windows — checked (found bugs, but not the primary leak)
- `ToplevelInfoState.toplevels` Vec — removed by `remove_toplevel()`
- `pending_windows` — retained by `alive()` check
- Space elements — retained by `alive()` check
- Render caches — use `Weak` references
- Calloop executor — does NOT hold element references
- Activation tokens — only store `String` keys, not surfaces
- FloatingLayout animations — removed by `unmap(to=None)`
- MoveGrabState — temporary, grab-scoped

**Result:** All known data structures clean up properly. Static analysis exhausted.

### Phase 3: Runtime diagnostics — comprehensive probes

Added a delayed diagnostic callback (fires 500ms after `toplevel_destroyed`) that checks 14 probe points simultaneously:

| Probe | What it checks | Result |
|-------|---------------|--------|
| ptr_focus | Pointer focus target | false |
| ptr_pending | Pointer pending focus | false |
| ptr_grabbed | Pointer grab surface | false |
| kbd_focus | Keyboard focus target | false |
| kbd_pending | Keyboard pending focus | false |
| kbd_grabbed | Keyboard grab surface | false |
| active_focus | ActiveFocus list | false |
| in_element_for_surface | element_for_surface() lookup | false |
| is_surface_mapped | is_surface_mapped() | false |
| in_pending | pending_windows | false |
| in_registered_toplevels | ToplevelInfoState.toplevels Vec | false |
| in_any_space | All Space elements across all workspaces | false |
| in_any_minimized | All minimized_windows across all workspaces | false |
| in_any_fullscreen | Raw fullscreen fields (bypassing alive() filter) | false |

**Result:** ALL probes false. The leaked reference is NOT in any cosmic-comp data structure accessible through the Shell or State. But `Arc::strong_count()` still shows extra references.

### Phase 4: Per-clone tracking — the definitive answer

Added instrumentation directly to smithay's `Window` struct:
- `clone_id: u64` field on every `Window` instance (incremented atomically on each clone)
- `clone_registry: Mutex<HashMap<u64, String>>` on `WindowInner`, recording the creation backtrace of every live clone
- `dump_live_clones()` method to print all surviving clones after destruction

After closing a window and waiting 500ms, `dump_live_clones()` reported exactly **one** surviving clone:

```
clone_id=1500: ToplevelHandleStateInner::from_window
  at cosmic-comp/src/wayland/protocols/toplevel_info.rs:115
  called from get_cosmic_toplevel request handler at line 200
```

**Root cause confirmed:** `ToplevelHandleStateInner::from_window(window)` clones the `CosmicSurface` into the protocol handle's user data. This clone is never cleared when the window is destroyed.

**Key discovery:** Even in bare TTY testing (no cosmic-panel, no cosmic-workspaces), cosmic-term itself binds to `zcosmic_toplevel_info_v1` and requests handles for its own windows. So the leak affects EVERY window, not just sessions with panel/workspaces running.

### Phase 5: Fix and verify

Added `handle_state.lock().unwrap().window = None` in both `remove_toplevel()` and the `refresh()` dead-window path.

Verification: `Arc::strong_count()` dropped from 3 to 2, then to 1 (only the diagnostic clone), then `WindowInner` DROPPED message confirmed full cleanup. VRAM stays flat.

## Confirmed Remaining Leaks

All tests below run on the `weak_window` branch (with the main ToplevelHandleState VRAM leak already fixed). System: NVIDIA RTX 2070, uptime 1 day 7 hours.

### Leak A: Workspace Overview (Super+W) — largest confirmed leak

Opening and closing the workspace overview while windows are open leaks significant VRAM. The leak persists after windows are closed normally.

| | Before | After | Delta |
|--|--------|-------|-------|
| cosmic-comp VRAM | 1342 MiB | 1545 MiB | **+203 MiB** |
| cosmic-workspaces VRAM | 94 MiB | 142 MiB | **+48 MiB** |
| Total GPU | 3407 MiB | 3736 MiB | **+329 MiB** |

**Test:** Opened 20 cosmic-term windows, pressed Super+W 10 times (5 open/close cycles of the workspace overview), then closed all 20 windows normally. **+203 MiB leaked in cosmic-comp, +48 MiB in cosmic-workspaces.**

**Probable cause:** `cosmic-workspaces` uses `ext_foreign_toplevel_image_capture_source_manager_v1` to create toplevel capture sources for window thumbnails in the overview. On the server side (cosmic-comp), `toplevel_source_created()` stores `ImageCaptureSourceKind::Toplevel(CosmicSurface)` — a strong reference — in the capture source's user data (`src/wayland/handlers/image_capture_source.rs:48`). Additionally, each capture session holds its own `ImageCaptureSource` Arc clone via `SessionInner.source`, and sessions are stored in the `CosmicSurface`'s user_data via `add_session()`, creating a reference cycle:

```
ImageCaptureSource (Arc)
  -> UserDataMap -> ImageCaptureSourceKind::Toplevel(CosmicSurface)  [strong ref]
    -> CosmicSurface (Arc<WindowInner>) -> user_data -> Vec<Session>
      -> Session -> SessionInner -> source: ImageCaptureSource (Arc clone)  [cycle]
        -> keeps entire chain alive even after window is destroyed
          -> WlSurface handles alive -> SurfaceUserData -> data_map -> GPU textures trapped
```

**This is likely the biggest VRAM leak for typical usage** — workspace overview is used frequently, and each open/close cycle leaks VRAM proportional to the number of visible windows.

**Fix summary (cosmic-comp + smithay):**

Three changes are required together:

1. **Use `WeakCosmicSurface` in `ImageCaptureSourceKind::Toplevel`** (cosmic-comp, already on `weak_window` branch):
   - File: `src/wayland/protocols/image_capture_source.rs:37`
   - Breaks the reference cycle — capture sources no longer keep `CosmicSurface` alive

2. **Stop all capture sessions before dropping a toplevel** (cosmic-comp):
   - File: `src/wayland/handlers/image_copy_capture/user_data.rs` — new `stop_all_capture_sessions(&UserDataMap)` function that drains owned `Session`/`CursorSession` from the surface's user data
   - File: `src/wayland/protocols/toplevel_info.rs` — call `stop_all_capture_sessions(toplevel.user_data())` in `remove_toplevel()` (before `self.toplevels.retain()`) and in `refresh()` (in the `!window.alive()` branch)
   - Needed because with `WeakCosmicSurface`, the `session_destroyed` callback can't `upgrade()` the weak ref after the surface is dropped, so `remove_session()` never runs. Explicitly draining sessions triggers `Session::drop()`, which fails active frames and releases GPU buffers.

3. **Cherry-pick smithay `mem::forget` fix** (smithay commit [`3d3f9e35`](https://github.com/Smithay/smithay/commit/3d3f9e359352d95cffd1e53287d57df427fcbd34) by Ian Douglas Scott):
   - File: `src/wayland/image_copy_capture/mod.rs`
   - Replaces `std::mem::forget(self)` in `Frame::success()` and `Frame::fail()` with a `completed: bool` flag. Previously, `mem::forget` prevented `Frame::drop()` from running, silently leaking GPU buffers. With this fix, `Frame::drop()` properly fails uncommitted frames and releases resources.
   - **Important:** This commit is included in smithay upstream master at rev `599857c`, but that rev also contains unrelated changes (`xdg-shell` v7 update, `ext-background-effect-v1` protocol) that cause `wp_viewport` protocol errors, crashing `cosmic-workspaces` at `screencopy.rs:81`. The fix must be cherry-picked onto the base rev (`14a2009`) individually to avoid this breakage.

**Test results (fixed, 4 rounds of 20 windows + 5 Super+W cycles each):**

| Round | cosmic-comp | cosmic-workspaces | Notes |
|-------|------------|-------------------|-------|
| 0 (baseline) | 32 MiB | 14 MiB | Fresh session |
| 1 | 231 MiB | 142 MiB | One-time allocation of working set |
| 2 | 207 MiB | 142 MiB | No growth |
| 3 | 161 MiB | 142 MiB | No growth |
| 4 | 248 MiB | 142 MiB | Normal variance, no accumulation |

**Before fix:** cosmic-comp leaked +203 MiB per 5-cycle test, accumulating linearly.
**After fix:** VRAM fluctuates but does not accumulate across cycles. Leak eliminated.

### Leak B: Minimized Windows killed while minimized

Killing windows while minimized leaks VRAM through `minimized_windows` storage.

| | Before | After killing 20 minimized windows | Delta |
|--|--------|-------------------------------------|-------|
| cosmic-comp VRAM | 1245 MiB | 1342 MiB | **+97 MiB** |
| Total GPU | 3263 MiB | 3407 MiB | **+144 MiB** |

**Test:** Opened 20 cosmic-term windows, minimized all via title bar, then killed all 20 processes while minimized (`kill <pids>`). **~4.8 MB leaked per window** — identical rate to the original ToplevelHandleState leak, confirming the same `Arc<WindowInner>` → GPU texture chain.

**Additionally**, `ImageCaptureSourceKind::Toplevel(CosmicSurface)` in `src/wayland/protocols/image_capture_source.rs:37` stores a strong `CosmicSurface` clone in the capture source user data. The `cosmic-applet-minimize` (minimized windows dock applet) creates toplevel capture sources for window thumbnails. If these capture source handles outlive the window, they contribute to the same VRAM leak chain. Fixing this would require changing to `WeakCosmicSurface`.

**Fix summary (all cosmic-comp, no smithay changes):**

1. Add `impl IsAlive for MinimizedWindow` (prerequisite for all other fixes):
   - File: `src/shell/workspace.rs` (near existing `impl IsAlive for FullscreenSurface`)
   - Match all three variants (`Fullscreen`, `Floating`, `Tiling`), delegate to inner `surface`/`window.alive()`

2. Fix `Workspace::unmap_surface()` — only matches `Fullscreen`, skips `Floating`/`Tiling`:
   - File: `src/shell/workspace.rs:674`
   - Change position search to use `active_window()` for all variants

3. Add `minimized_windows.retain(|m| m.alive())` to `Workspace::refresh()`:
   - File: `src/shell/workspace.rs:445`

4. Fix `WorkspaceSet::refresh()` — only refreshes active workspace, dead entries on non-active workspaces accumulate forever:
   - File: `src/shell/mod.rs:597`
   - Add loop over non-active workspaces: `workspace.minimized_windows.retain(|m| m.alive())`

5. Add cleanup for `WorkspaceSet.minimized_windows` (sticky layer) which has zero cleanup:
   - File: `src/shell/mod.rs:362`
   - Add `self.minimized_windows.retain(|m| m.alive())` to `WorkspaceSet::refresh()`

**Probable VRAM leak chain (same as main leak, different entry point):**
```
minimized_windows Vec (never cleaned for dead surfaces)
  -> MinimizedWindow::Floating/Tiling { window: CosmicMapped }
    -> CosmicSurface -> Window(Arc<WindowInner>)      <- keeps Arc refcount > 0
      -> ToplevelSurface { wl_surface, shell_surface }
        -> WlSurface handles alive
          -> SurfaceUserData alive (wayland-server 0.31.x)
            -> data_map alive
              -> Arc<Mutex<MultiTextureInternal>> alive -> GPU textures trapped
```

### Bug 1: Workspace::unmap_surface() only checks Fullscreen minimized
**File:** `src/shell/workspace.rs:674`

```rust
// Only matches Fullscreen, skips Floating/Tiling:
if let MinimizedWindow::Fullscreen { surface: s, .. } = m { s == surface } else { false }
```

**Full leak path:** `toplevel_destroyed()` → `Shell::unmap_surface()` (`src/shell/mod.rs:2881`) → iterates WorkspaceSets → calls `workspace.unmap_surface()` (`src/shell/workspace.rs:653`) → line 674 only matches `MinimizedWindow::Fullscreen` → Floating/Tiling variants return `false` → falls through to `element_for_surface()` at line 691 which searches floating/tiling layers but NOT `minimized_windows` → returns `None` → dead MinimizedWindow entry stays in Vec forever.

**Proposed fix:** Change the position search at line 674 to check all variants via `active_window()`, then handle all variants in the removal block:

```rust
if let Some(pos) = self.minimized_windows.iter().position(|m| {
    &m.active_window() == surface
}) {
    let minimized = self.minimized_windows.remove(pos);
    minimized.active_window().set_minimized(false);
    return Some((minimized.active_window(), match minimized {
        MinimizedWindow::Fullscreen { previous, .. } => {
            WorkspaceRestoreData::Fullscreen(previous)
        }
        MinimizedWindow::Floating { previous, .. } => {
            WorkspaceRestoreData::Floating(Some(previous))
        }
        MinimizedWindow::Tiling { previous, .. } => {
            WorkspaceRestoreData::Tiling(Some(previous))
        }
    }));
}
```

### Bug 2: WorkspaceSet::refresh() only refreshes active workspace
**File:** `src/shell/mod.rs:597-598`

```rust
self.workspaces[self.active].refresh();  // ONLY active workspace refreshed
```

`WorkspaceSet::refresh()` only calls `self.workspaces[self.active].refresh()` — non-active workspaces get zero cleanup. Dead fullscreen surfaces AND dead minimized windows on non-active workspaces accumulate forever.

**Proposed fix:** Add a lightweight loop in `WorkspaceSet::refresh()` over non-active workspaces that only calls `workspace.minimized_windows.retain(|m| m.alive())` (avoids full refresh overhead on non-active workspaces):

```rust
// After the active workspace refresh:
for (i, workspace) in self.workspaces.iter_mut().enumerate() {
    if i != self.active {
        workspace.minimized_windows.retain(|m| m.alive());
    }
}
```

### Bug 3: No alive() check for minimized_windows
**Files:** `src/shell/workspace.rs:445-449`, `src/shell/mod.rs:578-601`

`Workspace::refresh()` checks `fullscreen` (`take_if`), `floating_layer` (`.refresh()`), and `tiling_layer` (`.refresh()`) — but NOT `minimized_windows`. `WorkspaceSet::refresh()` also doesn't check its own `minimized_windows` (sticky layer). No `impl IsAlive for MinimizedWindow` exists in the codebase.

**Proposed fix (prerequisite for other fixes):**

Add `impl IsAlive for MinimizedWindow` (near existing `impl IsAlive for FullscreenSurface` at `src/shell/workspace.rs:223`):

```rust
impl IsAlive for MinimizedWindow {
    fn alive(&self) -> bool {
        match self {
            MinimizedWindow::Fullscreen { surface, .. } => surface.alive(),
            MinimizedWindow::Floating { window, .. } => window.alive(),
            MinimizedWindow::Tiling { window, .. } => window.alive(),
        }
    }
}
```

Then add cleanup to `Workspace::refresh()` (`src/shell/workspace.rs:445`):

```rust
pub fn refresh(&mut self) {
    self.fullscreen.take_if(|w| !w.alive());
    self.floating_layer.refresh();
    self.tiling_layer.refresh();
    self.minimized_windows.retain(|m| m.alive());  // NEW
}
```

### Bug 4: WorkspaceSet.minimized_windows (sticky) has no cleanup
**File:** `src/shell/mod.rs:362, 578-601`

`WorkspaceSet` has its own `minimized_windows: Vec<MinimizedWindow>` (line 362) for sticky layer minimized windows. This Vec is never checked for dead surfaces — `WorkspaceSet::refresh()` calls `self.sticky_layer.refresh()` but NOT `self.minimized_windows.retain(...)`.

**Proposed fix:** Add to `WorkspaceSet::refresh()`:

```rust
self.sticky_layer.refresh();
self.minimized_windows.retain(|m| m.alive());  // NEW: sticky minimized
```

## Merging Upstream

### Recommended: WeakWindow approach

1. Merge [smithay @ weak_window](https://github.com/Smithay/smithay/compare/master...MartinKavik:smithay:weak_window) — adds `WeakWindow` type (1 file, ~25 lines)
2. Merge [cosmic-comp @ weak_window](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:weak_window) — stores weak references in `ToplevelHandleState` (3 files)
3. Also merge the shader cache and activation token fixes from [cosmic-comp @ fix_vram_leak](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:fix_vram_leak) — these are separate leaks not addressed by `WeakWindow`

### Alternative: quick fix only (no smithay changes)

1. Merge [cosmic-comp @ fix_vram_leak](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:fix_vram_leak) — explicitly clears stale refs + fixes shader cache and activation token leaks
2. This is proven and tested but requires remembering to clear references when adding new handle types in the future

### Upstream coordination

- Coordinate with cmeissl (already working on [PR #1921](https://github.com/Smithay/smithay/pull/1921)) — his defensive API changes prevent compositors from accidentally holding dead surface references, complementary to the `WeakWindow` fix
- My smithay workaround branch (`fix_vram_leak`) that clears `MultiTextureInternal` in the destruction hook is NOT recommended for merge — it breaks animations, but it proved the theory

## Test Environment

| Component | Details |
|-----------|---------|
| OS | Pop!_OS 24.04 LTS |
| Kernel | 6.18.7-76061807-generic |
| CPU | Intel Core i7-9700K @ 3.60GHz (8 cores) |
| RAM | 48 GB DDR4 |
| GPU | NVIDIA GeForce RTX 2070 (8 GB VRAM) |
| Driver | 580.126.09 |

## Measured Impact

Tested on the hardware above, 5 cycles of 20 cosmic-term windows each.

**Without fix:** VRAM grows ~97 MB per cycle (~4.8 MB per window), accumulating indefinitely.

**With fix:** VRAM stays flat across all cycles.

## Testing

Two scripts are included for reproducing and verifying the fix. Defaults work on Pop!_OS with NVIDIA GPU, root + seatd.

### Prerequisites

1. Build cosmic-comp: `cargo build --release` in the cosmic-comp repo
2. Switch to a TTY first (e.g. Ctrl+Alt+F3) — do not run from within a desktop session
3. NVIDIA GPU with `nvidia-smi` available

### `cosmic-debug.sh` — Start/stop the debug compositor

```bash
# Start: stops desktop, launches custom cosmic-comp on KMS
./cosmic-debug.sh start

# Stop: kills compositor, restores desktop
./cosmic-debug.sh stop
```

| Env var | Default | Description |
|---------|---------|-------------|
| `COSMIC_COMP_BIN` | `~/repos/cosmic-comp/target/release/cosmic-comp` | Path to binary |
| `LOG_FILE` | `/tmp/cosmic-debug.log` | Log output |
| `RUST_LOG` | `info,smithay=info` | Log filter |
| `LIBSEAT_BACKEND` | `seatd` | Seat backend |

### `cosmic-vram-test.sh` — Automated VRAM leak test

Run from a terminal inside the `cosmic-debug.sh` session:

```bash
# Default: 5 cycles of 20 windows
./cosmic-vram-test.sh

# Custom
CYCLES=3 WINDOWS=30 ./cosmic-vram-test.sh
```

| Env var | Default | Description |
|---------|---------|-------------|
| `CYCLES` | `5` | Number of open/close cycles |
| `WINDOWS` | `20` | Windows per cycle |
| `OPEN_CMD` | `cosmic-term` | App to launch |
| `SLEEP_OPEN` | `5` | Seconds after opening |
| `SLEEP_CLOSE` | `5` | Seconds after closing |
| `MAX_VRAM_MB` | `5000` | Safety abort threshold (0 = disabled) |
| `COMPOSITOR_LOG` | `/tmp/cosmic-debug.log` | Compositor log path (for smithay stats) |

**Expected output (fixed):** VRAM delta stays flat across cycles, prints `PASS`.

**Broken output:** VRAM delta grows linearly (~4.8 MB per cosmic-term window per cycle), prints `FAIL`.
