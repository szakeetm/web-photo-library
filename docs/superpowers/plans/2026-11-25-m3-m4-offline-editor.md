# Milestones 3 + 4 — Offline mode, photo editor

**Goal:** M3: the app launches and browses offline (catalog replica, image cache, downloaded
albums, view-only offline mode, storage screen). M4: non-destructive editor whose preview matches
the export by construction (one WGSL pipeline run by WebGPU in the browser and by Metal on the
server), auto-enhance, edit history, exports.

**Owner decisions (2026-11-25):** do M3 then M4; editor is **Photos-style on the phone** and
**Lightroom-style on desktop** (overrides spec §7.3 "Photos-style" for desktop); everything else
"builder picks best fit".

**Spec:** `docs/superpowers/specs/2026-11-25-photo-server-design.md` §6.7, §6.11, §6.12, §7.3–7.5.

## Builder calls
- Catalog delta: `GET /api/catalog/changes?since=<seq>&catalog=<id>` → changed/deleted asset ids
  from `change_log`, plus full folder and album lists (small). Each database gets a random
  `catalogId` (setting); a different id or a `since` beyond the current seq → `{reset: true}` and the
  client re-downloads the snapshot. The snapshot stays one request (no paging) — ~15 MB at 100k.
- Client storage: `idb` (tiny promise wrapper). Stores: `meta`, `assets`, `images` (cache index),
  `pins` (downloaded albums). Images in Cache Storage `images-v1`.
- Service worker: SvelteKit `src/service-worker.ts`. App shell precached; navigations served from
  the cached `index.html`; `/api/thumb|preview` cache-first (written to the index by the worker,
  last-access updates batched); everything else under `/api` network-only. New worker waits; the
  existing blocking "Update now" dialog activates it and reloads.
- LRU eviction runs in the page (after sync, after downloads, on Storage screen): unpinned entries,
  oldest access first, until under the limit (default 2 GB, stored in `meta`).
- Offline = `/api/health` fails (2 s timeout) or any API fetch fails with a network error; retry
  every 10 s and on `online`/visibility. Offline: banner, favourite/album/select-actions/upload/edit
  disabled.
- Download album pins thumb + preview (device format, current edit version) of every member; a
  sync that changes an `ev` re-pins the new URLs and releases the old ones.
- Edit pipeline: render pipelines (fullscreen triangle). Passes: `fs_luma` (downsample luminance
  to a fixed 256 px long edge — resolution independent), `fs_blur` ×2 (separable Gaussian),
  `fs_develop` (geometry → linear P3 → exposure → white balance → highlights/shadows/brilliance
  (local, from blurred luminance) → brightness/contrast/black point → tone curve (monotone cubic,
  up to 16 points, evaluated in the shader) → saturation/vibrance → vignette → sharpen → encode).
  All recipe→uniform math lives in WGSL; TS and Swift only copy recipe numbers into a fixed
  `array<vec4f, 16>` layout.
- Shaders: `shaders/edit.wgsl` (source of truth) → `scripts/gen-shaders.sh` (naga) →
  `server/Sources/PhotoCore/Editing/EditShaders.generated.swift` (MSL in a string, committed;
  compiled at runtime with `makeLibrary(source:)` — no Xcode needed). A test fails if the
  generated file is stale.
- Colour: both sides upload the base image as Display-P3-encoded RGBA8; output Display P3.
- Base image for editing and for edited previews/thumbnails is the unedited 2048 px preview
  (`e0`), so the edited preview is pixel-for-pixel what the editor showed. Full-resolution export
  decodes the original (orientation applied) and runs the same recipe.
- Parity: committed fixture (`shaders/fixtures/*.rgba`) × recipes; Swift (Metal) renders and
  compares against committed goldens; vitest renders with Dawn (`webgpu` npm) and compares against
  the same goldens. Tolerance 1/255 each side (≤ 2/255 between them). `UPDATE_GOLDENS=1` on the
  Swift side rewrites them.
- Export: `GET /api/assets/{id}/export?variant=original|edited&fmt=jpeg|heic` renders synchronously
  (small LRU in `cache/exports`) and returns an attachment. iOS: fetch → blob → "Share" button
  (fresh gesture) → `navigator.share({files})`.
- Auto-enhance: `CIImage.autoAdjustmentFilters` on the e0 preview → highlights/shadows, vibrance,
  tone curve, warmth/tint from face balance.
- History: `edit(assetId, version, recipe, createdAt)`; save appends + sets `asset.editVersion`;
  revert sets 0. Edited derivatives regenerate on demand from the recipe; Rebuild caches
  re-renders them; BlurHash follows the current version.
- Content changed at the same path: the edit follows the asset; geometry reset if dimensions differ.
- Editor UI: `Editor.svelte` overlay opened from the viewer (button, key E). Desktop (≥ 900 px,
  fine pointer): canvas + right panel (histogram, Light, Color, Tone curve editor, Effects,
  Geometry), toolbar (Auto, undo/redo, Revert, Cancel, Done). Phone: canvas, tabs Adjust/Crop,
  scrolling round adjustment buttons with value rings, ruler dial slider, press-and-hold for
  original, double-tap to reset. Crop: handles, aspect presets, straighten dial (crop auto-shrinks
  to stay inside), rotate 90°, flip.

## Tasks
1. Server: catalogId, `/api/catalog/changes`, tests.
2. Web: IndexedDB replica + delta sync, offline detection, view-only offline UI.
3. Web: service worker (shell + image cache), update flow, cache index + LRU, Storage screen,
   Download album. Unit tests (fake-indexeddb).
4. Shaders + generator + Swift Metal renderer + parity fixtures/goldens.
5. Server: edit table/API (history, save, revert, auto-enhance, export), edited derivatives,
   rebuild caches, relink, API v3. Tests.
6. Web: TS WebGPU renderer (+ parity test), recipe model, editor UI desktop + phone, export/share.
7. Build, run, verify in the browser (desktop + phone viewport), README.

## Review focus
1. Offline cold launch with a downloaded album: everything in it opens, no spinner.
2. Re-editing a photo in a downloaded album re-pins the new previews; old ones become evictable.
3. Preview in the editor vs exported JPEG for the same recipe: visually identical.
4. Clearing server caches → edited thumbnails come back (re-rendered from recipes).
5. App update while a new service worker is waiting → "Update now" lands on the new build.
