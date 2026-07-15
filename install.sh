#!/bin/bash
# Tessy Link installer.
# Downloads the latest prebuilt app, removes the download quarantine so it opens
# without a Gatekeeper warning, installs it to /Applications, and launches it.
set -e
echo "Installing Tessy Link…"
URL="https://github.com/mattchernando/tessy-link/releases/latest/download/Tessy-Link.zip"
TMP="$(mktemp -d)"
curl -fsSL -o "$TMP/app.zip" "$URL"
/usr/bin/unzip -oq "$TMP/app.zip" -d "$TMP"
/usr/bin/pkill -f TessyLink 2>/dev/null || true
sleep 1
rm -rf "/Applications/Tessy Link.app"
cp -R "$TMP/Tessy Link.app" "/Applications/"
/usr/bin/xattr -dr com.apple.quarantine "/Applications/Tessy Link.app" 2>/dev/null || true
rm -rf "$TMP"
open "/Applications/Tessy Link.app"
echo ""
echo "Installed. Look for the display icon in your menu bar."
echo "  1) Click it -> Start, and allow Screen Recording (it relaunches once)."
echo "  2) Open https://tessylink.hernandomediallc.com and enter the code shown."
