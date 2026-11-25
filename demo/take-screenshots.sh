#!/bin/zsh
# Regenerates docs/screenshots from the demo library (stock photos, see CREDITS.md).
#
#   cd web && npm run build && cd ../server && swift build -c release && cd ..
#   demo/take-screenshots.sh [name,name,...]     # e.g. desktop-editor,mobile-editor
#
# The library is copied to /Users/Shared/PhotoDemo so no personal paths show up in Settings.
# A throwaway server instance (own data dir, free port) is started and stopped again.
set -euo pipefail
REPO=${0:A:h:h}
DEMO=${DEMO_DIR:-/Users/Shared/PhotoDemo}
PORT=${PORT:-8833}
BIN=$REPO/server/.build/release/PhotoServer
BASE=http://127.0.0.1:$PORT

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null; then
	echo "Port $PORT is in use; set PORT=..." >&2; exit 1
fi
[[ -x $BIN && -d $REPO/web/build ]] || { echo "Build the web app and the server first." >&2; exit 1; }

rm -rf $DEMO && mkdir -p $DEMO/Uploads $DEMO/upload-samples
cp -R $REPO/demo/Library $DEMO/Library
cp $REPO/demo/upload-samples/* $DEMO/upload-samples/
# An upload that's already in the library, to show de-duplication.
cp "$(ls $DEMO/Library/Dolomites/*.jpg | head -1)" $DEMO/upload-samples/IMG_from_phone.jpg

PHOTOSERVER_HOME=$DEMO/Data PORT=$PORT WEB_ROOT=$REPO/web/build $BIN >$DEMO/server.log 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in {1..50}; do curl -sf $BASE/api/health >/dev/null && break; sleep 0.2; done

api() { curl -sf -X $1 $BASE/api/$2 -H 'content-type: application/json' ${3:+-d} ${3:-} >/dev/null; }
idle() { until ! curl -sf $BASE/api/jobs | grep -q '"state":"\(queued\|running\)"'; do sleep 0.5; done; }
api PUT settings "{\"libraryPath\":\"$DEMO/Library\",\"uploadsPath\":\"$DEMO/Uploads\"}"
api POST jobs/detect-changes; sleep 1; idle
api POST jobs/import-takeout-albums; sleep 1; idle

cd $REPO/demo
[[ -d node_modules ]] || npm install --silent
OUT=$DEMO/shots && mkdir -p $OUT
node screenshots.mjs $BASE $OUT $DEMO/upload-samples ${1:-}
for f in $OUT/*.png; do
	sips -s format jpeg -s formatOptions 82 $f --out $REPO/docs/screenshots/${f:t:r}.jpg >/dev/null
done
echo "Updated: $(cd $OUT && ls *.png | sed 's/\.png$//' | tr '\n' ' ')"
