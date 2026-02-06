# Pop!_OS VRAM Leak Fix

Fixes a VRAM leak in the COSMIC compositor where GPU texture memory is never reclaimed when windows are closed. On an NVIDIA RTX 2070, this leaks ~4.8 MB of VRAM per cosmic-term window, accumulating indefinitely. Also fixes two smaller CPU RAM leaks (shader caches and activation tokens).

## Forked Repositories

- **Smithay (the critical fix):** [github.com/MartinKavik/smithay @ fix_vram_leak](https://github.com/MartinKavik/smithay/tree/fix_vram_leak) — [diff vs upstream master](https://github.com/Smithay/smithay/compare/master...MartinKavik:smithay:fix_vram_leak)
- **cosmic-comp:** [github.com/MartinKavik/cosmic-comp @ fix_vram_leak](https://github.com/MartinKavik/cosmic-comp/tree/fix_vram_leak) — [diff vs upstream master](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:fix_vram_leak)

## Overview

### 1. VRAM Leak — MultiTextureInternal not cleared on surface destroy (smithay)

**This is the main fix.** When a Wayland surface is destroyed, Smithay's destruction hook calls `RendererSurfaceState::reset()`, which drops its texture references. However, `MultiTextureInternal` (stored in the surface's `data_map` via an `Arc`) retains its own texture `HashMap`.

In wayland-server 0.31.x, `SurfaceUserData` (and therefore `data_map`) stays alive as long as *any* Rust `WlSurface` handle exists — even after the client disconnects. cosmic-comp holds `WlSurface` handles beyond client disconnect, so `MultiTextureInternal` is never dropped and its GPU textures leak indefinitely.

**Fix:** In the surface destruction hook (alongside the existing `reset()` call), also clear `MultiTextureInternal`'s texture `HashMap` through the `data_map` Arc reference. This ensures GPU resources are freed immediately regardless of Arc lifetime.

**Impact:** ~4.8 MB VRAM leaked per cosmic-term window (~97 MB per 20-window cycle). With the fix, VRAM stays flat.

**Why clear the internals instead of dropping the Arc?** The Arc lives in `SurfaceData.data_map`, which is a `UserDataMap` — an append-only type map with no `remove()` method. The Arc is trapped there until `SurfaceData` itself drops, which won't happen because cosmic-comp holds `WlSurface` handles after client disconnect. The "proper" fix would be adding `remove()` to `UserDataMap` or changing wayland-server to drop `SurfaceData` eagerly, but both are much larger changes to foundational types with concurrency implications. Clearing the textures HashMap is safe because an empty HashMap is a valid state (same as before first import), and no code accesses it after the destruction hook fires.

**Files changed:**
- `src/backend/renderer/multigpu/mod.rs` — added `clear_textures()` method on `MultiTextureInternal`
- `src/backend/renderer/utils/wayland.rs` — call `clear_textures()` in the destruction hook

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

| Configuration | Smithay fix | Shader fix | Total VRAM delta | Per-cycle delta | Result |
|--------------|------------|-----------|-----------------|----------------|--------|
| A. No fixes (baseline) | off | off | +483 MB | ~97 MB/cycle | FAIL |
| B. Smithay fix only | **on** | off | -6 MB | 0 MB/cycle | PASS |
| C. Shader fix only | off | **on** | +471 MB | ~94 MB/cycle | FAIL |
| D. All fixes | **on** | **on** | -2 MB | 0 MB/cycle | PASS |

### Fix 1: MultiTextureInternal clear (smithay)
Saves **~97 MB per 20-window cycle** (~4.8 MB per cosmic-term window). This is the entire VRAM fix — configs B and D are flat, while A and C leak identically.

### Fix 2: Shader cache cleanup (cosmic-comp)
**No measurable VRAM impact.** Configs A and C show identical VRAM growth (~483 vs ~471 MB). The shader caches store CPU-side data only (shader parameters, geometry, uniforms) — not GPU textures. This fix prevents unbounded CPU RAM growth, not VRAM.

### Fix 3: Activation token cleanup (cosmic-comp)
CPU RAM only — not measurable via GPU VRAM.

## Merging Upstream

The **smithay fix must be merged first** — the cosmic-comp changes depend on it.

1. Merge the [smithay fix](https://github.com/Smithay/smithay/compare/master...MartinKavik:smithay:fix_vram_leak) into upstream smithay
2. Update cosmic-comp's `Cargo.toml`: replace both local `path` overrides with a git rev pointing to the merged smithay commit:
   ```toml
   [patch.crates-io]
   smithay = { git = "https://github.com/smithay/smithay.git", rev = "<merged-commit-hash>" }
   ```
   Remove the `[patch."https://github.com/smithay/smithay.git"]` section entirely (it's only needed for local path overrides)
3. Merge the [cosmic-comp fix](https://github.com/pop-os/cosmic-comp/compare/master...MartinKavik:cosmic-comp:fix_vram_leak)

## Building (local development)

The cosmic-comp fork's `Cargo.toml` currently uses `[patch]` sections to point `smithay` to a local path (`../smithay`) for development and testing.

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

### Measuring per-fix VRAM savings

To measure each fix's individual VRAM impact, build 4 configurations with different fixes enabled/disabled and test each one.

**Configurations:**

| Config | Smithay branch | Shader fix (cosmic-comp) | What's tested |
|--------|---------------|-------------------------|---------------|
| A | `master` | disabled | No fixes (baseline) |
| B | `fix_vram_leak` | disabled | Smithay texture fix only |
| C | `master` | enabled | Shader cache fix only |
| D | `fix_vram_leak` | enabled | All fixes |

**How to toggle fixes:**

- **Smithay texture fix:** Switch branch in the smithay repo between `master` and `fix_vram_leak`
- **Shader cache fix:** Comment/uncomment the cleanup block in `cosmic-comp/src/backend/render/mod.rs` (inside `render_output()`):
  ```rust
  // Comment out these 2 lines to disable:
  let pending_cleanup = {
      let mut shell_guard = shell.write();
      std::mem::take(&mut shell_guard.pending_shader_cleanup)
  };
  remove_from_shader_caches(renderer, &pending_cleanup);
  ```
- **Activation token fix:** CPU memory only — no VRAM impact, no need to toggle

**Build and test each configuration:**

```bash
# 1. Switch smithay branch
cd ~/repos/smithay && git checkout master   # or fix_vram_leak

# 2. Toggle shader fix in cosmic-comp (edit the file above)

# 3. Build
cd ~/repos/cosmic-comp && cargo build --release

# 4. Save the binary (optional — avoids rebuilding)
cp target/release/cosmic-comp ~/repos/popos_fix_vram_leak/builds/cosmic-comp-A

# 5. Switch to TTY (Ctrl+Alt+F3), start compositor, run test
COSMIC_COMP_BIN=~/repos/popos_fix_vram_leak/builds/cosmic-comp-A ./cosmic-debug.sh start
# Inside compositor terminal:
./cosmic-vram-test.sh | tee results/results-A.txt
```

Repeat for configs B, C, D. Compare the "Total delta" line from each to see per-fix savings.
