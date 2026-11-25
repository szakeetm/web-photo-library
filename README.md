# Web Photo Library

A self-hosted, Apple Photos–style photo library. A Mac serves a read-only folder of images
to a web app (desktop + iPhone PWA) over Tailscale. See
[`docs/superpowers/specs/2026-11-25-photo-server-design.md`](docs/superpowers/specs/2026-11-25-photo-server-design.md).

## Layout
- `server/` — Swift package (`PhotoCore` library + `PhotoServer` executable)
- `web/` — SvelteKit single-page app

## Develop
```sh
cd server && swift test -j 1     # server tests (-j 1: CLT macro plugin is flaky with parallel jobs)
cd web && npm install && npm run build
cd server && WEB_ROOT=../web/build swift run PhotoServer   # http://127.0.0.1:8787
```
