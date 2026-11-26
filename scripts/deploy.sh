#!/bin/bash
# Rebuilds the server and web app from a git ref and restarts the live server with it.
#
#   scripts/deploy.sh              # latest origin/main
#   scripts/deploy.sh <ref>        # a branch, tag or commit (e.g. main, db99023)
#
# The live server runs from its own checkout (a git worktree in deployed/ inside this repo, git-ignored),
# so work in progress in the main checkout is never served. Everything is built first; the running
# server is only stopped once both builds succeeded. Settings: DEPLOY_DIR, PORT (8787), LOG.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
DEPLOY_DIR=${DEPLOY_DIR:-$REPO/deployed}
PORT=${PORT:-8787}
LOG=${LOG:-$HOME/Library/Logs/PhotoServer.log}
REF=${1:-origin/main}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Fetching"
git -C "$REPO" fetch --quiet origin

if [ ! -d "$DEPLOY_DIR" ]; then
	step "Creating the deploy checkout at $DEPLOY_DIR"
	git -C "$REPO" worktree add --detach "$DEPLOY_DIR" "$REF"
fi

step "Checking out $REF"
cd "$DEPLOY_DIR"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	echo "The deploy checkout has local changes; refusing to overwrite them:" >&2
	git status --short --untracked-files=no >&2
	exit 1
fi
git checkout --quiet --detach "$REF"
git log -1 --format='%h  %s  (%cr)'

step "Building the web app"
cd "$DEPLOY_DIR/web"
# Share the main checkout's dependencies (installed there by npm install).
if [ ! -e node_modules ]; then ln -s "$REPO/web/node_modules" node_modules; fi
npm run build --silent

step "Building the server (release)"
cd "$DEPLOY_DIR/server"
swift build -c release

step "Restarting on port $PORT"
OLD=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN || true)
if [ -n "$OLD" ]; then
	kill $OLD
	for _ in $(seq 1 50); do lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null || break; sleep 0.1; done
fi
mkdir -p "$(dirname "$LOG")"
PORT=$PORT nohup .build/release/PhotoServer >>"$LOG" 2>&1 </dev/null &
disown

for _ in $(seq 1 100); do
	if HEALTH=$(curl -sf "http://127.0.0.1:$PORT/api/health"); then
		echo "$HEALTH"
		WANT=$(git rev-parse --short HEAD)
		case "$HEALTH" in
			*"\"commit\":\"$WANT"*) printf '\n\033[32mRunning %s on http://127.0.0.1:%s\033[0m (log: %s)\n' "$WANT" "$PORT" "$LOG" ;;
			*) echo "Warning: the server reports a different commit than $WANT." >&2 ;;
		esac
		exit 0
	fi
	sleep 0.2
done
echo "The server did not answer on port $PORT; last log lines:" >&2
tail -n 20 "$LOG" >&2
exit 1
