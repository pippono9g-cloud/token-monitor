#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
APP_DIR="$ROOT_DIR/TokenMonitor.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/TokenMonitor"
RESOURCES="$APP_DIR/Contents/Resources"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"

mkdir -p "$APP_DIR/Contents/MacOS" "$RESOURCES" "$MODULE_CACHE"
rm -f "$APP_DIR/Contents/MacOS/Token Monitor"
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"
cp "$ROOT_DIR/index.html" "$RESOURCES/index.html"
cp "$ROOT_DIR/styles.css" "$RESOURCES/styles.css"
cp "$ROOT_DIR/app.js"     "$RESOURCES/app.js"

# ── Build app icon ────────────────────────────────────────────────
ICON_PNG="$MODULE_CACHE/icon_1024.png"
ICONSET="$MODULE_CACHE/AppIcon.iconset"
ICNS="$RESOURCES/AppIcon.icns"

clang -fobjc-arc "$MAC_DIR/generate_icon.m" -framework Cocoa -o "$MODULE_CACHE/generate_icon"
"$MODULE_CACHE/generate_icon" "$ICON_PNG"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
# Retina variants
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -z $double $double "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
if ! iconutil --convert icns "$ICONSET" --output "$ICNS"; then
  if [[ -f "$ICNS" ]]; then
    echo "warning: iconutil failed; keeping existing AppIcon.icns" >&2
  else
    exit 1
  fi
fi

# ── Info.plist ────────────────────────────────────────────────────
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>local.token-monitor.app</string>
  <key>CFBundleName</key>
  <string>TokenMonitor</string>
  <key>CFBundleDisplayName</key>
  <string>Token Monitor</string>
  <key>CFBundleExecutable</key>
  <string>TokenMonitor</string>
  <key>CFBundleShortVersionString</key>
  <string>1.5.1</string>
  <key>CFBundleVersion</key>
  <string>1.5.1</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# ── Build main executable ─────────────────────────────────────────
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" clang \
  -fobjc-arc \
  "$ROOT_DIR/mac/TokenMonitorApp/main.m" \
  -framework Cocoa \
  -framework WebKit \
  -framework ServiceManagement \
  -o "$EXECUTABLE"

chmod +x "$EXECUTABLE"
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
