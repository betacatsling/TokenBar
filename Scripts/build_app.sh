#!/bin/bash
# Builds TokenBar.app — a self-contained menu bar bundle.
#
# Uses SwiftPM + the Command Line Tools SDK only; no Xcode project is required.
# Produces:
#   dist/TokenBar.app     double-clickable app bundle
#   dist/tokenbar         the raw binary (also usable as `tokenbar --verify`)

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DIST="$ROOT/dist"
APP="$DIST/TokenBar.app"

echo "==> Building release binary"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/TokenBar"
if [ ! -f "$BIN" ]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/TokenBar"
cp "$ROOT/Sources/TokenBar/Resources/remote_collect.py" "$APP/Contents/Resources/"

# SwiftPM emits the resource bundle next to the binary; the app needs it for
# Bundle.module lookups.
BIN_DIR="$(dirname "$BIN")"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TokenBar</string>
    <key>CFBundleDisplayName</key>
    <string>TokenBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.tokenbar</string>
    <key>CFBundleExecutable</key>
    <string>TokenBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Accessory app: menu bar only, no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature keeps macOS from re-prompting on every launch.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "note: ad-hoc codesign skipped"

# Also expose the bare binary for the --verify harness.
cp "$BIN" "$DIST/tokenbar"

echo "==> Done"
echo "    app:    $APP"
echo "    binary: $DIST/tokenbar"
echo
echo "Launch with:  open '$APP'"
echo "Verify with:  '$DIST/tokenbar' --verify"
