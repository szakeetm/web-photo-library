# Videos — design

Status: approved · 2026-11-25

## Intent

Videos in the library should show up in the timeline, folders, albums and search like photos do,
and be **playable on the iPhone** (and desktop) over Tailscale. Today the scanner skips every video
(counted as "videos/other files skipped"); the main spec lists videos as a v1 non-goal. This lifts
that for plain videos only.

What the owner said:
- Phone playback is the point. Quality doesn't need to be high.
- Videos stay **out of Download (pinning) and the device cache**.
- Larger-than-1080p videos get a **1080p H.265 preview**; playable small originals are served as is.
- Conversion is **on demand** (first open of a video), plus a **manual, pausable/resumable
  "Convert all N videos"** control in Settings.

## What's in the real library (probed 2026-11-25)

| Files | What | Plan |
|---|---|---|
| 93 MP4, ≤4 s, same basename as a JPG, no own sidecar | Takeout **Live Photo motion** | hidden as assets; played as Live Photo motion |
| 38 MOV, HEVC `hvc1`, 4K (some HLG HDR, iPhone 15 Pro Max) | real videos | 1080p preview |
| 23 MOV, **VP9** `vp09`, 1080p (Takeout) | real videos | preview (Safari can't play; AVFoundation reports "Cannot Decode") |
| 3 MOV + 2 MP4, H.264, ≤1080p | real videos | serve original |

66 real videos, 3–34 s each, ≈11 min total. Expected preview size ≈350 MB.

## Goals

1. Videos are indexed as assets (`kind = video`) with date, location, dimensions, duration.
2. Grid thumbnails show a poster frame with a duration badge (`0:12`).
3. The viewer plays videos with native controls on iPhone Safari (installed web app) and desktop.
4. A video is served either as its **original** (if Safari-playable and not larger than 1080p) or
   as a **1080p HEVC preview** made by ffmpeg, the first time someone opens it or by "Convert all".
5. Settings shows video conversion status and a pausable/resumable "Convert all" control.
6. Live Photos play their motion clip in the viewer (press and hold), unedited even when the still
   is edited.

## Non-goals

- Video editing, trimming, export of anything but the original file.
- Faces in videos.
- Video uploads (uploads stay images-only in this round).
- Adaptive streaming (HLS), multiple quality levels.
- Offline video: never in Download, never in the device cache.

## Anti-goals

- Writing anything into the library folder (read-only stays absolute).
- A conversion run blocking Detect changes / Re-index / faces jobs.
- A video request ever stored by the service worker or the image cache.
- Live Photo motion clips appearing as separate videos in the timeline.
- HEVC tagged `hev1` or without fast-start (Safari: black frame / waits for whole file).

## Constraints

- Server is Swift (Hummingbird 2, GRDB) on Apple Silicon macOS 15+. Mac app launched at login has no
  Homebrew `PATH`.
- iPhone Safari only plays video served with **HTTP byte ranges** (`206 Partial Content`). Today
  `assets/:id/original` and derivative routes answer `200` with the full body.
- Safari plays H.264 and HEVC (`hvc1`) in MP4/MOV, HEVC 10-bit HLG as HDR; not VP9 outside WebM.
- AVFoundation cannot decode VP9 on this Mac (tested), so VP9 needs ffmpeg for both preview and
  poster frame.
- Catalog/API changes need the API version bump (app asks to reload on mismatch).

## Approaches considered

- **A. Originals only, byte-range streaming.** Simplest, no dependency. Rejected: 23 VP9 videos
  unplayable on Apple devices; 4K at ~40 Mbps stutters on cellular over Tailscale.
- **B. Original when playable, else a 1080p HEVC preview via ffmpeg.** ← **chosen**, with the
  owner's change: previews are made **on first open** (not after every scan) plus a manual
  "Convert all" in Settings.
- **C. Live transcoding (HLS) at play time.** No storage, but every first play waits and it is far
  more machinery. Rejected: storing ≈350 MB is cheap for this library.

## Design

### Indexing

- Scanner adds video extensions: `mov`, `mp4`, `m4v`, `3gp`, `avi`, `mkv`, `webm` (anything else
  still counted as "other").
- **Live Photo motion is skipped** (counted separately as "Live Photo videos skipped"): a video is
  motion if a still with the same basename exists in the same folder (case-insensitive, e.g.
  `IMG_0300.jpg` + `IMG_0300.MP4`), **or** its QuickTime `com.apple.quicktime.content.identifier`
  matches a still's Apple content identifier (Apple MakerNote, key `17` in
  `kCGImagePropertyMakerAppleDictionary`). Real videos in the probe never match either test.
  - Stills get a new `contentId` column filled by the image probe. Existing photos are filled by a
    re-index (the owner is fine with a full rescan); the migration should make the next Detect
    changes / Re-index re-probe photos whose `contentId` was never read.
  - The basename test stays because Takeout JPGs may have lost the maker note, and the ID test
    catches pairs whose names differ (e.g. after renaming or "IMG_0040 Copy.heic").
  - Ordering: a video is classified after the stills in its scan, so a pair found in one pass is
    never briefly shown as a video.
- Probe via AVFoundation (`AVURLAsset`: dimensions with rotation applied, duration, codec, creation
  date `com.apple.quicktime.creationdate`, GPS `com.apple.quicktime.location.ISO6709`, make/model).
  Fallback to `ffprobe` when AVFoundation can't read it. Takeout `.json` sidecars apply as for photos
  (`IMG_0309.MOV.json`), same precedence: sidecar → embedded metadata → file mtime.
- New asset columns: `kind` (`photo`|`video`), `duration` (seconds, double), `videoCodec`,
  `servePlan` (`original`|`preview`). `servePlan = original` iff codec is H.264 or HEVC, container
  MOV/MP4/M4V, and short side ≤ 1080; otherwise `preview`.
- Content hash and dedup as for photos.
- Places: yes (from GPS). Faces: skipped for videos. Search: as photos.

### Poster, thumbnail, blurhash

- A poster frame (at ~1 s or the first frame for shorter clips) is grabbed with
  `AVAssetImageGenerator`, falling back to ffmpeg (`-ss 1 -frames:v 1`) for VP9 etc. It feeds the
  existing `thumb` and `preview` image derivatives and the BlurHash, so the grid, Download and the
  image cache treat it exactly like a photo's images. These are made in the background after scans
  like photo derivatives (cheap: one frame).
- Without ffmpeg, VP9 videos get no poster: the grid shows a neutral tile with a video glyph.

### Video previews (conversion)

- Tool: **ffmpeg**, looked up at `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, then `PATH`.
- Command shape (builder tunes):
  `ffmpeg -i SRC -map 0:v:0 -map 0:a:0? -vf scale=<short side 1080, keep aspect> -c:v hevc_videotoolbox
  -b:v 4M -tag:v hvc1 -c:a aac -b:a 128k -movflags +faststart -map_metadata -1 OUT.tmp.mp4`, then
  atomic rename to `<data>/cache/video/<id>.mp4`.
  - HLG sources: `-profile:v main10 -pix_fmt p010le` and keep bt2020 / arib-std-b67 colour tags so
    they stay HDR. Dolby Vision metadata is dropped (plays as HLG).
  - Sources already ≤1080 but unplayable (VP9): no scaling, just re-encode.
  - Rotation: ffmpeg's autorotate; output has no rotation flag.
- One shared **conversion queue** (separate from `JobRunner`, so scans are never blocked), at most
  1 conversion at a time (hardware encoder). On-demand requests jump ahead of "Convert all" work.
  A request for a video already converting attaches to the running conversion.
- Progress per video (from ffmpeg `-progress`) is kept in memory for the UI.
- Failure (corrupt file, ffmpeg missing) is remembered per asset (`videoError`) and shown; retried
  only by "Convert all" or a re-index.
- "Rebuild caches" deletes video previews too; "Purge missing" removes those of purged assets.

### Settings: Videos section

```
Videos
66 videos · 61 need a preview · 18 converted (120 MB)
[ Convert all 43 ]                     ← idle
Converting 7 of 43 · IMG_0320.MOV 40%  [ Pause ]   ← running
Paused · 7 of 43 done                  [ Resume ]  ← paused
ffmpeg not found — install with `brew install ffmpeg` (VP9 videos can't play without it; 4K videos play full size)
```

- Pause = finish nothing more after stopping the current ffmpeg process (kill it, discard temp).
  Resume = start again; already-converted videos are skipped, so it continues where it left off.
- Run state lives in memory only: after a server restart the section is back to idle
  ("Convert all 36"), and starting it again skips what's already converted. *(Call.)*
- On-demand conversion still works while "Convert all" is paused.

### Serving

- `GET api/assets/:id/video` → the file to play:
  - `servePlan = original`: the original.
  - `servePlan = preview`, preview exists: the preview.
  - `servePlan = preview`, preview missing: **wait for the preview** (owner's decision) — returns
    `202` with `{progress}` and enqueues it on demand; `GET api/assets/:id/video/status` polls.
  - Fallback *(call)*: if ffmpeg is missing or this video's conversion failed, and the original is
    Safari-playable (H.264/HEVC `hvc1` in MOV/MP4 — i.e. the 4K iPhone clips), serve the original
    instead, so those never become unplayable. VP9 with no preview gets a "Can't play this video
    here — Download" state.
- **Byte-range support** (`Range`, `206`, `Content-Range`, `Accept-Ranges: bytes`) on this route and
  on `assets/:id/original`. Correct `Content-Type` (`video/mp4`, `video/quicktime`).
- Cache headers: preview `private, max-age=31536000, immutable` keyed by a version query param;
  originals as today.

### Live Photos *(added at approval, owner's request)*

- The motion clips found by the Live Photo detection above are **not** assets: they're stored as
  the still's motion file (its own row linked to the photo asset, with path/size/mtime/root; exact
  shape left to the builder). They follow the still: purged with it, re-linked when rescanned.
  A Takeout duplicate of the photo keeps whichever motion file the scan finds first.
- Served by `GET api/assets/:id/motion` with byte ranges; never in Download or the device cache.
- **Always the original clip** if Safari can play it (HEVC/H.264 — all 93 in the library), even
  though they're above 1080p: they're 2–4 s and a few MB, and waiting for a conversion would break
  press-and-hold. Unplayable motion (rare) converts through the same queue as videos, on demand.
- **Editing:** the motion clip is untouched by edits. An edited Live Photo still plays its original,
  unedited motion (owner's decision); Revert changes nothing about motion.
- Catalog carries `hasMotion` per asset (API version bump).
- **Viewer** *(calls)*: a "LIVE" badge at the top-left of the photo. On the iPhone, press and hold
  the photo to play the motion with sound, release to return to the still; on desktop, hover the
  LIVE badge (or press and hold the photo). The clip is preloaded once the photo has been on screen
  a moment, so playback starts instantly. Not while zoomed in; not offline (badge greyed). No
  autoplay on swipe, no badge in the grid.

### Web app

- Catalog delta carries `kind`, `duration`, `servePlan`, and whether a preview is ready. API version
  bump.
- Grid: duration badge bottom-right on video thumbs.
- Viewer: for a video, the poster (preview image) is shown, then a `<video playsinline controls>`
  pointing at `api/assets/:id/video`. Swipe left/right and swipe-down-to-close keep working; pinch
  zoom and Edit are disabled for videos. Starts playing when opened if the browser allows it,
  otherwise shows a play button.
- First open of an unconverted video: poster with "Preparing video… 40%" (polling status), then
  plays. Leaving the viewer doesn't cancel the conversion.
- Info panel: duration, resolution, codec, file size; Download offers the original.
- **Service worker**: never intercepts `api/assets/*/video` or `…/original` (they already fall
  through to the network; add an explicit guard so a future change can't cache them). Image cache
  and Download skip video files; posters/thumbs are cached like photo images.
- Offline: opening a video shows the poster with "Video needs a connection".

## Left to the builder

- Exact ffmpeg bitrate/scale/HDR flags (verify playback on iPhone Safari, incl. an HLG clip).
- Whether Hummingbird's `FileIO` range loading is used or a small custom range reader.
- Status polling vs. long-poll for "Preparing video".
- Poster frame time and fallback.
- Migrations and the exact column names.
