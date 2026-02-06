# Pop!_OS VRAM Leak Fix

Fixes a VRAM leak in the COSMIC compositor where GPU texture memory is never reclaimed when windows are closed. On an NVIDIA RTX 2070, this leaks ~3 MB of VRAM per window, accumulating indefinitely.

## Forked Repositories

- **Smithay (the critical fix):** [github.com/MartinKavik/smithay](https://github.com/MartinKavik/smithay) — branch `fix_vram_leak`
- **cosmic-comp:** [github.com/MartinKavik/cosmic-comp](https://github.com/MartinKavik/cosmic-comp) — branch `fix_vram_leak`

## Overview

### 1. VRAM Leak — MultiTextureInternal not cleared on surface destroy (smithay)

**This is the main fix.** When a Wayland surface is destroyed, Smithay's destruction hook calls `RendererSurfaceState::reset()`, which drops its texture references. However, `MultiTextureInternal` (stored in the surface's `data_map` via an `Arc`) retains its own texture `HashMap`.

In wayland-server 0.31.x, `SurfaceUserData` (and therefore `data_map`) stays alive as long as *any* Rust `WlSurface` handle exists — even after the client disconnects. cosmic-comp holds `WlSurface` handles beyond client disconnect, so `MultiTextureInternal` is never dropped and its GPU textures leak indefinitely.

**Fix:** In the surface destruction hook (alongside the existing `reset()` call), also clear `MultiTextureInternal`'s texture `HashMap` through the `data_map` Arc reference. This ensures GPU resources are freed immediately regardless of Arc lifetime.

**Impact:** VRAM growth went from ~60 MB per 20-window cycle to ~3 MB (flat).

**Files changed:**
- `src/backend/renderer/multigpu/mod.rs` — added `clear_textures()` method on `MultiTextureInternal`
- `src/backend/renderer/utils/wayland.rs` — call `clear_textures()` in the destruction hook

### 2. Shader Cache Leak (cosmic-comp)

Shadow, Indicator, and Backdrop pixel shader elements are cached per-window in the EGL context's `user_data()` but never cleaned up when windows close. This leaks GPU shader element memory (smaller than the texture VRAM leak, but still grows unbounded).

**Fix:** Added `remove_from_shader_caches()` called from the render loop via a deferred `pending_shader_cleanup` queue on `Shell`.

**Files changed:**
- `src/backend/render/mod.rs` — `remove_from_shader_caches()` function and render-loop integration
- `src/backend/render/shadow.rs` — made `ShadowCache` type public
- `src/shell/mod.rs` — `pending_shader_cleanup` queue, populated during `unmap_surface()`
- `src/shell/element/mod.rs` — `Debug` impl for `CosmicMappedKey`
- `src/backend/kms/surface/mod.rs` — process pending cleanup in KMS render path

### 3. Activation Token Leak (cosmic-comp)

`pending_activations` `HashMap` entries for destroyed windows were never removed. Tokens accumulate in memory indefinitely.

**Fix:** Clean up Wayland activation tokens in `toplevel_destroyed()` and X11 tokens in `destroyed_window()`.

**Files changed:**
- `src/wayland/handlers/xdg_shell/mod.rs` — remove activation token on Wayland toplevel destroy
- `src/xwayland.rs` — remove activation token on X11 window destroy

## Testing

Two helper scripts are included for reproducing and verifying the fix on a Pop!_OS system with an NVIDIA GPU:

### `cosmic-kms-debug.sh`

Launcher script that stops the greeter, acquires DRM master, and runs a custom `cosmic-comp` binary directly on KMS. Handles session/VT management, seatd/logind backends, and cleanup.

```bash
# Start the debug compositor (from a TTY, not from within a desktop session)
cosmic-kms-debug.sh start

# Stop and restore the greeter
cosmic-kms-debug.sh stop
```

### `cosmic-vram-plateau-auto.sh`

Automated VRAM leak test. Opens N windows, snapshots VRAM, closes them, snapshots again, and repeats for multiple cycles. Reports per-cycle VRAM deltas.

```bash
# Run from a terminal within the debug compositor session
# Default: 3 cycles of 20 windows each
cosmic-vram-plateau-auto.sh

# Custom parameters
CYCLES=5 WINDOWS_TARGET=30 cosmic-vram-plateau-auto.sh
```

**Expected output (fixed):** VRAM delta stays flat across cycles (~3 MB baseline noise).

**Broken output:** VRAM delta grows linearly (~3 MB per window per cycle, never reclaimed).
