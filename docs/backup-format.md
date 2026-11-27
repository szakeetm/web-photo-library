# Backup format

Backups (Settings → Backup) hold what can't be rebuilt: the database and the uploads. Thumbnails,
previews and the library sources themselves are not in them.

## Layout

At the backup destination (any rclone path, e.g. `pcloud:Photos/webLibrary_backup`):

| Path | What |
|---|---|
| `library.sqlite.lzfse` | A consistent copy of the database (`VACUUM INTO`), compressed with LZFSE (built into macOS; about half the size): catalog, albums, edits, adjusted dates, trims, people and faces, places, settings. Unpack by hand with `compression_tool -decode -a lzfse -i library.sqlite.lzfse -o library.sqlite`. Format 1 had a plain `library.sqlite` instead (removed by the next format 2 backup). |
| `uploads/…` | The uploads folder, kept the same (`rclone sync`; hidden files and folders left out) |
| `manifest.json` | Written last: a backup with a manifest is complete |

The same names are written each time; a destination that keeps versions (pCloud's 30-day rewind,
S3 versioning…) keeps the earlier backups.

## manifest.json

| Field | Meaning |
|---|---|
| `version` | The backup format (below) |
| `createdAt`, `serverVersion` | When, and by which server version |
| `migrations` | The database's applied migrations (its schema) |
| `databaseBytes`, `assets`, `albums` | What the database holds (`databaseBytes`: its size unpacked) |
| `databaseFile`, `databaseStoredBytes` | The database's file in the backup and its compressed size (format 2; absent in format 1, whose file is `library.sqlite`) |
| `sources` | The library sources the photos come from (`root`, `kind`: `local` or `rclone`, `path`, file count, 20 sample files with their sizes) |
| `uploadsPath`, `uploadsFiles`, `uploadsBytes` | The uploads backed up |

## Versions and compatibility

Two things decide whether a backup can be restored, and Restore checks both before anything is
changed:

1. **The backup format** (`version`, `BackupFormat` in `server/Sources/PhotoCore/Backup/BackupService.swift`):
   the layout of the backup and the manifest.
   - A backup in a format newer than the server's is refused ("update the server first").
   - A backup older than `BackupFormat.oldestRestorable` is refused, with the reason from `BackupFormat.breaking`.
2. **The database schema** (`migrations`): a database is migrated forward when it's opened, so a backup
   from an older server restores into a newer one. A database with a migration this server doesn't know
   (made by a newer server) is refused.

Restore also checks that each source in `sources` is still where it was (its sample files at the same
paths with the same sizes), so a restored catalog doesn't point at folders that moved.

### Rules when changing things

- **Database change:** add a migration, as usual. Nothing else: older backups migrate forward, newer
  ones are refused by their migrations.
- **Backup layout or manifest change** that this server can still read in older backups: bump
  `BackupFormat.current` and describe it in the history below.
- **A change that makes older backups unrestorable** (a migration that can't run on old data, a layout
  this server no longer reads): bump `BackupFormat.current`, raise `BackupFormat.oldestRestorable` to it,
  add the reason to `BackupFormat.breaking` (shown when such a restore is refused), and add it here.
  Prefer keeping older formats readable instead.

## History

| Format | Server | Change | Breaking |
|---|---|---|---|
| 1 | 0.1.0 (2026-11-26) | First format: `library.sqlite`, `uploads/` (synced), `manifest.json` with sources and samples | — |
| 2 | 0.1.0 (2026-11-27) | The database is compressed: `library.sqlite.lzfse`, named in the manifest's `databaseFile` | — (format 1 backups still restore) |

No breaking changes so far: every backup can be restored by the current server.
