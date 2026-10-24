#!/bin/zsh
# Builds Halo.app next to this script. Usage: ./build.sh [--install]
# --install also quits the running Halo, replaces /Applications/Halo.app and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=false
[[ "${1:-}" == "--install" ]] && INSTALL=true

APP=Halo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: scale the 1024px master into an iconset and pack it as .icns.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Assets/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Assets/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# libwebp (brew install webp) is linked statically so the app runs without Homebrew.
WEBP="${WEBP_PREFIX:-$(brew --prefix webp 2>/dev/null || echo /opt/homebrew/opt/webp)}"
if [[ ! -f "$WEBP/lib/libwebp.a" ]]; then
  echo "libwebp not found. Install it with: brew install webp" >&2
  exit 1
fi

swiftc -O -swift-version 5 -target arm64-apple-macos26 \
  -import-objc-header Sources/WebP-Bridging.h -Xcc -I"$WEBP/include" \
  Sources/*.swift "$WEBP/lib/libwebpmux.a" "$WEBP/lib/libwebp.a" "$WEBP/lib/libsharpyuv.a" \
  -o "$APP/Contents/MacOS/Halo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Halo</string>
  <key>CFBundleDisplayName</key><string>Halo</string>
  <key>CFBundleIdentifier</key><string>local.halo.imageconverter</string>
  <key>CFBundleExecutable</key><string>Halo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"

if $INSTALL; then
  DEST=/Applications/Halo.app
  if pgrep -xq Halo; then
    osascript -e 'quit app id "local.halo.imageconverter"' 2>/dev/null || true
    # Give it a few seconds to quit cleanly before forcing it.
    for _ in {1..20}; do pgrep -xq Halo || break; sleep 0.25; done
    pkill -x Halo 2>/dev/null || true
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
