## March 30, 2026: executable-path window rules and pending-window lag follow-up

### Summary

Implemented two follow-up changes:

1. `cosmic-comp` / `cosmic-settings` / `cosmic-settings-daemon` now support matching background window rules by executable path.
2. `cosmic-comp` now has better pending-window cleanup and diagnostics to reduce redraw churn that can contribute to cursor/render lag.

### Executable-path rule matching

Added `exe_path_patterns` to `WindowBehaviorRule`.

- One non-empty line = one regex.
- Lines are OR-ed together.
- The rule still combines with other fields using AND semantics.
- Matching uses the canonical `/proc/<pid>/exe` path.
- If a rule specifies executable-path patterns and the path cannot be resolved, that rule does not match.

Implemented in:

- `~/repos/cosmic-settings-daemon/config/src/window_rules/mod.rs`
- `~/repos/cosmic-comp-background-window-rules/src/shell/mod.rs`
- `~/repos/cosmic-comp-background-window-rules/src/shell/element/surface.rs`
- `~/repos/cosmic-comp-background-window-rules/src/xwayland.rs`
- `~/repos/cosmic-comp-background-window-rules/src/wayland/handlers/xdg_shell/mod.rs`

### Settings UI support

Added executable-path support to the Background Window Rules page.

- The open-window picker now shows executable path when available.
- Selecting a live window prefills an exact escaped executable-path regex.
- Each rule now has a multiline `Executable path patterns` field.
- The tester/match view now includes executable-path information.

Implemented in:

- `~/repos/cosmic-settings/cosmic-settings/src/subscription/toplevel_windows.rs`
- `~/repos/cosmic-settings/cosmic-settings/src/pages/desktop/window_management.rs`

### Toplevel info protocol extension

Extended the local patched `cosmic-protocols` repo so toplevel-info can carry executable path:

- `unstable/cosmic-toplevel-info-unstable-v1.xml`
- `client-toolkit/src/toplevel_info.rs`

The compositor-side toplevel-info export was updated in:

- `~/repos/cosmic-comp-background-window-rules/src/wayland/protocols/toplevel_info.rs`
- `~/repos/cosmic-comp-background-window-rules/src/wayland/handlers/toplevel_info.rs`

### Pending-window cleanup and lag diagnostics

Added pending-window lifecycle cleanup and better logging in `cosmic-comp`.

- Pending windows now track creation time.
- Destroyed Wayland/X11 windows are removed from `pending_windows` before they can leak.
- Pending activations are cleared when the pending window is removed.
- Commit classification now distinguishes visible, hidden, and still-pending visual commits.
- Perf logging now includes pending-window counts and oldest pending age.
- If pending windows stay around unusually long, the compositor logs a small debug snapshot.
- Corner-radius forced-redraw warnings are suppressed for hidden or pending surfaces and only kept for genuinely visible unmapped cases.

Implemented in:

- `~/repos/cosmic-comp-background-window-rules/src/wayland/handlers/compositor.rs`
- `~/repos/cosmic-comp-background-window-rules/src/lib.rs`
- `~/repos/cosmic-comp-background-window-rules/src/wayland/handlers/corner_radius.rs`

### Important build note

The local `cosmic-protocols` XML change did not invalidate downstream proc-macro output automatically in every workspace.

Required cleanup before downstream rebuilds:

- `cargo clean -p cosmic-protocols -p cosmic-client-toolkit` in `~/repos/cosmic-settings`
- `cargo clean -p cosmic-protocols` in `~/repos/cosmic-comp-background-window-rules`

After that:

- `cargo check -p cosmic-settings` passed
- `cargo check -p cosmic-comp` passed
- release builds for both passed

### Installed binaries

Installed on March 30, 2026:

- `/usr/bin/cosmic-comp`
  - `fa7bbd58df50447e34f19781158e84f6ed7034978c77daac0aeae3a86273f527`
- `/usr/bin/cosmic-settings`
  - `f308e14cb2cd24a6e0cc807c6f1279039688c25482f0c7246dde37173ef31581`

### Running-session state at install time

The current graphical session was still running the old deleted compositor binary:

- running `cosmic-comp`: `ff98c447542bed392b170136d41dbfb214309fdcffbc6f767519f0884d3312dc`
- installed `/usr/bin/cosmic-comp`: `fa7bbd58df50447e34f19781158e84f6ed7034978c77daac0aeae3a86273f527`

So the compositor-side changes require a fresh COSMIC logout/login or reboot before testing.
