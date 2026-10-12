#!/bin/bash
# Builds a universal (arm64 + x86_64) BuildGate.app and packs it into a DMG.
# Usage: ./build-dmg.sh   -> dist/BuildGate-<ver>.dmg   (VER=1.2.0 BUNDLE_ID=... to override)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VER="${VER:-1.0}"
BUNDLE_ID="${BUNDLE_ID:-com.deanoss.buildgate}"
OUT="$ROOT/dist"
APP="$OUT/BuildGate.app"
TMP="$OUT/tmp"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

echo "==> gate binary (universal)"
(cd "$ROOT/src" &&
  GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags=-s -o "$TMP/gate-arm64" . &&
  GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags=-s -o "$TMP/gate-amd64" .)
lipo -create -output "$APP/Contents/Resources/buildgate" "$TMP/gate-arm64" "$TMP/gate-amd64"

echo "==> menu bar app (universal)"
for arch in arm64 x86_64; do
  xcrun swiftc -parse-as-library -swift-version 5 -O -target "$arch-apple-macos14" \
    "$ROOT/app/BuildGate.swift" -o "$TMP/app-$arch"
done
lipo -create -output "$APP/Contents/MacOS/BuildGate" "$TMP/app-arm64" "$TMP/app-x86_64"

echo "==> icon"
xcrun swift "$ROOT/app/make-icon.swift" "$TMP/icon.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>BuildGate</string>
<key>CFBundleDisplayName</key><string>BuildGate</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>BuildGate</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>$VER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHumanReadableCopyright</key><string>Limits how many builds run at once</string>
</dict></plist>
PLIST

echo "==> sign (ad-hoc)"
codesign --force -s - "$APP/Contents/Resources/buildgate"
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"

# hdiutil sometimes fails with "Resource busy" (common on CI runners).
retry() { for i in 1 2 3 4 5; do "$@" && return 0; echo "retry $i: $*" >&2; sleep 3; done; return 1; }

echo "==> dmg"
STAGE="$TMP/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/BuildGate-$VER.dmg"
# Volume icon: build read-write, set the custom-icon flag, then compress.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
RW="$TMP/rw.dmg"
retry hdiutil create -quiet -volname "BuildGate" -srcfolder "$STAGE" -ov -format UDRW "$RW"
MNT=$(retry hdiutil attach -nobrowse -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
SetFile -a C "$MNT" 2>/dev/null || xcrun SetFile -a C "$MNT"
retry hdiutil detach -quiet "$MNT"
retry hdiutil convert -quiet "$RW" -format UDZO -o "$DMG" -ov
# Icon on the .dmg file itself (Finder/Downloads)
cat > "$TMP/seticon.swift" <<SWIFT
import AppKit
NSWorkspace.shared.setIcon(NSImage(contentsOfFile: CommandLine.arguments[1]), forFile: CommandLine.arguments[2], options: [])
SWIFT
xcrun swift "$TMP/seticon.swift" "$APP/Contents/Resources/AppIcon.icns" "$DMG"
rm -rf "$TMP"
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
