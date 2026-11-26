#!/bin/zsh
# Regenerates docs/screenshots from the demo library (stock photos, see CREDITS.md).
#
#   cd web && npm run build && cd ../server && swift build -c release && cd ..
#   demo/take-screenshots.sh [name,name,...]     # e.g. desktop-editor,mobile-editor
#   PHONE=none KEEP=1 demo/take-screenshots.sh     # desktop only, server left running (iPhone shots
#                                                  # taken in the iOS Simulator against it, see below)
#
# The library is copied to /Users/Shared/PhotoDemo so no personal paths show up in Settings.
# A throwaway server instance (own data dir, free port) is started and stopped again.
set -euo pipefail
REPO=${0:A:h:h}
DEMO=${DEMO_DIR:-/Users/Shared/PhotoDemo}
PORT=${PORT:-8833}
# BIN / WEB let a test build be used instead of the one a running server is serving.
BIN=${BIN:-$REPO/server/.build/release/PhotoServer}
WEB=${WEB:-$REPO/web/build}
BASE=http://127.0.0.1:$PORT

if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null; then
	echo "Port $PORT is in use; set PORT=..." >&2; exit 1
fi
[[ -x $BIN && -d $WEB ]] || { echo "Build the web app and the server first." >&2; exit 1; }

rm -rf $DEMO && mkdir -p $DEMO/Uploads $DEMO/upload-samples
cp -R $REPO/demo/Library $DEMO/Library
cp $REPO/demo/upload-samples/* $DEMO/upload-samples/
# An upload that's already in the library, to show de-duplication.
cp "$(ls $DEMO/Library/Dolomites/*.jpg | head -1)" $DEMO/upload-samples/IMG_from_phone.jpg
# A smaller re-saved copy of a library photo in the uploads, to show Duplicates.
mkdir -p $DEMO/Uploads/phone-uploads/2024-07
DUP=$(ls $DEMO/Library/Dolomites/*.jpg | sed -n 3p)
sips -Z 1000 -s formatOptions 70 "$DUP" --out "$DEMO/Uploads/phone-uploads/2024-07/${DUP:t:r}-small.jpg" >/dev/null
# A short video (a slow pan over a coast photo) to show videos and trimming.
if command -v ffmpeg >/dev/null; then
	ffmpeg -loglevel error -y -loop 1 -i "$DEMO/Library/Coast Trip/IMG_4208.jpg" -t 12 -r 30 \
		-vf "scale=3840:-2,zoompan=z='1.15':x='iw/2-(iw/zoom/2)+(on-180)*3':y='ih/2-(ih/zoom/2)':d=1:s=1920x1080:fps=30,format=yuv420p" \
		-c:v libx264 -crf 23 "$DEMO/Library/Coast Trip/IMG_4209.MOV"
fi

PHOTOSERVER_HOME=$DEMO/Data PORT=$PORT WEB_ROOT=$WEB $BIN >$DEMO/server.log 2>&1 &
SERVER=$!
[[ -n ${KEEP:-} ]] || trap 'kill $SERVER 2>/dev/null' EXIT
for _ in {1..50}; do curl -sf $BASE/api/health >/dev/null && break; sleep 0.2; done

api() { curl -sf -X $1 $BASE/api/$2 -H 'content-type: application/json' ${3:+-d} ${3:-} >/dev/null; }
idle() { until ! curl -sf $BASE/api/jobs | grep -q '"state":"\(queued\|running\)"'; do sleep 0.5; done; }
api PUT settings "{\"libraryPath\":\"$DEMO/Library\",\"uploadsPath\":\"$DEMO/Uploads\"}"
api POST jobs/detect-changes; sleep 1; idle
api POST jobs/import-takeout-albums; sleep 1; idle
api POST jobs/objects; sleep 1; idle
# the demo video is dated with the trip (Adjust Date & Time) and shown trimmed (2–9 s of 12)
VID=$(curl -sf $BASE/api/catalog | python3 -c "import json,sys;print(next((a['id'] for a in json.load(sys.stdin)['assets'] if a['name']=='IMG_4209.MOV'),''))")
if [[ -n $VID ]]; then
	api PATCH assets/meta "{\"ids\":[\"$VID\"],\"change\":{\"setTo\":\"2025-07-14T13:02:14Z\",\"tzOffset\":7200}}"
	api PUT assets/$VID/trim '{"start":2,"end":9}'
fi
# faces (if the model is installed in the demo data dir) run after the scan
if [[ -n ${FACE_MODEL:-} ]]; then
	mkdir -p $DEMO/Data/models && cp -R $FACE_MODEL $DEMO/Data/models/FaceNet.mlpackage
	api POST jobs/faces; sleep 1; idle
	node $REPO/demo/name-people.mjs $BASE
fi

cd $REPO/demo
[[ -d node_modules ]] || npm install --silent
OUT=$DEMO/shots && mkdir -p $OUT
node screenshots.mjs $BASE $OUT $DEMO/upload-samples ${1:-}
for f in $OUT/*.png; do
	sips -s format jpeg -s formatOptions 82 $f --out $REPO/docs/screenshots/${f:t:r}.jpg >/dev/null
done
echo "Updated: $(cd $OUT && ls *.png | sed 's/\.png$//' | tr '\n' ' ')"
