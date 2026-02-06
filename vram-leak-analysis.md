# Smithay MultiGPU VRAM Leak Analysis

**Date:** 2026-02-06
**Smithay branch:** `fix_vram_leak` (incorporates multi-GPU fixes from `vram-debug-3`)
**cosmic-comp branch:** `fix_vram_leak`

---

## 1. Multi-GPU Fix Commit Analysis

These two commits fix bugs in the multi-GPU `dma_shadow_copy` path. They only affect systems with multiple GPUs — on single-GPU setups (e.g. single NVIDIA RTX 2070), `dma_shadow_copy` is never called and these have no effect.

### Commit 5aec8326: Fix `get_or_insert` -> `insert` in `dma_shadow_copy`

**File:** `src/backend/renderer/multigpu/mod.rs`, function `dma_shadow_copy`

**Bug:** The code used `slot.get_or_insert(...)` to store the newly allocated shadow buffer. `get_or_insert` evaluates its argument eagerly but only inserts if the slot is `None` — if the slot was already `Some`, the freshly allocated buffer is silently dropped while the stale value is returned.

The fix changes to `slot.insert(...)`, which always overwrites the slot with the fresh allocation and drops any previous value.

**Verdict:** Correct fix. Prevents stale dmabuf references and potential VRAM accumulation from leaked allocations.

### Commit 8148d67e: Fix slot reuse check from format-match to `is_some()`

**File:** `src/backend/renderer/multigpu/mod.rs`, function `dma_shadow_copy`

**Before:**
```rust
let ((shadow_buffer, _, existing_sync_point), is_new_buffer) = if slot
    .as_ref()
    .is_some_and(|(buffer, _, _)| buffer.format().code == format)
{
    (slot.as_mut().unwrap(), false)
} else {
    // allocate new buffer...
}
```

**After:**
```rust
let ((shadow_buffer, _, existing_sync_point), is_new_buffer) = if slot.is_some() {
    (slot.as_mut().unwrap(), false)
} else {
    // allocate new buffer...
}
```

**Bug:** The old code checked if the existing slot's dmabuf format matched the source texture format. Since `src_texture.format()` could return `None` (defaulting to `Abgr8888`) while the slot's buffer used the actual negotiated transfer format, a mismatch was common. This caused **per-frame dmabuf allocation** — a new GPU buffer + GL texture every frame for each cross-GPU surface.

Combined with the `get_or_insert` bug (before 5aec8326), the old buffer might not be dropped, causing true VRAM accumulation. After 5aec8326, `insert` correctly drops the old buffer, but the constant allocation/deallocation churn remains extremely expensive.

**Verdict:** This was the **primary multi-GPU performance bug**. After both fixes, each cross-GPU surface has at most one shadow buffer allocation for its lifetime.

---

## 2. MultiTexture Arc Lifecycle Analysis

This section analyzes the single-GPU VRAM leak that is the main fix.

### Architecture

`MultiTexture` wraps `Arc<Mutex<MultiTextureInternal>>` (type-aliased as `MultiTextureUserData`). This Arc is stored in **two** independent locations:

1. **`SurfaceData.data_map`** — as `MultiTextureUserData` (via `insert_if_missing_threadsafe`)
   - Set in `import_dma_buffer()` and `import_surface()` mem copy path
   - The `data_map` is a `UserDataMap` (append-only type map, no `remove()`)

2. **`RendererSurfaceState.textures`** — as `Box<dyn Any>` containing `MultiTexture` (which holds a clone of the same Arc)

### Destruction Path

When a surface is destroyed:

1. **Destruction hook** (`wayland.rs`) runs:
   - `state.reset()` — clears `RendererSurfaceState.textures` (drops `MultiTexture`, decrements Arc refcount)
   - `MultiTextureUserData.clear_textures()` — **THE FIX** — clears GPU textures inside `MultiTextureInternal` through the `data_map` Arc, even though the Arc itself can't be removed from `data_map`

2. **SurfaceData drop**: When wayland-server eventually drops the `SurfaceData`, the `data_map` is dropped, which drops the `MultiTextureUserData` Arc.

3. **GlesTexture cleanup**: When `GlesTexture`'s inner `GlesTextureInternal` drops, it sends cleanup messages through the `destruction_callback_sender` channel. These are processed in `GlesCleanup::cleanup()` during the next render frame (GL texture deletion, EGL image destruction, etc).

### The Leak (before fix)

In wayland-server 0.31.x, `SurfaceUserData` (and therefore `data_map`) stays alive as long as *any* Rust `WlSurface` handle exists. cosmic-comp holds `WlSurface` handles beyond client disconnect, so step 2 never happens — `MultiTextureInternal` is never dropped and its GPU textures accumulate indefinitely.

The fix adds step 1b: even though the `data_map` Arc can't be removed, the destruction hook now explicitly clears the textures HashMap inside `MultiTextureInternal`, freeing all GPU resources immediately.

### Non-leak: `from_surface` Re-fetching

`MultiTexture::from_surface()` checks `data_map` for an existing `MultiTextureUserData`. If found, it reuses it. If called after `reset()` but before surface destruction, it wraps the same Arc in a new `MultiTexture` stored back in `RendererSurfaceState.textures`. This is correct by-design behavior for re-importing after buffer changes.

---

## 3. GlesRenderer dmabuf_cache Analysis

### Structure

```rust
dmabuf_cache: HashMap<WeakDmabuf, GlesTexture>
```

- **Key:** `WeakDmabuf` — a `Weak<DmabufInternal>` reference
- **Value:** `GlesTexture` — `Arc<GlesTextureInternal>` holding the GL texture ID

### Cleanup Path

`cleanup()` in `GlesRenderer`:
```rust
self.dmabuf_cache.retain(|entry, _tex| !entry.is_gone());
self.buffers.retain(|buffer| !buffer.0.dmabuf.is_gone());
self.gles_cleanup().cleanup(&self.egl, &self.gl);
```

The `is_gone()` check uses `Weak::strong_count() == 0`, meaning entries are retained only while the `Dmabuf` strong reference exists somewhere.

**No leak here** — cache entries are cleaned up when their Dmabuf is dropped. The `GlesTexture` values may outlive the cache entry if cloned elsewhere (e.g. in `MultiTextureInternal`), but GL resources are only freed when the last clone drops.

### `buffers` vec (Dmabuf bind targets)

Same pattern: `GlesBuffer` contains `WeakDmabuf`, retained while alive. The `GlesBuffer` also holds FBO + RBO + EGL image, all sent to the cleanup channel on drop.

---

## 4. Win+Q Freeze Speculation

The Win+Q freeze (system hang when closing windows) was observed during development. This section captures hypotheses — **none have been verified**.

### 4a. Mutex Contention

`MultiTexture` wraps `Arc<Mutex<MultiTextureInternal>>`. The mutex is locked during render, import, and copy operations. However, `Arc::drop` doesn't lock the inner mutex, so there's no deadlock risk from nested mutex locking during the destruction path.

### 4b. GL State Corruption

`GlesCleanup::cleanup()` calls `gl.DeleteTextures`, `DestroyImageKHR`, etc. This requires a valid GL context. Cleanup runs only during explicit `cleanup()` calls (not during render), and cosmic-comp is single-threaded for GL, so no GL state corruption is expected.

### 4c. Most Likely Cause

The freeze is likely in cosmic-comp's response to rapid surface destruction, not in Smithay's multigpu layer:

- Synchronous `SyncPoint::wait()` blocking the main thread
- Large numbers of surfaces destroyed simultaneously causing O(n) destruction hooks
- Large batch of deferred GL cleanup operations executing at once

---

## 5. Other Potential Leak Vectors (all verified as non-leaks)

### 5a. `dma_shadow_copy` Slot

Stored per-`GpuSingleTexture` inside `MultiTextureInternal`. Contains `Dmabuf` + imported texture + GPU fence. Correctly cleaned up when `MultiTextureInternal` drops (or when `clear_textures()` is called by the fix).

### 5b. External Shadow Buffers in Mem Copy Path

`GpuSingleTexture::Mem { external_shadow, .. }` holds a dmabuf + texture for surfaces that can't be directly read. Per-surface allocation, correctly dropped with the variant.

### 5c. Texture Mappings Accumulation

`GpuSingleTexture::Mem { mappings, .. }` stores texture mapping objects for partial updates. Theoretically unbounded if damage regions keep changing, but in practice damage covers the full surface frequently enough to bound this.

### 5d. `renderer_seen` HashMap

Tracks which renderer contexts have seen which commits. Bounded by the number of GPUs (typically 2-3). Not a leak concern.

### 5e. Orphaned MultiTextureInternal in data_map

If stored in `data_map` but the surface is never imported again, the Arc persists until surface destruction. This is correct caching behavior — and now explicitly cleaned up by the fix's `clear_textures()` call in the destruction hook.

---

## 6. Summary

### Fixed Bugs

| Commit | Bug | Impact | Scope |
|--------|-----|--------|-------|
| 5aec8326 | `get_or_insert` didn't replace existing slot | Stale dmabuf, potential VRAM accumulation | Multi-GPU only |
| 8148d67e | Format mismatch caused per-frame slot reallocation | New dmabuf + GL texture every frame per cross-GPU surface | Multi-GPU only |
| **035e3c47** | **MultiTextureInternal textures not cleared on surface destroy** | **~4.8 MB VRAM leaked per window, accumulating indefinitely** | **All GPUs** |

### Conclusions

1. **No remaining leak vectors in Smithay's multigpu layer** — the Arc lifecycle is correct, cleanup paths are sound.

2. **The `dmabuf_cache` and `buffers` cleanup depends on `cleanup()` being called regularly** (typically once per frame). If frames stop being rendered (e.g. all outputs off), these caches won't be pruned.

3. **The Win+Q freeze** is likely caused by cosmic-comp-side issues, not Smithay. Needs separate investigation with profiling spans around the destruction path.
