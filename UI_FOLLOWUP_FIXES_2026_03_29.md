## UI follow-up fixes installed on 2026-03-29

### Context

After the previous reboot and login, the active session was already running the newly installed
`cosmic-comp` from `background-window-rules`, but the following regressions remained:

- `Super+W` workspace overview still did not render correctly
- `cosmic-screenshot` still failed immediately
- compositor logs still showed:
  - `Visual commit could not be mapped to a render output`
  - `Mapping tiled window into a non-empty workspace`
  - `Cross-output animation was still globally visible to this surface thread`
- portal logs still showed:
  - `wl_shm#7: error 1: invalid wl_shm_pool size`

### Changes made

#### `cosmic-comp-background-window-rules`

- In `src/wayland/handlers/compositor.rs`:
  - commit scheduling now uses `render_output_for_surface(...)` in addition to
    `visible_output_for_surface(...)`
  - visual commits are no longer restricted to active-visible lookup before scheduling a redraw

- In `src/wayland/handlers/image_copy_capture/mod.rs`:
  - zero-sized toplevel screencopy sessions are now rejected instead of advertising invalid
    buffer constraints
  - zero-sized toplevel sessions are stopped at session creation time

- In `src/wayland/handlers/image_copy_capture/render.rs`:
  - zero-sized toplevel captures now fail with `BufferConstraints` and the session is removed
    instead of proceeding into an invalid SHM path

#### `cosmic-workspaces-epoch`

- In `src/backend/wayland/screencopy.rs`:
  - zero-sized screencopy `Formats.buffer_size` values are treated as invalid and the session is
    dropped instead of creating a zero-sized buffer

### Build / install

- `cargo check -p cosmic-comp`
- `cargo build --release -p cosmic-comp`
- `cargo check`
- `cargo build --release`

Installed hashes:

- `cosmic-comp`
  - release + `/usr/bin`: `afbde9356f9353664caebf5b5a91c7e25b2225b1df694640e80dd8a9dc75a25b`
  - running session before relogin: `80c08d5c66f1b4b77ab4e84082461acf6d6d8bac2bc636c9568b255f665af21f`

- `cosmic-workspaces`
  - release + `/usr/bin`: `69f578048838884f06c6394ea4dbc3ed398c9f7175363c4ac3409cefc9e5fe06`
  - running session before relogin: `8070c636f84e79ffb9f52861d9d0b4a9d9539ac745ebaadb9091946b116fe433`

### Activation boundary

These fixes are installed but not active in the current session until a fresh COSMIC login starts
the new `/usr/bin/cosmic-comp` and `/usr/bin/cosmic-workspaces`.
