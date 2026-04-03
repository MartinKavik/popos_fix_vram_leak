# UI Correctness Rollback Follow-Up (March 29, 2026)

## Why this pass was needed

After the long-session lag fixes were ported onto `cosmic-comp-background-window-rules` and installed, the next reboot exposed correctness regressions:

- tiled layout/grid placement looked broken and left stale rectangles
- the Super+W workspace overview stopped working reliably
- screenshot capture still failed

The strongest runtime signals were:

- repeated compositor warnings:
  - `Visual commit could not be mapped to a render output`
  - `Visible commits could not be mapped to an output`
  - `Cross-output animation was still globally visible to this surface thread`
- repeated portal/capture failures:
  - `Screenshot output count mismatch: 0 != 2`
  - `Screenshot outputs: []`

## What changed

### `cosmic-comp-background-window-rules`

Files updated:

- `src/shell/mod.rs`
- `src/wayland/handlers/compositor.rs`
- `src/wayland/handlers/image_copy_capture/mod.rs`
- `src/backend/kms/surface/mod.rs`

Behavior changes:

- Added a broader `render_output_for_surface(...)` lookup so redraw scheduling can fall back to the owning workspace/output instead of only the currently visible active workspace.
- Changed compositor commit handling to use that broader render-output lookup before declaring a visible commit unmapped.
- Removed the edge-triggered output-capture wakeup optimization. Output screencopy now schedules a render on every frame request.
- Disabled overload-based screencopy skipping for non-mirrored outputs in this pass. Pending screencopy frames are served correctness-first.

### `cosmic-workspaces-epoch`

Files updated:

- `src/backend/wayland/mod.rs`
- `src/backend/wayland/capture.rs`
- `src/backend/wayland/screencopy.rs`

Behavior changes:

- Workspace capture filtering no longer drops a workspace just because its output list is temporarily empty.
- Screencopy session creation failure is now logged instead of panicking.
- Wayland flush failure during screencopy now tears down that session cleanly instead of panicking the overview client.

## Build verification

Verified successfully:

- `cargo check -p cosmic-comp` in `~/repos/cosmic-comp-background-window-rules`
- `cargo build --release -p cosmic-comp` in `~/repos/cosmic-comp-background-window-rules`
- `cargo check` in `~/repos/cosmic-workspaces-epoch`
- `cargo build --release` in `~/repos/cosmic-workspaces-epoch`

## Installed binaries

Installed at `2026-03-29T14:38:36+02:00`.

### `cosmic-comp`

- release build: `7ce23c8cf0ed2761656063d314ec815f34259902087d4a76fc7984b34de111ee`
- installed `/usr/bin/cosmic-comp`: `7ce23c8cf0ed2761656063d314ec815f34259902087d4a76fc7984b34de111ee`
- currently running `/proc/2204/exe`: `cbdc6ef0dc5358631a34fec267e350ce408bb8e12eb2b219503619cf5abb3d26`

### `cosmic-workspaces`

- release build: `0f5734b22f6b371fc654bc029720633895203fe78abc84cad9beefb70327d5f6`
- installed `/usr/bin/cosmic-workspaces`: `0f5734b22f6b371fc654bc029720633895203fe78abc84cad9beefb70327d5f6`
- currently running `/proc/2359/exe`: `2729b11edc4ac5fa8e9ad0aea68d3d84a5a7905996e20e7308b85e52d4afa378`

## Rollout note

The currently running session is still on the older March 29 executables started around:

- `cosmic-comp`: `Sun Mar 29 13:39:46 2026`
- `cosmic-workspaces`: `Sun Mar 29 13:39:47 2026`

A fresh login or reboot is required before the fixes above can be evaluated.
