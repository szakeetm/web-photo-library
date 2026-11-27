# Web Photo Library

A self-hosted, Apple Photos–style photo library. A Mac serves a **read-only** folder of
images (including Google Photos Takeout exports) to a web app that works on desktop and as an
iPhone Home Screen app, reached privately over [Tailscale](https://tailscale.com).

> Status: **all 6 milestones** of the [spec](docs/superpowers/specs/2026-11-25-photo-server-design.md) —
> indexing, timeline, folders, viewer, albums, favourites, search, uploads, installable app,
> offline mode, non-destructive editing, people (face recognition) and places (map); since then
> text in photos and duplicates, a Trash for uploads, local mode on the Mac and big-library tuning.

## Screenshots

| Desktop | iPhone |
|---|---|
| ![Library timeline on desktop](docs/screenshots/desktop-library.jpg) | ![Library timeline on iPhone](docs/screenshots/mobile-library.jpg) |
| ![Filter and sort menu on desktop](docs/screenshots/desktop-filter.jpg) | ![Filter and sort menu on iPhone](docs/screenshots/mobile-filter.jpg) |
| ![Photo viewer on desktop](docs/screenshots/desktop-viewer.jpg) | ![Photo viewer on iPhone](docs/screenshots/mobile-viewer.jpg) |
| ![Photo editor on desktop](docs/screenshots/desktop-editor.jpg) | ![Photo editor on iPhone](docs/screenshots/mobile-editor.jpg) |
| ![Trimming a video on desktop](docs/screenshots/desktop-trim.jpg) | ![Trimming a video on iPhone](docs/screenshots/mobile-trim.jpg) |
| ![Albums and collections on desktop](docs/screenshots/desktop-albums.jpg) | ![Albums on iPhone](docs/screenshots/mobile-albums.jpg) |
| ![Exporting the library: originals and edits, XMP sidecars, by month](docs/screenshots/desktop-export.jpg) | ![Exporting an album on iPhone](docs/screenshots/mobile-export.jpg) |
| ![Exporting a selection on desktop](docs/screenshots/desktop-download.jpg) | ![Selecting photos by dragging a finger on iPhone](docs/screenshots/mobile-select.jpg) |
| ![Duplicates on desktop](docs/screenshots/desktop-duplicates.jpg) | ![Adjust Date & Time on iPhone](docs/screenshots/mobile-date.jpg) |
| ![Search on desktop](docs/screenshots/desktop-search.jpg) | ![The info sheet, swiped up on iPhone](docs/screenshots/mobile-info.jpg) |
|  | ![Folders on iPhone](docs/screenshots/mobile-folder.jpg) |
| ![People on desktop](docs/screenshots/desktop-people.jpg) | ![People on iPhone](docs/screenshots/mobile-people.jpg) |
| ![The people in a photo, in the info panel](docs/screenshots/desktop-viewer-people.jpg) | ![Places by country and city on iPhone](docs/screenshots/mobile-places-list.jpg) |
| ![Photos on a map on desktop](docs/screenshots/desktop-places.jpg) | ![Photos on a map on iPhone](docs/screenshots/mobile-places.jpg) |
| ![Uploading by drag and drop on desktop](docs/screenshots/desktop-upload.jpg) |  |
| ![Folders on desktop](docs/screenshots/desktop-folders.jpg) |  |
| ![Settings on desktop](docs/screenshots/desktop-settings.jpg) |  |

Screenshots use the stock-photo demo library in [`demo/`](demo/) (the people are NASA astronauts in
public-domain NASA photos; [credits](docs/screenshots/CREDITS.md));
regenerate them with `demo/take-screenshots.sh` (desktop; `PHONE=none KEEP=1` leaves the demo server
running). The iPhone shots are taken in the iOS Simulator, in the app added to the Home Screen (not a
Safari tab), with Local mode off; the phone editor shot is older (the Simulator has no WebGPU).

## What it does today

- **Read-only library.** Point it at any folder on the Mac; it never writes there. Thumbnails,
  previews and the database live in a separate, movable data location.
- **Videos and Live Photos.** Videos play in the viewer with seeking; iPhone Live Photos play on
  press. Originals that browsers handle (H.264/HEVC up to 1080p) stream as-is, others get an HEVC
  preview made on demand with ffmpeg (or in bulk from Settings, Videos).
- **Google Takeout aware.** Dates, locations, descriptions and favourites come from Takeout JSON
  sidecars (with all their naming quirks), then EXIF, then the file date. Duplicate copies that
  Takeout scatters across album folders are recognised by content hash and shown once.
- **Fast.** HEIC thumbnails and previews via the Mac's hardware HEVC codec, one decode per photo,
  8 parallel workers (~16 s for 550 photos on an M-series Mac). BlurHash placeholders while loading.
- **Photos-like UI.** Month-grouped timeline (local time where each photo was taken), pinch or
  ⌘-scroll to change density, a timeline scrubber on the right edge (drag to jump through the years)
  and a jump-to-month panel (tap the month label: years with photo counts, then months), folders with covers, a full-screen viewer with swipe, swipe-down to
  close, pinch/double-tap zoom (and a −/+ zoom slider on desktop), info panel and original download.
  On the iPhone, swipe up on a photo for its info sheet and swipe it down again. Zooming in loads the
  full-resolution original in the background (progress in the corner) and swaps it in once decoded,
  so zooming never stalls.
- **Albums and favourites.** Create albums from a multi-selection (Select button, long-press on
  iPhone, ⌘/shift-click on desktop; in Select mode drag sideways across photos — finger or mouse —
  to select a range), reorder-safe membership by content hash, ♥ in the viewer (or press F).
  Albums show oldest to newest. Google Takeout album folders become albums with one click.
- **Filter and sort** any grid from the title bar: Favourites, Photos, Videos, Live Photos, Edited,
  Screenshots, Selfies, Portraits; Newest/Oldest First or Recently Added. Albums open oldest first and remember
  a change on the device for good; folders open oldest first and people and places newest first, and
  keep a change until the browser session ends.
  Screenshots, selfies (front camera) and Portrait-mode photos also get Media Types collections.
- **Adjust Date & Time** for one photo (info panel) or a selection: shift them all (spacing kept),
  set them all to one time, or change the time zone. Kept in the database only — the files never
  change, re-indexing keeps it — and written into exported copies. Revert goes back to the file's date.
- **Search** across file names, folders, descriptions, album titles, people, places and **text in
  photos** (signs, documents, screenshots — read on the Mac with the OCR built
  into macOS; nothing to download).
- **Sources**: the library folder, more folders on the Mac, Apple Photos libraries (originals read in
  place, edited photos as Photos renders them, albums imported) and folders on any rclone remote
  (pCloud…; originals fetched when needed, a size-limited cache on the Mac). The same photo in several
  sources is shown once. Each source has a **Refresh** button (Settings) to look for new and changed
  photos in it alone, and an optional **auto-refresh**, off by default: every 5 minutes (say, a Photos
  library synced with iCloud) to every week.
- **Backup** (Settings): the database and the uploads to any rclone destination, daily by default;
  Restore checks the backup's format and the sources first. Format and compatibility rules:
  [docs/backup-format.md](docs/backup-format.md).
- **Duplicates** (Collections): copies of the same photo (re-saved, resized, converted); shots
  that are only alike (bursts, crops) aren't listed. Keep one: it gets the others' albums and favourite; uploaded copies
  go to the Trash, library copies are shown in the Finder for you to delete.
- **Trim videos** in the viewer (filmstrip with two handles). Save keeps the trim in the database
  (playback and exports use it); Save as New writes a trimmed copy, without re-encoding, into the
  uploads folder.
- **Analyse photos.** Text in photos (for search) and duplicate fingerprints are made on the Mac
  after each scan, in one pass; Settings → Analyse photos runs it by hand.
- **Export.** One photo, a selection, an album, several albums (Collections → Select) or the whole
  library (Library → ↓). On desktop: originals, with edits, or both (the originals of edited items in
  an `Originals/` folder); Live Photo videos; Google Photos JSON or XMP sidecars (date with time zone,
  place, description, favourite, albums and people as keywords, named faces); all in one folder, one
  per album or `YYYY/YYYY-MM` folders. The Mac streams it as one ZIP, or — on the Mac itself — writes
  it into a folder you choose. Edits are applied without re-encoding where possible (an adjusted date
  is rewritten into the same JPEG/HEIC, trims are cut losslessly). On the iPhone: the files, with or
  without edits, through the share sheet, plus each Live
  Photo's video (.MOV named like the still) if wanted. Edited stills keep the Live Photo's content
  identifier, so importing the photo and its .MOV together into Photos on a Mac gives the Live Photo
  back. On the iPhone files go through the share sheet (a web app can't save Live Photos, so they
  arrive as a photo and a video).
- **Uploads.** Upload from the iPhone photo picker or drag files/folders onto the desktop window.
  Uploads go to a separate uploads folder (`phone-uploads/`, `desktop-uploads/`), are de-duplicated
  by content hash, and keep their albums and favourites if you later move them into the library.
- **Trash for uploads.** Uploaded photos (only those — the library is never changed) can be
  deleted: they move to a hidden `.trash` folder inside the uploads folder and wait in Trash (in
  Collections and under Uploads in the sidebar) for 30 days. Restore puts them back with their
  albums, favourites and edits; Delete permanently or Empty Trash removes the files from disk.
  Uploading a photo that is in the Trash restores it.
- **Works offline.** The catalog is kept on the device and updated with small deltas; photos you
  look at are cached (size limit, Clear cache and Remove offline downloads in Settings → This
  device). **Download** an album or a folder (with its subfolders) from its ⋯ menu to keep its
  thumbnails and previews, with progress shown under the title (and a confirmation above 500
  photos); offline the app opens without a network and is view-only.
- **Big libraries.** Built for ~100k photos: the first install shows a "Downloading library"
  progress card, then updates carry only what changed (changed albums; folders, people and places
  only when they differ). Views share one index built per sync, the grid draws only what is on
  screen, and the device cache keeps running totals and evicts least-recently-used images in batches
  (Live Photo clips capped, thumbnails protected). On the Mac, scans resume after a restart and
  background work pauses while you browse; face grouping scales past 100k faces.
- **Local mode.** A browser on the Mac running the server is recognised (directly or through
  Tailscale) and shows *Local mode*: nothing is cached or downloaded for offline use, videos play
  from the original whenever the browser can, zoom loads full resolution at once, and photos,
  videos, folders, uploads and the Trash have a **Reveal in Finder** button. Settings → This device
  can switch it off to test the app as a phone would see it.
- **Non-destructive editor.** Light (exposure, brilliance, highlights, shadows, brightness,
  contrast, black point), colour (saturation, vibrance, warmth, tint), tone curve, sharpness,
  vignette, crop with aspect presets, straighten, rotate, flip, Auto, undo/redo, hold to compare,
  full history and Revert to Original. Photos-style on the iPhone, Lightroom-style panels with a
  histogram on desktop. The preview is exactly what gets saved: one shader file
  (`shaders/edit.wgsl`) runs in the browser (WebGPU) and on the Mac (Metal, via naga). Edited
  thumbnails/previews are rendered on the Mac, so viewing never needs WebGPU; **Export** renders
  the edit at full resolution (JPEG/HEIC, original metadata kept) for the share sheet or a download.
- **HDR.** iPhone HDR photos (Apple and ISO 21496-1 gain maps) stay HDR everywhere: thumbnails and
  previews carry the gain map, and the editor works in HDR on HDR screens (extended-range WebGPU
  canvas, the gain map sent alongside the preview). Saved edits keep HDR: crop/rotate/straighten
  carry the original gain map through the same geometry, other edits get a gain map computed from
  the SDR and HDR renditions. The SDR look is unchanged, so SDR screens see what they always did.
- **People.** Faces are found and recognised on the Mac (Apple Vision for detection, a FaceNet
  model on the Neural Engine for recognition; nothing leaves the Mac) and grouped into people
  automatically. Name a group, combine two groups that are the same person, remove a face that
  isn't them (it is never added back), choose the cover, or hide someone. The info panel shows
  the faces in a photo — click one to see all photos of that person, or name someone new. New
  photos are scanned after each library scan (~1 minute for 550 photos). Search finds names.
- **Places.** Photo locations become place names (city, region, country) offline, from a bundled
  [GeoNames](https://www.geonames.org) table (CC BY 4.0). A map with photo pins that split as you
  zoom (tap one to see its photos), and a list by country and city. Search finds place names.
  Map tiles come from [OpenFreeMap](https://openfreemap.org) (style changeable in Settings);
  tiles you have seen keep working offline.
- **Installable** to the iPhone Home Screen (Share → Add to Home Screen) or the Dock / app list.
- **Everything configured in the browser:** library folder (server-side folder picker), refresh
  jobs (Detect changes, Re-index, Rebuild caches, Purge missing), data location with “Move…”.
  Settings is split into About, This device (only this browser) and Server (shared by every
  device).
- **Versioned API.** Every response carries the API version; if the app and server don't match,
  the app asks you to update (a reload — the server serves the app).

## Requirements

- A Mac with Apple Silicon (macOS 15+), Swift 6 (Xcode or Command Line Tools), Node 20+.
- For editing: a browser with WebGPU (Safari on iOS / macOS 26, current Chrome).
- For people: the face recognition model, built once with `tools/face-model/make.sh` (below).
- Optional: ffmpeg (`brew install ffmpeg`) for video previews of 4K, VP9 and other unplayable videos.
- Tailscale on the Mac and your devices for remote access.

## Run it

```sh
# build the web app
cd web && npm install && npm run build && cd ..

# build and start the server (serves web/build, listens on 127.0.0.1:8787)
cd server && swift build -c release && .build/release/PhotoServer
```

Open <http://127.0.0.1:8787>, choose your library folder in **Settings**, and it starts indexing.
If the folder is in Documents, Desktop or on an external drive, give the server binary (or your
terminal) **Full Disk Access** in System Settings → Privacy & Security.

### As a Mac app

```sh
scripts/build-app.sh --install    # builds everything into ~/Applications/PhotoServer.app
```

**Photo Server** lives in the menu bar: it starts the server, then opens your photos — in the
Safari web app if you made one (Safari → File → Add to Dock while on `http://127.0.0.1:8787`),
otherwise in Safari. The menu has **Open Photos**, **Start at Login** (keeps the server up for
your iPhone), **Show Log** (`~/Library/Logs/PhotoServer.log`) and **Quit**, which stops the
server. If a server is already running on port 8787 (say, a dev build), it uses that one instead.
The library data stays in `~/Library/Application Support/PhotoServer`, so rebuilding or replacing
the app keeps everything. Give **PhotoServer.app** Full Disk Access if your library needs it; with
the default ad-hoc signature that grant resets on each rebuild, so set `SIGN_IDENTITY` to a code
signing certificate to keep it.

### Face recognition model (once)

```sh
tools/face-model/make.sh   # needs uv (brew install uv); ~1 GB of downloads, then ~2 min
```

It converts [facenet-pytorch](https://github.com/timesler/facenet-pytorch)'s FaceNet
(Inception-ResNet-v1 trained on VGGFace2, MIT-licensed weights) to Core ML and installs it in the
data location (`<data location>/models/FaceNet.mlpackage`, 45 MB; by default
`~/Library/Application Support/PhotoServer`). Then
choose **Settings → Find faces**; later scans pick up new photos on their own. To remove it again:
delete that `.mlpackage`, `tools/face-model/.venv` (Python environment, ~0.5 GB), and the
download caches `~/.cache/uv` and `~/.cache/torch`.

### From your iPhone (Tailscale)

The server only listens on localhost; Tailscale publishes it inside your tailnet over HTTPS
(needed for the Home Screen app):

```sh
tailscale serve --bg 8787
```

Then open `https://<your-mac>.<your-tailnet>.ts.net` on the phone and use Share → **Add to Home
Screen**. Optionally set your Tailscale login under Settings → Access so only you get in.

## Develop

```sh
scripts/test-server.sh        # server tests (Swift Testing)
demo/take-screenshots.sh      # README screenshots from the demo library (after a release build)
cd web && npm test            # web unit tests
cd web && npm run dev         # Vite dev server, proxies /api to 127.0.0.1:8787
PHOTOSERVER_HOME=/tmp/ps2 PORT=8799 WEB_ROOT=/tmp/web2 server/.build/release/PhotoServer   # second instance
WEB_OUT=/tmp/web2 npm run build   # (in web/) a test build that doesn't replace what the running server serves
scripts/gen-shaders.sh        # after editing shaders/edit.wgsl: regenerate the server's Metal code (needs naga)
tools/geonames/build.sh       # refresh the bundled offline place table from GeoNames
```

**Edit pipeline parity.** `shaders/edit.wgsl` is the only implementation of the edit maths.
`scripts/gen-shaders.sh` (`cargo install naga-cli`) translates it to Metal into
`server/Sources/PhotoCore/Editing/EditShaders.generated.swift` (committed, so building the server
needs no naga; a test fails if it is stale). Both sides render `shaders/fixtures` recipes and
compare against the same golden images (server: Metal; web: Dawn via the `webgpu` npm package),
within 1/255 per channel. After an intended shader change:
`UPDATE_GOLDENS=1 scripts/test-server.sh --filter EditRender`.

Layout: `server/` (Swift package — `PhotoCore` indexing/DB, `PhotoAPI` HTTP routes, `PhotoServer`
executable), `web/` (SvelteKit single-page app), `docs/` (design spec and plans).
