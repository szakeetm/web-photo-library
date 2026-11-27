# Locked folder — design

Status: planned, not started · 2026-11-27

## Intent

A **Locked** collection, like Google Photos' Locked Folder or Apple Photos' Hidden album. Photos
moved into it disappear from the rest of the app and can only be seen after unlocking with
**Face ID / Touch ID / Windows Hello**, through a passkey (WebAuthn).

What the owner said:
- Unlock with the device's own biometrics.
- **No app PIN.** The device already falls back to its own passcode or password when biometrics fail.

## Threat model (what it does and doesn't protect)

- **Protects against:** someone using your unlocked phone or computer and opening the app.
- **Does not protect against:** someone with access to the Mac's disk. The library folder is
  read-only, so a locked original stays where it is. Its thumbnails and previews in the data location
  are not encrypted either. Locking hides the photo **in the app only**.
- Possible later: move locked *uploads* (which live in the data location) into an encrypted store,
  and encrypt locked previews with a key held only while unlocked. Not in v1.

## Why WebAuthn works here

- WebAuthn needs HTTPS and a real domain name. The app is served by `tailscale serve` on
  `https://<mac>.<tailnet>.ts.net`. `ts.net` is on the Public Suffix List, so the full host is a
  valid relying-party ID (RP ID). Plain `http://` or a bare IP would not work.
- `navigator.credentials.get({ userVerification: "required" })` shows Face ID or Touch ID in Safari,
  including the iPhone Home Screen app. If biometrics fail, the OS falls back to the device
  passcode or password. The server only learns that the user was verified, not how.
- Passkeys sync through iCloud Keychain, so one registered on the iPhone also unlocks on the Mac.
  A device with no synced passkey (for example a Windows PC) can use the browser's
  "use a phone or tablet" option: scan a QR code and approve with Face ID on the iPhone.
- Local mode on `localhost` is a different RP ID and needs its own passkey.
- Safari only shows the prompt after a tap, so unlocking is always started by an **Unlock** button.

## Data

- Migration `v22-locked` (or the next free number): `ALTER TABLE asset ADD COLUMN locked BOOLEAN NOT NULL DEFAULT 0`.
  This is separate from `archived`, which only keeps a photo out of the Library view.
- New table `lockedCredential`: `id` (credential id, base64url), `publicKey` (COSE bytes),
  `signCount`, `name` (for example "iPhone", "MacBook"), `createdAt`, `lastUsedAt`.
- The WebAuthn RP ID and origin come from the request's `Host` (the `ts.net` name or `localhost`),
  checked against a short allow-list in settings.

## Server — enforce it in one place

The filter must live in the server, not the UI. Every place that lists or serves assets leaves
`locked` out unless the request carries a valid unlock token:

- Lists: timeline, albums, folders, favourites, search, people, places and the map, duplicates,
  edited, videos, live, uploads, trash, and every count and badge.
- Single photos by id: thumbnail, preview, original, video stream, Live Photo motion, info,
  edit/export. Return 404 (not 403), so a locked photo looks like it doesn't exist.
- Export and download of albums, folders and selections skip locked photos.
- Add one shared helper (for example in `CatalogService`) that every query uses, plus a test that
  goes over every list endpoint with a locked fixture photo, so a new endpoint can't forget it.
- Face recognition, text-in-photos and duplicate detection may still analyse locked photos, but
  never return them in results while the request is locked.

Library: [swift-server/webauthn-swift](https://github.com/swift-server/webauthn-swift) (works with Hummingbird 2).

### Endpoints

| Endpoint | What |
|---|---|
| `GET  /api/locked/status` | `{ configured, unlocked, expiresAt }` |
| `POST /api/locked/register/begin` · `/finish` | Add a passkey. Needs an unlocked session, **or** a direct local request on the Mac (not proxied: no `X-Forwarded-For`, the same test `OwnerMiddleware` uses). The first passkey can only be added this way or from the owner's Tailscale identity. |
| `POST /api/locked/unlock/begin` · `/finish` | Challenge, then `navigator.credentials.get`, then signature and sign-count check. Sets the unlock cookie. |
| `POST /api/locked/lock` | Ends the session now. |
| `GET/DELETE /api/locked/credentials[/:id]` | List and remove passkeys (unlocked only). |
| `POST /api/locked/reset` | Recovery: remove every passkey. **Direct local request on the Mac only.** Photos stay locked. |
| `POST /api/assets/lock` · `/unlock` | Move photos in or out. Both need an unlocked session. |

### Unlock session

- Random token, kept **in memory only**, so a server restart locks everything.
- Sent as a cookie: `HttpOnly; Secure; SameSite=Strict; Path=/api`.
- Expires after 5 minutes idle (each locked request extends it), with a hard limit of 30 minutes.
- Challenges are single-use and expire after 2 minutes.

### Caching

- Responses for locked photos carry `Cache-Control: no-store`.
- `service-worker.ts` never caches `/api/` responses for locked photos. A response header such as
  `X-Locked: 1` lets the worker see which ones they are. Locking a photo removes its cached
  thumbnails and previews from the worker cache and from offline downloads.

## Web app

- **Locked** page: under the phone's **More** tab and in the desktop sidebar, below Archive.
  - Not set up: a "Set up with Face ID / Touch ID" button. If the request is not local or from the
    owner, it explains that setup is done on the Mac.
  - Locked: a lock icon and an **Unlock** button that calls WebAuthn.
  - Unlocked: the normal grid and viewer, with the time left shown.
- Action bar and viewer: **Move to Locked** (asks for Face ID if not unlocked) and, inside Locked,
  **Remove from Locked**.
- Re-lock as soon as the page is hidden (`visibilitychange` to hidden, `pagehide`): call
  `/api/locked/lock`. Also clear any locked photos from client state, the selection, the viewer
  and history entries, and go back from `/locked` routes.
- Settings → **Locked folder**: list of passkeys (name, last used, remove), "Add this device", and
  on the Mac only, "Reset Locked folder passkeys".
- Client: `@simplewebauthn/browser`, or the plain `navigator.credentials` API with base64url helpers.

## Not in v1

- Encryption at rest (see the threat model).
- An app PIN (the OS fallback covers it; recovery is the local reset on the Mac).
- Locking a whole album or folder (lock its photos instead).
- Importing Google Photos' Locked Folder: Takeout doesn't export it.

## Tests

- Server: a locked fixture photo is missing from every list endpoint and returns 404 by id while
  locked. It appears with a valid token. Expired, reused and forged tokens and challenges are
  rejected. Register and reset are refused for proxied requests without an unlocked session.
- Web: re-lock on `visibilitychange`; nothing locked left in the service worker cache.
- Manually in the iPhone Home Screen app over `ts.net`: setup, Face ID unlock, passcode fallback,
  re-lock when switching apps.
