# Halo

A tiny macOS menu bar app for converting images while you drag them.

1. Start dragging one or more images (Finder, Desktop…).
2. Tap **⇧** for the **Convert** wheel (PNG, JPG, HEIC, WebP, AVIF, TIFF, GIF, BMP, PDF) or **⌘** for the **Tools** wheel (resize 75/50/25%, fit 1920px, compress, strip metadata, trim borders, crop…). **Crop…** opens a small window: drag to draw or move the selection, pick an aspect ratio, press Return to save.
3. Drop on a slice. The result is saved next to the original; nothing is overwritten. Drop in the centre to cancel.

No Accessibility or Input Monitoring permission is needed: mouse buttons, modifier keys and the drag pasteboard are polled.

## Build

Needs Xcode and libwebp (`brew install webp`). libwebp is linked statically, so the built app doesn't need Homebrew to run.

```sh
./build.sh        # produces Halo.app (ad-hoc signed, arm64, macOS 26+)
open Halo.app
```

Copy `Halo.app` to `/Applications` before turning on **Launch at Login**.

## Headless testing

```sh
Halo.app/Contents/MacOS/Halo --run png  photo.jpg
Halo.app/Contents/MacOS/Halo --run scale50 photo.jpg
Halo.app/Contents/MacOS/Halo --run pdf a.jpg b.png
Halo.app/Contents/MacOS/Halo --demo tools      # show the wheel for a few seconds
```

Actions: any format name, `pdf`, `scaleNN`, `fit`, `compress`, `strip`, `trim`, `crop:x,y,w,h` (fractions, origin top-left).

## Layout

- `Sources/main.swift` — app delegate, menu bar item, CLI test mode
- `Sources/DragWatcher.swift` — detects file drags and ⇧/⌘ taps
- `Sources/Wheel.swift` — radial wheel panel, drop target, SwiftUI view
- `Sources/ImageOps.swift` — ImageIO/PDFKit conversions, trim and crop
- `Sources/WebP.swift`, `Sources/WebP-Bridging.h` — WebP encoding via libwebp
- `Sources/CropWindow.swift` — interactive crop window

## Known limitations

- WebP output doesn't carry EXIF metadata and is limited to 16383px per side.
- macOS 26+ only, because Homebrew's libwebp is built for macOS 26.
- Only the first frame of animated GIFs / multi-page images is used.
