#!/bin/bash
# Builds "Tessy Link.app" from the SwiftPM release binary.
set -e
cd "$(dirname "$0")"
APPNAME="Tessy Link"
BIN="TessyLink"
BUILDDIR=".build/release"
APP="$APPNAME.app"

/usr/bin/xcrun swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILDDIR/$BIN" "$APP/Contents/MacOS/$BIN"

# SwiftPM resource bundle(s)
for b in "$BUILDDIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# Icon -> .icns
if [ -f icon_1024.png ]; then
  ISET="AppIcon.iconset"; rm -rf "$ISET"; mkdir "$ISET"
  for s in 16 32 128 256 512; do
    d=$((s*2))
    sips -z $s $s icon_1024.png --out "$ISET/icon_${s}x${s}.png" >/dev/null
    sips -z $d $d icon_1024.png --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
  done
  cp icon_1024.png "$ISET/icon_512x512@2x.png"
  iconutil -c icns "$ISET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ISET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tessy Link</string>
  <key>CFBundleDisplayName</key><string>Tessy Link</string>
  <key>CFBundleIdentifier</key><string>com.mhernando.tessylink</string>
  <key>CFBundleExecutable</key><string>TessyLink</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc code signature -> stable identity so TCC permissions stick
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "BUILT:$APP"
