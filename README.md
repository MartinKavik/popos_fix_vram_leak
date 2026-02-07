# Pop!_OS VRAM Leak Fix

Fixes a VRAM leak in the COSMIC compositor where GPU texture memory is never reclaimed when windows are closed. On an NVIDIA RTX 2070, this leaks ~4.8 MB of VRAM per cosmic-term window, accumulating indefinitely. Also fixes two smaller CPU RAM leaks (shader caches and activation tokens).

## Forked Repository

- **cosmic-comp:** [github.com/MartinKavik/cosmic-comp @ fix_vram_leak](https://github.com/MartinKavik/cosmic-comp/tree/fix_vram_leak) — [diff vs upstream master](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:fix_vram_leak)

No smithay changes required — the fix is entirely in cosmic-comp.

## Overview

### 1. VRAM Leak — ToplevelHandleState.window never cleared (cosmic-comp)

**This is the main fix.** When a window is destroyed, cosmic-comp's `remove_toplevel()` sends `closed` events to protocol clients and removes the window from its `toplevels` Vec, but never clears the `window: Option<CosmicSurface>` field in each `ZcosmicToplevelHandleV1` handle's user data (`ToplevelHandleState`).

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

**Fix:** Set `handle_state.window = None` in both `remove_toplevel()` and `refresh()` (dead-window safety-net path) in `src/wayland/protocols/toplevel_info.rs`. This drops the `CosmicSurface` clone immediately, allowing `Arc<WindowInner>` refcount to reach 0, which drops all `WlSurface` handles, which drops `SurfaceUserData` and its `data_map`, which drops `MultiTextureInternal` and frees GPU textures.

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

## How We Diagnosed the Leak

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

## Known Remaining Bugs (not causing VRAM leaks, but should be fixed)

### Bug: Workspace::unmap_surface() only checks Fullscreen minimized
**File:** `src/shell/workspace.rs:674`

```rust
// Only matches Fullscreen, skips Floating/Tiling:
if let MinimizedWindow::Fullscreen { surface: s, .. } = m { s == surface } else { false }
```

Floating/Tiling minimized windows at workspace level are never removed on destroy. No `alive()` safety-net exists anywhere for minimized_windows.

### Bug: WorkspaceSet::refresh() only refreshes active workspace
**File:** `src/shell/mod.rs:583-606`

Dead surfaces on non-active workspaces are never cleaned.

### Bug: No alive() check for minimized_windows
Neither `Workspace::refresh()` nor `WorkspaceSet::refresh()` retains minimized_windows by alive().

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

## Merging Upstream

The fix is entirely in cosmic-comp — no smithay changes needed.

1. Merge the [cosmic-comp fix](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:fix_vram_leak)

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
