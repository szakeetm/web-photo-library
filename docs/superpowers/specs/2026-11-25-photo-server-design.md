# Photo Server — Design

Date: 2026-11-25
Status: final draft — open questions resolved (SDR editing; OpenFreeMap tiles accepted)

## 1. Intent

A personal, self-hosted "Apple Photos"-like app. A Mac (Apple Silicon, M1 or newer) serves a
plain folder of image files — read-only — to a web app used on desktop and iPhone, reached
over Tailscale. It should feel like a native app, support non-destructive editing whose
preview exactly matches the exported result, organise photos by folders, virtual albums,
people (face recognition) and places, and keep working (view-only) when the server is
unreachable.

Single user: the owner. No accounts.

## 2. Goals, non-goals, anti-goals

**Goals (v1)**
- Index a library folder (configurable in the web GUI) of still images, read-only.
- Timeline (years / months / days / all photos), folder view, virtual albums, favourites.
- Metadata precedence: Google Photos Takeout JSON sidecar → EXIF → file date.
- Server-side caches: thumbnails, previews, edited derivatives; database.
- Manual refresh: **Detect changes**, **Re-index**, **Rebuild caches**.
- Non-destructive editing with instant local preview, auto-enhance, full edit history, revert.
- Export: original or edited (full resolution), via iOS share sheet / desktop download.
- Faces: detection + recognition + clustering into named people, using the M1 Neural Engine.
- Places: reverse-geocoded place hierarchy (offline dataset) + map view.
- Native feel: installable PWA, gestures, transitions, settings screen.
- Client device cache: visible, size-limited, clearable; per-album "Download" (pin) of thumbs
  + previews (never full res).
- Offline launch and view-only browsing of the whole catalog and any cached images.
- All server settings editable in the web GUI.

**Non-goals (v1)**
- Videos and Live Photos — added later, see `docs/superpowers/specs/2026-11-25-videos-design.md`.
- Multiple users, sharing outside the tailnet, public links.
- Offline editing or offline album/favourite changes (controls disabled offline).
- Native iOS/macOS client app.
- Importing from an Apple Photos `.photoslibrary`.
- Noise reduction, retouch/healing, scene/object search, "Memories".
- Automatic file watching (refresh is manual).
- Offline map tiles (only previously viewed tiles are available offline).

**Anti-goals (failure even if it "works")**
- Writing, moving, renaming or deleting anything inside the library folder (uploads go to a
  separate uploads folder, §6.13).
- An edited preview that looks different from the exported edited file.
- Losing edits, albums, favourites, face names when re-indexing, moving the library folder,
  or clearing caches.
- The app spinning indefinitely when the server is unreachable.
- Sending photos or photo metadata to third-party services (reverse geocoding is offline).
  Accepted exception: map tile requests for the area being viewed go to the tile provider
  (OpenFreeMap by default); a self-hosted tile source removes this.

## 3. Constraints

- Server: macOS on Apple Silicon (M1 baseline). Minimum macOS 15 (builder may raise if needed).
- Access only via Tailscale. HTTPS via `tailscale serve` on the `*.ts.net` name (required for
  service worker / PWA). Server binds to 127.0.0.1 only.
- Clients: iPhone Safari as Home Screen PWA (iOS 26+), desktop Safari 26+ / current Chrome.
  WebGPU is required **only for the editor**; viewing (including edited photos) works without it.
- Library size: assume up to ~100k images; must stay responsive at that size.
- iOS realities: no background downloads (pinning progresses only while the app is open);
  Home Screen app storage is separate from Safari's; non-installed Safari storage is evicted
  after 7 days unused; `navigator.share` requires a recent user gesture.

## 4. Approaches considered (edit rendering)

The hard problem is rendering an edit identically in the browser (live preview) and on the
server (full-res export, edited thumbnails).

1. **Single-source shaders (chosen).** The edit pipeline is written once in WGSL. Browser runs
   it via WebGPU; at build time `naga` translates the same WGSL to Metal Shading Language for
   the server. Parity by construction, instant local sliders. Cost: needs WebGPU for editing;
   no free Core Image filters (auto-enhance solved by using Core Image only for *analysis*).
2. **Two implementations** (WebGL in browser, Core Image on server). Rich filters for free,
   but preview/export drift; mitigation "preview-then-refine" (approximate while dragging,
   server render on release) still produces a visible pop and double maintenance. Rejected.
3. **Server renders every preview.** One implementation, but 150–400 ms per slider change over
   Tailscale; not smooth. Rejected (owner wants local, smooth preview).

Also rejected: TypeScript server + Swift helper (two runtimes, IPC, loses direct ImageIO /
Vision access); native iOS app (owner wants a web app).

## 5. Architecture overview

```
iPhone / desktop browser (PWA, Svelte 5)
  ├─ Service worker: app shell precache, image cache (Cache Storage)
  ├─ IndexedDB: catalog replica + cache index (LRU / pins)
  └─ WebGPU editor (WGSL edit pipeline)
        │  HTTPS (tailscale serve → 127.0.0.1:PORT)
Mac server (Swift, Hummingbird 2)
  ├─ REST/JSON API + static web app
  ├─ SQLite (GRDB, WAL, FTS5)
  ├─ Job queue: indexing, derivatives, faces, geocoding, exports
  ├─ ImageIO (decode, thumbnails, HEIC/JPEG encode via HW HEVC)
  ├─ Metal renderer (WGSL→MSL edit pipeline, same shaders as client)
  ├─ Core Image (auto-enhance analysis only)
  ├─ Vision + Core ML (face detection, face embeddings on Neural Engine)
  └─ GeoNames reverse geocoder (bundled, offline)
Library folder (read-only)      Data dir (DB)      Cache dir (derivatives)
```

Repository layout (proposal): `server/` (Swift package), `web/` (Svelte app), `shaders/`
(WGSL source of truth + parity tests), `tools/` (model conversion, GeoNames prep).

## 6. Server

### 6.1 Runtime & deployment
- Swift 6, Hummingbird 2, GRDB. Serves the built web app as static files.
- Runs as a user LaunchAgent (starts at login). The binary needs Full Disk Access if the library
  lives in a protected location (Desktop, Documents, external volumes); the settings screen
  shows a clear error if the library is unreadable.
- **Data location (owner request):** one user-selected folder holds the database
  (`library.sqlite`) and caches (`cache/`); default `~/Library/Application Support/PhotoServer/`.
  Its path is kept in a bootstrap file `~/Library/Application Support/PhotoServer/config.json`.
  Settings → "Move…" copies the DB (`VACUUM INTO`) and caches to the new folder, switches the
  bootstrap file, deletes the old copies and restarts the server in place (re-exec).
  Bundled models / GeoNames data ship with the app, not in the data location.
- Optional setting "Prevent sleep while jobs run" (IOPMAssertion).
- **Packaging** *(builder call)*: the server ships as a minimal `.app` bundle (no Dock icon,
  optional menu-bar status item), registered as a login item via `SMAppService`, signed with
  a stable identity (free Apple Development certificate via Xcode personal team is enough) so
  the Full Disk Access grant survives rebuilds. Install = build from source + one-time FDA
  grant; a `make install` script also prints/sets up the `tailscale serve` command.
- Auth: trust tailnet; optionally verify `Tailscale-User-Login` header against a configured
  owner login (setting).

### 6.2 Identity & storage model
- An **asset** is identified by the SHA-256 (CryptoKit) of the file contents. Identical files
  in several folders (common in Google Takeout: year folder + album folder) are **one asset
  with several file locations**. Timeline shows it once; folder view shows it in each folder.
- A **file** row is (relative path, size, mtime, asset id). Paths are relative to the library
  root, so moving the whole library folder and updating the setting re-links everything.
- All user data (edits, albums, favourites, people names, face assignments) hangs off asset id
  and is never deleted by refresh operations.
- **Content changed at the same path** (e.g. another tool rewrote metadata) *(builder call)*:
  "Detect changes" re-links user data from the old asset to the new hash. If the new hash
  already exists as another asset, merge (union albums, favourite = OR, keep the existing
  asset's edit if both have one). If pixel dimensions/orientation changed, keep the edit but
  reset its geometry part and flag the asset "edit needs review". Faces are re-detected;
  names carry over by matching to the person centroids.

### 6.3 Data model (SQLite, sketch)
- `asset(id, width, height, mime, taken_at_utc, tz_offset, date_source[sidecar|exif|file],
  lat, lon, location_source, place_id, camera_make, camera_model, lens, iso, aperture,
  shutter, focal, description, favorite, favorite_user_set, blurhash, edit_version,
  missing_since)`
- `file(id, asset_id, rel_path, folder_id, size, mtime, sidecar_rel_path)`
- `folder(id, rel_path, parent_id, name)`
- `album(id, title, created_at, cover_asset_id, sort_mode, source[user|takeout])`,
  `album_asset(album_id, asset_id, position)`
- `edit(asset_id, version, recipe_json, created_at)` — append-only history; current =
  `asset.edit_version` (0 = unedited).
- `face(id, asset_id, bbox, landmarks, quality, embedding BLOB(512×f32), person_id,
  assignment[auto|user|rejected])`, `person(id, name, cover_face_id, hidden)`
- `place(id, geoname_id, name, admin1, country_code, lat, lon)`
- `setting(key, value_json)`, `job(id, kind, state, progress, total, error, started, ended)`
- `change_log(seq, entity, entity_id, op)` — drives client catalog delta sync.
- FTS5 index over filename, description, folder path, album titles, person names, place names.

### 6.4 Indexing pipeline
Triggered manually from Settings:
- **Detect changes**: walk the library; new path or changed (size, mtime) → hash → upsert;
  vanished paths → remove file row; assets with no files get `missing_since` set (hidden, user
  data retained). "Purge missing" button deletes them for good.
- **Re-index**: re-read metadata (sidecar/EXIF/file date, geocoding) for all assets, without
  rehashing unchanged files. Never overwrites user-set values (e.g. `favorite_user_set`).
- **Rebuild caches**: delete and regenerate derivatives.

Per new/changed asset (job priorities: interactive requests > thumbs > metadata > previews >
faces > geocoding):
1. Hash; read ImageIO properties; apply EXIF orientation everywhere downstream.
2. Metadata resolution (§6.5).
3. Thumbnail (eager) + BlurHash.
4. Preview (generated in background after thumbs, also on demand).
5. Face detection + embeddings (§6.8).
6. Reverse geocode (§6.9).

Supported inputs: anything ImageIO decodes — JPEG, HEIC/HEIF, PNG, TIFF, WebP, GIF (first
frame), DNG and common camera RAW (CR2/CR3, NEF, ARW, RAF…; default development). Videos and
unknown types are skipped and counted in the job report. A RAW+JPEG pair is two assets in v1.

### 6.5 Metadata precedence & Google Takeout sidecars
Per field (date, location, description, favourite): sidecar → EXIF → file mtime (date only).
Record the source per field.

**Calendar day / time zone** *(builder call)*: the timeline groups by local time where the
photo was taken. Instant: sidecar `photoTakenTime` (UTC) if present, else EXIF. Offset, in
order: EXIF `OffsetTimeOriginal`; else the time zone of the nearest GeoNames city to the
photo's GPS (GeoNames rows carry a tz id — no extra dataset); else EXIF local time is used as
"floating" local time; else (sidecar/file date with nothing else) the server's time zone.
`tz_offset` and a `tz_source` are stored.

Sidecar matching must handle Takeout quirks, with unit tests per case:
- `IMG.jpg.json` and `IMG.jpg.supplemental-metadata.json` (and truncated variants such as
  `.supplemental-metad.json`, `.suppl.json`).
- Filenames truncated at ~46–51 chars in the JSON name.
- Duplicate counters: `IMG(1).jpg` ↔ `IMG.jpg(1).json`.
- Edited copies: `IMG-edited.jpg` (or localised suffixes) uses the original's sidecar.
- Fields: `photoTakenTime.timestamp` (UTC), `geoData`/`geoDataExif` (ignore 0,0),
  `description`, `favorited`.
- Album folders containing `metadata.json` with a `title`: offered (Settings button, and
  prompt after first index) to import as virtual albums with `source=takeout`.

### 6.6 Derivatives & formats
- Thumbnail: 512 px long edge. Preview: 2048 px long edge. Both via
  `CGImageSourceCreateThumbnailAtIndex` (fast path) and encoded as **HEIC** (hardware HEVC
  encoder), quality tuned by builder.
- JPEG variants generated lazily for clients that can't decode HEIC. Client detects HEIC
  support at startup (decode a tiny embedded HEIC) and requests `?fmt=heic|jpeg`.
- Colour: preserve Display P3 (iPhone photos are P3); embed ICC profile in derivatives.
- Edited derivatives (thumb + preview) are rendered by the server Metal pipeline whenever an
  edit is saved, so viewing edited photos never needs WebGPU.
- File naming: `cache/{kind}/{id[0:2]}/{id}_e{edit_version}.{fmt}`. URLs carry asset id + edit
  version and are served with `Cache-Control: immutable`.
- Server cache size is shown in Settings with a "Clear" button (regenerates on demand).

### 6.7 Edit pipeline (shared WGSL)
- Source of truth: `shaders/*.wgsl`. Build step runs `naga` to produce MSL; server compiles a
  metallib. Browser loads WGSL directly.
- Processing in float16 linear-light (extended linear Display P3), output encoded to P3/sRGB.
- Recipe (versioned JSON schema, `schema: 1`):
  - geometry: crop rect (normalised), straighten angle, 90° rotation, flip H/V
  - light: exposure, brilliance, highlights, shadows, brightness, contrast, black point
  - colour: saturation, vibrance, warmth, tint
  - tone curve (points; filled by auto-enhance, editable later)
  - vignette, sharpen (simple unsharp mask)
- **Auto-enhance**: server runs `CIImage.autoAdjustmentFilters()` on the preview, maps the
  returned filter parameters (tone curve, vibrance, highlight/shadow, face balance) onto recipe
  values, and returns a recipe the client applies and lets the user tweak. Endpoint:
  `POST /api/assets/{id}/auto-enhance` → recipe (not saved until user saves).
- Client edits on the 2048 px preview; server export renders the same recipe on the full-res
  decode (tiled if needed for very large images).
- **Standard dynamic range editing (owner decision):** edits apply to the SDR, display-referred
  rendering of the original — the same baseline the preview is made from (RAW: default
  development; HDR/gain-map photos: SDR base image). The server's full-res export decodes the
  original to that same SDR baseline before running the recipe, so preview and export match.
  Edited exports carry no HDR gain map; "Download original" keeps HDR/RAW untouched.
- Resolution-dependent parameters (sharpen radius, vignette, any blur used by brilliance /
  highlights-shadows) are expressed relative to image size so preview and export match
  visually *(builder call)*.
- **Parity tests**: a fixed set of test images × recipes rendered by the Metal path and by
  headless Chrome/Safari WebGPU (Playwright); max per-channel difference within a small
  tolerance (builder sets, e.g. ≤ 2/255 after 8-bit quantisation).
- Saving an edit appends to history; "Revert to original" sets `edit_version` to 0 (history
  kept). Undo/redo during a session is client-side.

### 6.8 Faces
- Detection: Vision `VNDetectFaceRectanglesRequest` + `VNDetectFaceLandmarksRequest` +
  `VNDetectFaceCaptureQualityRequest`, on the preview-size image.
- Alignment: similarity transform from landmarks to a 112×112 canonical crop.
- Embedding: ArcFace-family model converted to Core ML (`tools/` holds the conversion script),
  `computeUnits = .all` so it runs on the Neural Engine. Builder chooses the concrete model;
  InsightFace models are non-commercial-licensed (acceptable for personal use — note it in
  the README). Skip faces below a size/quality threshold.
- Clustering: incremental. New face → cosine similarity to each named person's centroid; above
  threshold → auto-assign; otherwise unassigned pool. Periodic DBSCAN-style clustering of the
  pool produces "unnamed people" suggestions. User actions: name a cluster, merge people,
  remove a face from a person (`rejected` – never auto-reassigned there), hide a person.
- Runs as a low-priority, pausable background job; progress in Settings.

### 6.9 Places
- Reverse geocoding: bundled GeoNames `cities1000` + admin1 + country names, nearest-city via
  k-d tree, entirely offline. Hierarchy: country → region → city.
- Map: MapLibre GL JS with OpenFreeMap tiles by default; style URL is a setting (allows a
  self-hosted Protomaps file later). Photos shown as clustered pins from the catalog
  coordinates; tapping a cluster opens the photos.

### 6.10 Export
- `GET /api/assets/{id}/original` streams the original file (original filename).
- `POST /api/assets/{id}/export {variant: edited, format: heic|jpeg, quality}` → job; renders
  full res with the Metal pipeline, copies EXIF/GPS/date (orientation normalised), returns a
  download URL when ready. Recent exports kept in a small server LRU.

### 6.11 API (sketch)
- `GET /api/catalog?since={seq}` — full snapshot (paged NDJSON) or delta from `change_log`.
- `GET /api/thumb/{id}?e={v}&fmt=`, `GET /api/preview/{id}?e={v}&fmt=`
- `GET/POST/PATCH/DELETE /api/albums…`, `POST /api/albums/{id}/assets` (add/remove/reorder)
- `PATCH /api/assets/{id}` (favourite, description), `GET/POST /api/assets/{id}/edits`
- `GET/PATCH /api/people…`, `POST /api/people/merge`, `PATCH /api/faces/{id}`
- `GET /api/places`, `GET /api/search?q=`
- `GET/PUT /api/settings`, `GET /api/fs/list?path=` (directory browser, directories only)
- `POST /api/jobs/{detect-changes|reindex|rebuild-caches|faces|purge-missing|import-takeout-albums}`,
  `GET /api/jobs` (progress; polled or SSE)
- `GET /api/health` (fast, for offline detection)

### 6.12 Versioning & updates (owner request)
- **Old clients are not supported (owner decision):** a client must match the server; an outdated
  client is updated, never served in compatibility mode. No backward-compatibility code paths for
  old clients on the server.
- **API contract:** server constant `apiVersion`. Every `/api` response carries `X-API-Version` and
  `X-Server-Version`; every client request sends `X-Client-API-Version`. A client whose API version
  differs from the server's gets `426 {error, updateRequired: true}` (health stays reachable) and
  shows a blocking "Update now" that reloads into the server's current build.
- **Payload formats:** catalog snapshot has `format`; a device replica with another format is
  discarded and re-synced. Edit recipes carry `schema` (int). The server keeps an ordered list of
  recipe upgrade functions (`schema n → n+1`); on startup a DB migration upgrades stored recipes to
  the current schema (this upgrades old *data*, not old clients). A posted recipe whose `schema`
  differs from the server's current schema is rejected with 409 `updateRequired`. Database schema
  changes use GRDB migrations.
- **Updating the app:** the web app is served by the Mac server, so updating the server updates the
  app. Clients detect a new web build via SvelteKit's `version.json` (polled every 5 min, on focus,
  and on visibility change) and show a blocking "Update now" (reload). With the service worker
  (milestone 3) the new version downloads in the background and is applied on "Update now" or the
  next cold launch. Offline devices keep running the cached version (view-only, see §7.5); on
  reconnecting they hit the version check and must update before doing anything else. Same on iOS
  Home Screen apps and desktop installs.

### 6.13 Uploads (owner request)
- **Separate uploads folder** (setting, chosen with the folder browser; the library stays read-only).
  It contains `phone-uploads/` and `desktop-uploads/`, each organised as `YYYY-MM/` by capture date
  (EXIF, else upload date). Original filenames are kept; a name clash with different content gets a
  ` (2)` suffix. The server only ever writes into this folder.
- **One catalog, several roots:** `file` rows gain a `root` (`library` | `uploads`). Detect changes
  scans all roots in one pass, so a file moved from uploads into the library (same hash) is matched to
  the existing asset — albums, edits, favourites and faces stay attached. Folder view shows both roots
  ("Library" and "Uploads").
- **Upload API:** `POST /api/uploads?source=phone|desktop` streaming one file per request, with the
  client's SHA-256 first checked via `HEAD /api/assets/{hash}` so duplicates are skipped instantly.
  The server hashes the received bytes, writes atomically (temp file + rename), indexes the file
  immediately (thumb, preview, metadata) and returns the catalog entry.
- **iPhone:** "Upload" button → photo picker (`<input type=file accept="image/*" multiple>`), which
  lets you multi-select from the Photos library. Uploads run one at a time with progress and continue
  only while the app is open; a closed app resumes the remaining queue when reopened. Drag and drop
  isn't practical on iPhone (works on iPad), and iOS doesn't let web apps appear in the share sheet.
  iOS may hand over JPEG instead of HEIC and may strip location unless "Location" is enabled in the
  picker's Options — verify on device.
- **Desktop:** same button plus drag and drop of files/folders onto the window.

## 7. Web client

### 7.1 Stack
Svelte 5 + Vite (SvelteKit with static adapter, SPA mode — builder may choose plain Vite +
router), TypeScript, IndexedDB (e.g. Dexie), service worker (Workbox or hand-written),
MapLibre GL JS, WebGPU for the editor. Virtualised justified/square grid.

### 7.2 Native feel
- Home Screen install (manifest, icons, splash), standalone display, safe-area aware.
- Mobile: bottom tab bar — Library · Albums · People · Places · Search. Desktop: Photos-like
  sidebar (Library, Favourites, Folders, Albums, People, Places, Settings).
- Library: Years / Months / Days / All Photos; pinch to change density; scrubber.
- Viewer: shared-element transition from grid, swipe left/right, swipe down to dismiss,
  pinch/double-tap zoom (loads original or full-res edited on deep zoom when online), info
  panel (date, camera, map, people, albums, folders).
- Multi-select by long-press/drag; actions: favourite, add to album, share/export.
- Folders and Albums are separate sections; a setting hides either.
- Settings screen sections: Library (path via server folder browser, refresh actions, job
  progress, purge missing, import Takeout albums), Server (data location + Move…, sizes, cache clear,
  prevent sleep, owner login), Faces (on/off, pause, re-cluster), Map (style URL), This device
  (storage, offline, app version/update).

### 7.2a Desktop
- Same app, same origin. Works in a regular tab, and is installable for an app window:
  Chrome/Edge "Install app", Safari (macOS 14+) "Add to Dock". Firefox: tab only.
- Storage, device cache, album download and offline launch work in all of these. Installed
  apps (and Chrome tabs) keep data; a Safari *tab* is subject to 7-day-unused eviction, so the
  app suggests "Add to Dock" in Safari. Safari's Dock app has storage separate from Safari.
- Desktop-specific UX: sidebar, hover states, keyboard shortcuts (arrows, space to open/close,
  ⌘A, F favourite, E edit, ⌘C/⌘S export), shift/⌘-click and marquee selection, drag photos onto
  an album in the sidebar, larger editor with histogram.

### 7.3 Editor
- Photos-style: adjustment list with sliders, auto-enhance wand, crop/straighten/rotate/flip
  tool with pinch, press-and-hold for original, double-tap slider to reset, undo/redo, revert
  to original, save. Disabled with explanation if WebGPU is unavailable or offline.

### 7.4 Export / share
- Tap Export → choose Original / Edited (+format) → "Preparing…" → **Share** button calls
  `navigator.share({files})` (fresh user gesture). Desktop: regular download. Multi-select
  shares multiple files in one sheet.

### 7.5 Device cache & offline
- **App shell** precached by the service worker → launches with no network.
- **Catalog replica** in IndexedDB: all assets' lightweight metadata, folders, albums, people,
  places, current edit versions, BlurHashes. Initial sync paged; then delta sync via
  `since=seq` on launch/foreground.
- **Images** in Cache Storage; IndexedDB index records `{url, bytes, lastAccess, pinnedBy[]}`.
  LRU eviction of unpinned entries to stay under the user-set limit (default e.g. 2 GB).
  Storage screen: used vs. limit, breakdown (thumbs / previews / per downloaded album),
  "Clear cache" (keeps or drops pins, user chooses), limit slider.
- **Download album**: pins thumbs + previews of all album assets (current edit version),
  progress UI, resumes when app reopens; re-pins when an asset's edit version changes.
  Never full resolution. Requests `navigator.storage.persist()`.
- **Offline detection**: `/api/health` with ~2 s timeout plus request failures → offline
  badge; periodic retry. Offline mode is view-only: edit/album/favourite controls disabled,
  uncached images show BlurHash placeholders, map shows only cached tiles.
- App updates: new service worker waits; blocking "Update now" applies it on reload (§6.12).

## 8. Suggested milestones (builder may reorder)
1. Server skeleton, settings + folder browser, indexing (hash, metadata, sidecars),
   thumbnails/previews, timeline + folders + viewer.
2. Albums (virtual + Takeout import), favourites, search basics, PWA shell + native-feel UI.
3. Device cache, catalog sync, download album, offline mode.
4. WGSL edit pipeline (client + Metal), parity tests, editor UI, auto-enhance, exports.
5. Faces.
6. Places + map.

## 9. Left to the builder
- Concrete library choices within the stated stack (router, IndexedDB wrapper, SW tooling).
- Exact face model and thresholds; clustering parameters.
- HEIC/JPEG quality settings, thumbnail grid layout (justified vs. square, or toggle).
- Job scheduler details and concurrency limits.
- Exact edit-math formulas (must be identical by construction via shared WGSL).
- Port number, logging, test strategy beyond the parity and sidecar tests named above.
