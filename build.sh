#!/bin/zsh
# Builds Halo.app next to this script. Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP=Halo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

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
