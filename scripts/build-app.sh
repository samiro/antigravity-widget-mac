#!/usr/bin/env bash
# Builds AntigravityWidget.app into ./build (ad-hoc signed).
#
#   scripts/build-app.sh            # release build for this Mac's architecture
#   scripts/build-app.sh --universal  # arm64 + x86_64
#   scripts/build-app.sh --install    # also copy to ~/Applications
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="AntigravityWidget"
DISPLAY_NAME="Antigravity Widget"
BUNDLE_ID="${BUNDLE_ID:-dev.samiro.antigravity-widget}"
VERSION="${VERSION:-0.1.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ $UNIVERSAL == 1 ]]; then
  swift build -c release --product "$APP_NAME" --arch arm64 --arch x86_64
  BIN="$(swift build -c release --product "$APP_NAME" --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
else
  swift build -c release --product "$APP_NAME"
  BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# App icon (generated from code; see scripts/make-icon.swift).
if swift scripts/make-icon.swift "$BUILD_DIR/AppIcon.iconset" >/dev/null 2>&1 \
   && iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "warning: icon generation failed; continuing without an icon" >&2
  ICON_KEY=""
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Reads Antigravity usage data locally. Nothing leaves your Mac.</string>
  $ICON_KEY
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ $INSTALL == 1 ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Installed to $HOME/Applications/$APP_NAME.app"
fi
