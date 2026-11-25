# Milestone 2 — Fixes, Albums, Favourites, Search, Uploads, Installable App

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Close milestone-1 deferred findings; add virtual albums (+ Takeout album import), favourites,
basic search, multi-select, uploads into a separate uploads root (hash-matched with the library),
and make the web app installable to the Home Screen / Dock.

**Architecture:** `file`/`folder` rows gain a `root` (`library` | `uploads`); the scanner walks all
configured roots in one pass so moves between roots keep asset identity. Albums are DB rows
referencing asset ids. Uploads stream to the uploads root, are hashed server-side, written
atomically and indexed immediately. API version bumps to 2 (catalog shape changes).

**Tech Stack:** as milestone 1 (Swift 6.4, Hummingbird 2, GRDB 7, SvelteKit 3 / Svelte 5).

**Spec:** `docs/superpowers/specs/2026-11-25-photo-server-design.md` (§6.2, §6.3, §6.4, §6.5, §6.11–6.13, §7.2, §7.2a)

## Global Constraints
- Library root is never written. The server writes only into the data location and the uploads root.
- Data location, library and uploads root must not overlap each other (case-insensitive).
- Clients must match `apiVersion` exactly (now **2**); catalog `format` → **2**.
- User data (albums, favourites, descriptions) is never deleted by refresh jobs.
- Uploads: `uploads/{phone|desktop}-uploads/YYYY-MM/<original name>`; clash with other content → ` (2)`, ` (3)`…
- Tests: `scripts/test-server.sh`, `cd web && npx vitest run`, `npm run check`.

## Review Focus
1. Same photo uploaded twice (or already in library) → no second copy written; existing asset returned.
2. File moved from uploads into the library between scans → same asset, album membership kept.
3. Upload interrupted mid-stream → no partial file left in the uploads root, nothing indexed.
4. Album containing a photo whose files all disappear → album keeps the member (hidden while missing), reappears when found.
5. Takeout album import run twice → no duplicate albums or members.

---

## Task 1: Milestone-1 deferred fixes
- Derivative source check: `CatalogService.sourceURL(id:)` returns a file only if its size+mtime match the `file` row (else next row / nil → 404). Test: rewrite file in place → thumb request 404s until rescan.
- `progressReporter` thread-safe and monotonic (lock; ignore smaller `done`). Test: concurrent reports never decrease persisted progress.
- Derivative failures counted and appended to the job message (`N photos could not be rendered: <names>`). Test: truncated JPEG with valid header → job message mentions it.
- `DerivativeStore` per-key locks → fixed stripe of 64 locks by key hash. (No growth.)
- On-demand derivatives limited to 4 concurrent (async semaphore) at `.userInitiated`; jobs stay `.utility`.
- Scanner counts skipped non-image files (`skippedOther`) and reports "N videos/other files skipped". Test.
- Re-index: missing file → "File not found: path". Cancel checked inside `walk()` every 500 entries. Tests.
- Owner check: when owner is set, a request is allowed if its `Tailscale-User-Login` equals the owner, or if it carries no Tailscale headers **and** no `X-Forwarded-For` (direct local access). Test.
- Purge missing also deletes the purged assets' derivatives. Test.

## Task 2: Multiple roots (library + uploads)
- Migration v2: `file.root TEXT NOT NULL DEFAULT 'library'`, `folder.root` likewise; unique `(root, relPath)` for both (rebuild tables).
- `SettingKey.uploadsPath: String?`. `LibraryScanner(db:, roots: [Root(name:, url:)], …)`; walks all roots, `existing` keyed by `root + "/" + relPath`. Missing root (unset) is skipped; unreadable configured root → error but other roots still scanned and the unreadable root's rows untouched.
- `CatalogAsset.folders` stays folder ids; `FolderNode.root` added. Catalog `format = 2`.
- `PUT /api/settings {uploadsPath}` validates existence/writability and no overlap with library/data.
- Tests: `movedFromUploadsToLibraryKeepsAsset` (favourite survives), `twoRootsSameRelPath` (both indexed), `unreadableUploadsRootLeavesRowsAlone`.

## Task 3: Upload API
- `HEAD /api/assets/:id` → 200 if asset exists and not missing, else 404.
- `POST /api/uploads?source=phone|desktop&name=<filename>&mtime=<ms>` body = raw file bytes (streamed to a temp file inside `uploads/.incoming/`, SHA-256 while streaming). If hash exists (not missing) → delete temp, return `{asset, duplicate: true}`. Else probe (reject non-image 415), target `uploads/<source>-uploads/YYYY-MM/` (capture month from EXIF/sidecar else now), unique name, atomic rename, set mtime, index just that file (`LibraryScanner.indexFile(root:, relPath:)`), generate derivatives, return `{asset: CatalogAsset, duplicate: false}`.
- 409 when no uploads folder configured. Max body 512 MB.
- Tests: upload new → file exists at expected path & catalog contains it; duplicate → no file written; name clash → ` (2)`; garbage → 415 and no file; aborted body leaves no file in uploads (only `.incoming` cleaned).

## Task 4: Albums, favourites, search (server)
- Migration v3: `album(id, title, createdAt, coverAssetId, source, sourceKey UNIQUE)`, `album_asset(albumId, assetId, position, PRIMARY KEY(albumId, assetId))` — `assetId` without FK cascade to `asset` (members survive missing; purge removes them), FTS5 table `search(assetId UNINDEXED, text)` rebuilt per asset on upsert (filename, folder path, description, album titles).
- API: `GET /api/albums` (id, title, count, coverId, source), `POST /api/albums {title, assetIds?}`, `PATCH /api/albums/:id {title?, coverAssetId?}`, `DELETE /api/albums/:id`, `POST /api/albums/:id/assets {add?: [ids], remove?: [ids], order?: [ids]}`; `PATCH /api/assets {ids, favorite}` (sets `favoriteUserSet`); `GET /api/search?q=` → `{ids}` (prefix match per token).
- Catalog gains `albums: [{id, title, coverId, source, assetIds}]`.
- Job `import-takeout-albums`: each folder containing `metadata.json` with non-empty `title` → album `source=takeout, sourceKey=root:relPath`, members = assets in that folder; re-run updates members, never duplicates. Also offered after detect-changes finds such folders (`message` hint).
- `apiVersion = 2`.
- Tests per endpoint + Review Focus 4, 5.

## Task 5: Web — albums, favourites, selection, search
- Store: `app.albums`, actions `toggleFavorite(ids)`, `createAlbum`, `addToAlbum`, `removeFromAlbum` (optimistic, then reload).
- Selection mode in Grid: desktop click with ⌘/shift, mobile "Select" button then taps; action bar: ♥ Favourite, Add to Album (sheet with album list + "New album"), Remove from album (in album view), Download.
- Routes: `/albums` (Albums + Folders + Uploads sections, album cards), `/albums/[id]` (grid, rename, delete), `/favorites`, `/search` (input, results grid).
- Viewer: heart button + `F` key.
- Nav: mobile tabs Library · Albums · Search · Settings; desktop sidebar Library, Favourites, Albums list, Folders, Search, Settings.
- Settings: uploads folder picker, "Import Takeout albums" button, toggles to hide Folders/Albums.
- Vitest: selection range logic (`selectRange(ids, anchor, target)`).

## Task 6: Web — uploads
- `src/lib/uploads.svelte.ts`: queue persisted in IndexedDB (`File` blobs), sequential worker: SHA-256 via `crypto.subtle` → `HEAD` → `POST` with progress (XHR upload progress), retries ×3 with backoff, resumes on app start.
- Upload button (Library title bar + Albums/Uploads); desktop drag-and-drop overlay (files and folders via `webkitGetAsEntry`), `source` = phone when `navigator.maxTouchPoints > 0 && width < 768` else desktop.
- Upload sheet: per-file status (hashing, uploading %, duplicate, done, failed).
- Vitest: queue state transitions with a fake transport.

## Task 7: Installable app
- `static/manifest.webmanifest` (name Photos, standalone, theme/background colours, icons 192/512 + maskable), `apple-touch-icon` 180, generated by `scripts/make-icons.swift` (CoreGraphics, no external tools).
- `app.html` links manifest + touch icon; iOS status bar style; Safari "Add to Dock" hint in Settings → This device when not standalone.
- Verify: manifest served with `application/manifest+json`; Lighthouse-style check via CDP `Page.getAppManifest` shows no errors.

## Task 8: Verify, review, ship
- Full suites; CDP screenshots of albums, selection, upload sheet (demo instance); fresh-reviewer final review; fix pass; push; restart server.
