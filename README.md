# Halo

A tiny macOS menu bar app for converting images while you drag them.

1. Start dragging one or more images (Finder, Desktop…).
2. Tap **⇧** for the **Convert** wheel (PNG, JPG, HEIC, AVIF, TIFF, GIF, BMP, PDF) or **⌘** for the **Tools** wheel (resize 75/50/25%, fit 1920px, compress, strip metadata).
3. Drop on a slice. The result is saved next to the original; nothing is overwritten. Drop in the centre to cancel.

No Accessibility or Input Monitoring permission is needed: mouse buttons, modifier keys and the drag pasteboard are polled.

## Build

```sh
./build.sh        # produces Halo.app (ad-hoc signed, arm64, macOS 13+)
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

Actions: any format name, `pdf`, `scaleNN`, `fit`, `compress`, `strip`.

## Layout

- `Sources/main.swift` — app delegate, menu bar item, CLI test mode
- `Sources/DragWatcher.swift` — detects file drags and ⇧/⌘ taps
- `Sources/Wheel.swift` — radial wheel panel, drop target, SwiftUI view
- `Sources/ImageOps.swift` — ImageIO/PDFKit conversions

## Known limitations

- WebP can be read but not written (macOS ImageIO has no WebP encoder).
- Only the first frame of animated GIFs / multi-page images is used.
