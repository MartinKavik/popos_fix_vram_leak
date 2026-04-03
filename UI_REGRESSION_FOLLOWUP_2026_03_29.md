# UI Regression Follow-up 2026-03-29

## Scope

This pass intentionally stayed inside:

- `~/repos/cosmic-comp-background-window-rules`

No new portal code was installed.
No `xdg-desktop-portal-cosmic` rollout happened in this pass.

## Reason for This Follow-up

After rebooting onto the previous compositor build, the session still showed:

- screenshot tool failing
- new windows opening in broken tiling/layout states
- persistent `Coalescing redundant schedule_render requests`
- recurring `Cross-output animation was still globally visible to this surface thread`

The immediate goal of this pass was to remove the most likely regressions introduced during the recent correctness rollback and workspace-rule work, while keeping the underlying long-session lag fixes.

## Changes Made

### 1. Removed post-map background-rule remap

File:

- `/home/martinkavik/repos/cosmic-comp-background-window-rules/src/shell/mod.rs`

Change:

- `remap_for_window_behavior_rule(...)` no longer unmaps an already mapped window and re-maps it elsewhere on later `title_changed` / `app_id_changed` events.
- It now only remaps still-pending windows.

Why:

- The old path could map a window into the focused workspace first, disturb the tiling layout there, and then move it after metadata arrived.
- That directly matched the reported "opens in the current workspace first and breaks layout for a moment" failure mode.

### 2. Reverted broad hidden-surface redraw scheduling

File:

- `/home/martinkavik/repos/cosmic-comp-background-window-rules/src/wayland/handlers/compositor.rs`

Change:

- Commit scheduling was narrowed back to the known-good rule:
  - schedule redraw for `visible_output_for_surface(...)`
  - otherwise only schedule for `workspace_for_surface(...)` when that output is actually animating
- The broader `render_output_for_surface(...)` fallback is no longer used for normal commit scheduling.

Why:

- The broader fallback was too aggressive and could schedule redraws for hidden, minimized, or background-owned surfaces.
- That matched the nonstop `schedule_render` coalescing and likely contributed to UI churn.

### 3. Restored visible-only corner-radius redraw lookup

File:

- `/home/martinkavik/repos/cosmic-comp-background-window-rules/src/wayland/handlers/corner_radius.rs`

Change:

- Switched back from `owning_output_for_surface(...)` to `visible_output_for_surface(...)`.

Why:

- Hidden/workspace-owned surfaces should not wake outputs just because a corner-radius related state changed.

### 4. Backed out the speculative per-frame output-capture wakeup

File:

- `/home/martinkavik/repos/cosmic-comp-background-window-rules/src/wayland/handlers/image_copy_capture/mod.rs`

Change:

- Output capture now schedules a redraw only when the screencopy queue transitions from empty to non-empty.
- It no longer requests a redraw for every frame request.

Why:

- The per-frame wakeup was added during the later rollback attempt.
- It increased render churn but did not restore screenshot correctness.

### 5. Restored overload-based screencopy skipping behavior

File:

- `/home/martinkavik/repos/cosmic-comp-background-window-rules/src/backend/kms/surface/mod.rs`

Change:

- Restored the bounded overload skip path from the lag-fix compositor:
  - `MAX_SCREENCOPY_SKIP`
  - `SCREENCOPY_FORCE_DELAY_MS`
  - overload skip only until bounded by skip count or frame age

Why:

- The temporary "always serve screencopy unless mirroring" change was part of the speculative rollback pass, not the original lag-fix baseline.
- This restores the capture behavior to the known-good lag-fix branch instead of the later experiment.

### 6. Kept the long-session lag fixes

Files unchanged in intent from the lag-fix port:

- `src/backend/kms/surface/timings.rs`
- `src/backend/kms/surface/mod.rs`
- `src/state.rs`
- `src/lib.rs`
- related render / retry / throttling paths

Still retained:

- NVIDIA near-vblank timer fix
- render request coalescing
- DRM retry / recovery handling
- commit lock split
- throttled animation/update loop
- active capture tracking

## Build and Install

Built from:

- `~/repos/cosmic-comp-background-window-rules`

Installed binary:

- `/usr/bin/cosmic-comp`

Installed hash:

- `80c08d5c66f1b4b77ab4e84082461acf6d6d8bac2bc636c9568b255f665af21f`

At install time, the running compositor was still the previous deleted binary:

- running `/proc/2159/exe` hash: `7ce23c8cf0ed2761656063d314ec815f34259902087d4a76fc7984b34de111ee`

That means this pass is installed but not yet active in the current login session.

## Required Next Step

Start a fresh COSMIC session so the running compositor stops using:

- `/usr/bin/cosmic-comp (deleted)`

and starts using:

- `/usr/bin/cosmic-comp`

## First Checks After Fresh Login

- Verify screenshot tool startup before touching any workspace-rule flow.
- Verify a newly opened tiled window does not briefly split the currently focused workspace and then move away.
- Check whether `journalctl -b _COMM=cosmic-comp -o cat` still floods:
  - `Coalescing redundant schedule_render requests`
  - `Cross-output animation was still globally visible to this surface thread`
- Check whether `Visual commit could not be mapped to a render output` still appears during normal desktop use.
