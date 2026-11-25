#!/bin/zsh
# Builds PhotoServer.app: a menu bar app that runs the server and opens the photos.
#
#   scripts/build-app.sh             # build web + server + helper, assemble mac/build/PhotoServer.app
#   scripts/build-app.sh --install   # ...and copy it to ~/Applications (quits a running copy first)
#   scripts/build-app.sh --no-build  # reuse existing web/build and server release build
#
# Signing: uses $SIGN_IDENTITY if set (keeps Full Disk Access across rebuilds), else ad-hoc.
set -euo pipefail
REPO=${0:A:h:h}
INSTALL=0 BUILD=1
for a in "$@"; do
	case $a in
		--install) INSTALL=1 ;;
		--no-build) BUILD=0 ;;
		*) echo "unknown option: $a" >&2; exit 2 ;;
	esac
done

if (( BUILD )); then
	(cd $REPO/web && npm run build)
	(cd $REPO/server && swift build -c release)
fi
(cd $REPO/mac && swift build -c release)

SERVER_BIN=$REPO/server/.build/release
[[ -x $SERVER_BIN/PhotoServer && -f $REPO/web/build/index.html ]] || { echo "Missing server or web build." >&2; exit 1; }

APP=$REPO/mac/build/PhotoServer.app
rm -rf $APP
mkdir -p $APP/Contents/{MacOS,Helpers,Resources}
cp $REPO/mac/.build/release/PhotoServerApp $APP/Contents/MacOS/
cp $SERVER_BIN/PhotoServer $APP/Contents/Helpers/
# SwiftPM resource bundles are looked up next to the executable.
for b in $SERVER_BIN/*.bundle(N); do cp -R $b $APP/Contents/Helpers/; done
cp -R $REPO/web/build $APP/Contents/Resources/web

# App icon from the web app's icon.
ICONSET=$(mktemp -d)/AppIcon.iconset && mkdir -p $ICONSET
SRC=$REPO/web/static/icons/icon-512.png
for s in 16 32 128 256 512; do
	sips -z $s $s $SRC --out $ICONSET/icon_${s}x${s}.png >/dev/null
	(( s <= 256 )) && sips -z $((s*2)) $((s*2)) $SRC --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
cp $SRC $ICONSET/icon_512x512@2x.png
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns

VERSION=$(sed -n 's/.*serverVersion = "\(.*\)".*/\1/p' $REPO/server/Sources/PhotoAPI/*.swift | head -1)
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>local.photoserver.app</string>
	<key>CFBundleName</key><string>Photo Server</string>
	<key>CFBundleDisplayName</key><string>Photo Server</string>
	<key>CFBundleExecutable</key><string>PhotoServerApp</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION:-0.0.0}</string>
	<key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
	<key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
EOF

IDENTITY=${SIGN_IDENTITY:--}
for b in $APP/Contents/Helpers/*.bundle(N); do codesign --force --sign $IDENTITY $b; done
codesign --force --options runtime --sign $IDENTITY $APP/Contents/Helpers/PhotoServer
codesign --force --options runtime --sign $IDENTITY $APP
codesign --verify --strict $APP
echo "Built $APP (signed: ${SIGN_IDENTITY:-ad-hoc})"

if (( INSTALL )); then
	DEST=$HOME/Applications/PhotoServer.app
	osascript -e 'tell application id "local.photoserver.app" to quit' 2>/dev/null || true
	for _ in {1..50}; do pgrep -f "$DEST/Contents/MacOS/PhotoServerApp" >/dev/null || break; sleep 0.2; done
	mkdir -p $HOME/Applications
	rm -rf $DEST && cp -R $APP $DEST
	echo "Installed $DEST"
fi
