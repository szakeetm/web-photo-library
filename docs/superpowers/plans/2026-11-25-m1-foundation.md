# Milestone 1 — Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A running Mac server that indexes a read-only library folder (hash, sidecar/EXIF/file-date metadata, thumbnails, previews) and a web app with settings (library path via folder browser, refresh jobs), timeline, folders and a photo viewer.

**Architecture:** Swift package `server/` with a library target `PhotoCore` (DB, indexing, derivatives, jobs — no HTTP) and an executable `PhotoServer` (Hummingbird 2 routes + static web files). `web/` is a SvelteKit SPA (adapter-static, `ssr = false`) built into `web/build`, served by the server.

**Tech Stack:** Swift 6.4, Hummingbird 2, GRDB 7, ImageIO, CryptoKit, Swift Testing; Svelte 5, SvelteKit 2, Vite, TypeScript, Vitest.

**Spec:** `docs/superpowers/specs/2026-11-25-photo-server-design.md`

## Global Constraints

- Never write, move, rename or delete anything inside the library folder (open read-only).
- Server binds to 127.0.0.1 only; default port 8787 (setting `PORT` env overrides).
- Data dir `~/Library/Application Support/PhotoServer/`; cache dir default `~/Library/Caches/PhotoServer/` (setting).
- Thumbnail 512 px long edge; preview 2048 px long edge; HEIC default, JPEG lazily via `?fmt=jpeg`.
- Derivative path `cache/{kind}/{id[0:2]}/{id}_e{edit_version}.{fmt}`; responses `Cache-Control: public, max-age=31536000, immutable`.
- Asset id = lowercase hex SHA-256 of file contents. Paths stored relative to library root.
- Metadata precedence per field: sidecar → EXIF → file mtime (date only); record source.
- User data is never deleted by refresh jobs; assets without files get `missing_since`.
- Build tools available: Command Line Tools only (no Xcode). Tests use Swift Testing (`import Testing`).

## Review Focus

1. Library path unreadable (no Full Disk Access / unplugged drive) → job fails with a readable error shown in Settings, server keeps running.
2. Corrupt or zero-byte image / non-image file with image extension → skipped and counted, scan continues.
3. Unicode / spaces / NFD-normalised filenames (macOS) → paths round-trip; sidecar matching uses the same normalisation.
4. Same file content in two folders (Takeout) → one asset, two file rows; timeline shows it once.
5. Detect changes run twice with no changes → no rehash (size+mtime short-circuit), no duplicate rows.

Tests pinning these are in Tasks 3, 5 and 6.

---

## File Structure

```
server/Package.swift
server/Sources/PhotoCore/
  Paths.swift              — data/cache dir resolution
  Database/AppDatabase.swift   — DatabasePool, migrations
  Database/Records.swift       — Asset, FileRow, Folder, Job, Setting records
  Settings/SettingsStore.swift — typed get/set over `setting` table
  Indexing/FileHasher.swift    — streaming SHA-256
  Indexing/ImageProbe.swift    — ImageIO properties → ProbeResult
  Indexing/Sidecar.swift       — Takeout sidecar locate + parse
  Indexing/MetadataResolver.swift — precedence + tz
  Indexing/LibraryScanner.swift   — walk, diff, upsert (detect changes / reindex)
  Derivatives/DerivativeStore.swift — paths, generate thumb/preview, HEIC/JPEG encode
  Derivatives/BlurHash.swift
  Jobs/JobRunner.swift          — serial job queue, progress, cancellation
  Catalog/CatalogService.swift  — catalog + folder queries
  FS/DirectoryBrowser.swift
server/Sources/PhotoServer/
  main.swift, Routes/*.swift
server/Tests/PhotoCoreTests/  — one file per PhotoCore unit + Fixtures.swift
web/  — SvelteKit app (src/lib/api.ts, src/lib/stores, src/routes/…)
scripts/make-fixtures.swift — generates a sample library for manual testing
```

## Task 1: Repo scaffolding, Paths, database & migrations

**Files:** `.gitignore`, `README.md`, `server/Package.swift`, `Paths.swift`, `AppDatabase.swift`, `Records.swift`, `Tests/PhotoCoreTests/DatabaseTests.swift`

**Interfaces — Produces:**
- `struct AppPaths { let dataDir: URL; let defaultCacheDir: URL; static func standard() -> AppPaths }`
- `final class AppDatabase { init(path: String) throws; static func inMemory() throws -> AppDatabase; let writer: any DatabaseWriter }`
- Records (GRDB `Codable, FetchableRecord, PersistableRecord`): `Asset`, `FileRow`, `Folder`, `JobRow`, tables per spec §6.3 for asset/file/folder/setting/job/change_log (other tables in later milestones). Asset columns for M1: `id, width, height, mime, takenAt (Date), tzOffset (Int? seconds), dateSource, lat, lon, locationSource, cameraMake, cameraModel, lens, iso, aperture, shutter, focal, description, favorite, favoriteUserSet, blurhash, editVersion, missingSince`.

- [ ] Test `migrationsCreateTables`: in-memory DB has tables `asset, file, folder, setting, job, change_log`.
- [ ] Test `fileUniquePath`: inserting two `file` rows with same `relPath` throws.
- [ ] Implement, run `swift test` in `server/` → PASS. Commit.

## Task 2: SettingsStore & DirectoryBrowser

**Interfaces — Produces:**
- `final class SettingsStore { init(db: AppDatabase); func get<T: Codable>(_ key: SettingKey<T>) throws -> T; func set<T: Codable>(_ key: SettingKey<T>, _ value: T) throws; func all() throws -> [String: JSONValue] }`; keys: `libraryPath: String?`, `cacheDir: String?`, `ownerLogin: String?`.
- `struct DirectoryBrowser { static func list(_ path: String) throws -> DirListing }` where `DirListing { path, parent: String?, entries: [{name, path, readable: Bool}] }` — directories only, hidden dirs excluded, sorted case-insensitively.

- [ ] Tests: default `libraryPath` is nil; set/get round-trip; `list` of a temp dir with `a/`, `.hidden/`, `file.jpg` returns only `a`.
- [ ] Implement, PASS, commit.

## Task 3: FileHasher & ImageProbe

**Interfaces — Produces:**
- `enum FileHasher { static func sha256(url: URL) throws -> String }` (1 MiB streamed chunks, lowercase hex).
- `struct ProbeResult { width, height (oriented), mime (UTType id), exifDate: Date?, exifLocalDate: DateComponents?, exifOffset: Int?, lat, lon: Double?, make, model, lens, iso, aperture, shutter, focal, orientation: Int }`
- `enum ImageProbe { static func probe(url: URL) -> ProbeResult? }` — nil when ImageIO cannot read it.
- `Tests/PhotoCoreTests/Fixtures.swift`: `Fixtures.writeJPEG(to: URL, width: Int, height: Int, exif: [CFString: Any]?, gps: (Double, Double)?, color: (r,g,b))`.

- [ ] Test `hashKnownBytes`: file containing `"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
- [ ] Test `probeReadsExif`: fixture with DateTimeOriginal `2021:07:04 15:30:00`, OffsetTimeOriginal `+02:00`, GPS (47.5, 19.04), 800×600 → those values.
- [ ] Test `probeOrientation6SwapsDims`: orientation 6 fixture 800×600 → width 600, height 800.
- [ ] Test `probeGarbageReturnsNil` (Review Focus 2): zero-byte `x.jpg` and text file `y.jpg` → nil.
- [ ] Implement, PASS, commit.

## Task 4: Takeout sidecars

**Interfaces — Produces:**
- `enum SidecarLocator { static func sidecar(for imageName: String, in dirEntries: Set<String>) -> String? }`
- `struct SidecarData { takenAt: Date?; lat, lon: Double?; description: String?; favorited: Bool? }`
- `enum SidecarParser { static func parse(_ data: Data) -> SidecarData? }`

Matching order (first hit wins; names compared after NFC normalisation): `N.json`, `N.supplemental-metadata.json`, any entry starting with `N.` + prefix of `supplemental-metadata` + `.json`; duplicate counter: image `B(k).ext` → `B.ext(k).json` / `B.ext.supplemental-metadata(k).json`; edited `B-edited.ext` (also `-bearbeitet`, `-modifié`, `-editado`, `-modificato`) → sidecar of `B.ext`; truncation: if no hit, any `.json` entry whose stem (without `.json`/supplemental suffix) is a ≥ 30-char prefix of `N`, and unique.

- [ ] Tests (one each): plain, supplemental, truncated supplemental `IMG.jpg.supplemental-metad.json`, counter `IMG(1).jpg`↔`IMG.jpg(1).json`, edited, long-name truncated at 46 chars, NFD image name vs NFC json (Review Focus 3), no match → nil, ambiguous truncation → nil.
- [ ] Parser tests: `photoTakenTime.timestamp "1625405400"` → 2021-07-04T13:30:00Z; `geoData` 0,0 with `geoDataExif` 47.5,19.04 → 47.5,19.04; both 0 → nil; `favorited: true`; empty description → nil.
- [ ] Implement, PASS, commit.

## Task 5: MetadataResolver & LibraryScanner

**Interfaces — Produces:**
- `struct ResolvedMetadata { takenAt: Date; tzOffset: Int?; dateSource: "sidecar"|"exif"|"file"; lat, lon; locationSource: "sidecar"|"exif"|nil; description: String?; favorited: Bool? }`
- `enum MetadataResolver { static func resolve(probe: ProbeResult, sidecar: SidecarData?, fileMTime: Date, serverTZ: TimeZone) -> ResolvedMetadata }` — tz: EXIF offset → nil (floating: EXIF local interpreted in serverTZ, offset stored nil) → sidecar/file uses serverTZ offset. GPS-based tz arrives in M6.
- `final class LibraryScanner { init(db: AppDatabase, root: URL, derivatives: DerivativeStore?); func detectChanges(progress: (Int, Int) -> Void, isCancelled: () -> Bool) throws -> ScanReport; func reindex(progress:isCancelled:) throws -> ScanReport }`
- `struct ScanReport { added, updated, removed, unchanged, skipped: Int; errors: [String] }`

Rules: walk with FileManager enumerator (skip hidden, `.json`, video extensions); unchanged size+mtime → skip; content changed at same path → re-link user data per spec §6.2 (M1: favorite/description/editVersion move to new asset; merge if exists); missing files → delete file row, set `missing_since` on orphaned assets; upsert folders for every directory; append `change_log` rows; sidecar sets favourite only if `!favoriteUserSet`.

- [ ] Resolver tests: sidecar beats EXIF date; EXIF with offset → tzOffset 7200; no EXIF, no sidecar → file mtime, source `file`.
- [ ] Scanner test `firstScanAdds`: 3 images in 2 folders → added 3, folders 3 (root + 2).
- [ ] `duplicateContentOneAsset` (Review Focus 4): same bytes in `A/x.jpg`, `B/x.jpg` → 1 asset, 2 files.
- [ ] `secondScanNoRehash` (Review Focus 5): rescan → unchanged 3, added 0 (assert via hash call counter injected).
- [ ] `deletedFileMarksMissing`; `contentChangedRelinksFavorite`; `corruptFileSkipped` (Review Focus 2); `unreadableRootThrows` (Review Focus 1) → `ScanError.rootUnreadable(path)`.
- [ ] `libraryUntouched`: snapshot of root (paths, sizes, mtimes) identical after scan.
- [ ] Implement, PASS, commit.

## Task 6: DerivativeStore & BlurHash

**Interfaces — Produces:**
- `enum DerivativeKind: String { thumb, preview }; enum ImageFormat: String { heic, jpeg }`
- `final class DerivativeStore { init(cacheDir: URL); func url(id:kind:editVersion:format:) -> URL; func ensure(id: String, source: URL, kind:, editVersion: Int = 0, format:) throws -> URL; func generateThumb(...)`; `func clear() throws; func sizeOnDisk() -> Int64 }`
- `enum BlurHash { static func encode(cgImage: CGImage, x: 4, y: 3) -> String }`

Uses `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform`, `kCGImageSourceCreateThumbnailFromImageAlways`, max pixel size; HEIC via `CGImageDestination` (`public.heic`, quality 0.6), JPEG quality 0.8; keep color space (P3); atomic write (temp + rename); concurrent `ensure` for same key coalesced.

- [ ] Tests: thumb of 4000×3000 fixture → long edge 512 HEIC readable; preview 2048; JPEG variant; orientation 6 → portrait output; cache path matches constraint; BlurHash of solid red is a 28-char string decoding to ~red (compare to reference string from the woltapp algorithm for a solid color fixture).
- [ ] Implement, PASS, commit.

## Task 7: JobRunner & CatalogService

**Interfaces — Produces:**
- `enum JobKind: String { detectChanges = "detect-changes", reindex, rebuildCaches = "rebuild-caches", purgeMissing = "purge-missing" }`
- `actor JobRunner { func enqueue(_ kind: JobKind) -> Int64; func current() -> JobRow?; func recent(limit: Int) -> [JobRow]; func cancel(id:) }` — serial; detect-changes also generates thumbs (eager) then previews (background, same job, later phase); errors stored in `job.error`.
- `struct CatalogAsset: Codable { id, w, h, t (ISO8601 UTC), tz, fav, bh, ev, folders: [Int64], name }`
- `final class CatalogService { func catalog() throws -> CatalogSnapshot (assets sorted by takenAt desc, folders, seq); func folderTree() throws -> [FolderNode] (with counts); func asset(id:) throws -> AssetDetail; func sourceURL(id:) throws -> URL }`

- [ ] Tests: catalog excludes missing assets; dup-content asset appears once with 2 folder ids; folderTree counts; job progress persisted and state `done`; cancelled job state `cancelled`.
- [ ] Implement, PASS, commit.

## Task 8: HTTP server

**Files:** `server/Sources/PhotoServer/*`

Routes (JSON, errors `{error}`):
- `GET /api/health` → `{ok, version, libraryConfigured}`
- `GET/PUT /api/settings`; `GET /api/fs/list?path=`
- `POST /api/jobs/:kind` → `{id}`; `GET /api/jobs` → `{current, recent}`
- `GET /api/catalog`; `GET /api/folders`; `GET /api/assets/:id`
- `GET /api/thumb/:id?e=&fmt=`, `GET /api/preview/:id?e=&fmt=` (immutable cache headers, 404 unknown)
- `GET /api/assets/:id/original` (Content-Disposition with original filename)
- everything else → static file from `web/build` (env `WEB_ROOT`), SPA fallback `index.html`.

- [ ] Tests via HummingbirdTesting: health; settings round-trip; thumb has immutable header; unknown id 404; SPA fallback.
- [ ] Manual: `swift run PhotoServer`, curl `/api/health`. Commit.

## Task 9: Web app — shell, settings, folder browser, jobs

**Files:** `web/` SvelteKit project; `src/lib/api.ts` (typed fetch wrappers for Task 8 routes), `src/lib/heic.ts` (`supportsHeic(): Promise<boolean>` decoding an embedded 1×1 HEIC data URI), `src/routes/+layout.svelte` (sidebar on ≥ 768 px, bottom tab bar on mobile: Library · Folders · Settings for now), `src/routes/settings/+page.svelte`.

- Settings: library path + "Choose…" modal folder browser (navigates `/api/fs/list`), Save; buttons Detect changes / Re-index / Rebuild caches / Purge missing; current job progress bar + recent jobs with errors (poll `/api/jobs` every 1 s while running); first-run: if `libraryConfigured=false`, redirect to settings with a welcome card.
- [ ] Vitest: `api.ts` builds correct URLs (`thumbUrl(id, ev, fmt)` → `/api/thumb/{id}?e={ev}&fmt={fmt}`).
- [ ] `npm run build` succeeds; commit.

## Task 10: Web app — timeline, folders, viewer

- `src/lib/catalog.ts`: loads `/api/catalog` into a store; `groupByMonth(assets, tzAware)` using `t` + `tz` (local date of capture; floating when tz null).
- `src/lib/components/Grid.svelte`: virtualised square grid (rows computed from container width & density 3–9 columns mobile / 4–14 desktop), sticky month headers, pinch (touch) / ⌘± (desktop) density, BlurHash placeholder canvas until thumb loads.
- `src/routes/+page.svelte` (Library: All Photos with month headers), `src/routes/folders/[...path]/+page.svelte` (subfolders list + grid).
- `src/lib/components/Viewer.svelte`: full-screen overlay, preview image, swipe left/right + arrow keys, swipe down / Esc to close, double-tap / pinch zoom, info panel (date, camera, file paths), Download original button.
- [ ] Vitest: `groupByMonth` puts `2021-07-31T23:30:00Z` with tz +7200 into August 2021; null tz uses UTC fields of floating time.
- [ ] Build, run server with fixtures library (`scripts/make-fixtures.swift` creates ~50 images incl. sidecars, dup, rotated), manual check desktop + mobile viewport. Commit & push.
