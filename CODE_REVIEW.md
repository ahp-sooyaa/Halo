# Halo — Code Review

Reviewed: every file under `Sources/`, plus `build.sh` and `README.md`, at commit `42d8539` (2026-10-19).
Line numbers refer to that commit.

**Status (2026-10-19):** the items in the §5 priority list are fixed. Each fixed heading is marked ✅; the rest are still open.

Severity key: **High** = wrong output or lost work a user will hit · **Medium** = real bug in a narrower case, or a weakness that bites on big inputs · **Low** = polish, cleanup, or edge case.

---

## 1. Bugs

### ✅ 1.1 High — Rotated photos come out sideways when converted to WebP (and probably BMP/GIF/PNG)
`Sources/ImageOps.swift:82`, `Sources/WebP.swift:10`

`.convert` loads with `oriented: false`, so the pixels stay in sensor orientation and the result depends on the EXIF orientation tag being copied over. The WebP path (`WebP.encode`) ignores `props` completely, so the tag is lost. ImageIO's BMP and GIF writers have no orientation field either, and PNG support for it is patchy across viewers.

*Scenario:* an iPhone portrait JPEG (orientation 6) → Convert → WebP gives a landscape, sideways image.

*Fix:* bake the rotation in for every action (`oriented: true`), as scale/strip/crop already do. That also lets you remove the `oriented` parameter.

*Fixed:* `load(_:)` always bakes the rotation in. Testing also showed **AVIF** drops the tag. WebP, AVIF, GIF, BMP and PNG output from an orientation-6 JPEG are now upright.

### ✅ 1.2 High — Releasing the mouse on a slice can hide the wheel just as the job starts
`Sources/Wheel.swift:130-132`, `Sources/Wheel.swift:134-189`, `Sources/DragWatcher.swift:40`

`DragWatcher` polls the mouse button at 60 Hz and calls `dragEnded()` as soon as it sees the button up. `performDragOperation` comes separately, as an IPC callback from the drag server. If the poll fires first, `status` is still `.idle`, so `hide()` queues `shown = false` and an `orderOut` 0.18 s later. `perform()` then sets `.working`, but it doesn't bump `generation`, so the queued `orderOut` still runs.

*Scenario:* the user drops on "PNG", the wheel vanishes at once, and the progress/✓ feedback is never shown. If the callback is late enough, the panel can be gone before the drop lands, and the drop fails.

*Fix:* in `perform()`, bump `generation` (cancelling any pending hide), or ignore `dragEnded` while `hovered != nil`. Better still is the state-machine refactor in 3.1.

### ✅ 1.3 Medium — The wheel can stay invisible but still accept drops
`Sources/Wheel.swift:106-113`, `Sources/Wheel.swift:116-127`

`hide()` sets `model.shown = false` right away, then orders the panel out 0.18 s later. If `show()` runs inside that window (for example, the user taps ⌘ just after ⇧ closed the wheel), it bumps `generation`, so the `orderOut` is cancelled. But `panel.isVisible` is still true, so `show()` skips `model.shown = true`. The panel stays on screen at opacity 0 and keeps taking drops for the rest of the drag.

*Fix:* in `show()`, always set `model.shown = true`, not only when the panel was hidden.

### ✅ 1.4 Medium — "Same crop for all" breaks the aspect ratio on images of a different shape
`Sources/CropWindow.swift:63-79`, `Sources/CropWindow.swift:541`, `Sources/CropWindow.swift:576`

The crop is stored as a normalised rect, and the ratio is enforced only against the current image's `pixelSize`. With `sameForAll` on, that same normalised rect is copied to every entry. On an image with a different shape, a 1:1 crop of a 4:3 image becomes a non-square crop of a 16:9 image. The warning banner only says the crop "lands in a different place". It doesn't say the ratio will be wrong.

*Fix:* when sharing, either store the crop in a ratio-aware form and run `conform` per entry using that entry's `pixelSize`, or turn off the shared crop when `shapesDiffer` and an aspect ratio is set.

### ✅ 1.5 Medium — "Show in Finder" on a notification stops working
`Sources/Jobs.swift:156-160`, `Sources/Jobs.swift:119`, `Sources/main.swift:103`

The notification stores only the job ID. Tapping it looks the job up in `JobCenter.jobs`, but that list keeps just the last 5 finished jobs, is emptied by "Clear Finished", and is lost when the app quits. After any of those, tapping the notification does nothing.

*Fix:* put the output paths (or their parent folder) in `userInfo` and reveal straight from those.

### ✅ 1.6 Medium — Decoding can output a 1×1 image
`Sources/ImageOps.swift:138-145`

The oriented path asks for a thumbnail with `max(w, h, 1)` as its size. If the source's properties have no `PixelWidth`/`PixelHeight` (some RAW/odd formats), this asks for a 1-pixel image, and the "resize"/"strip"/"crop" output is a 1×1 file with no error.

*Fix:* if the size is unknown, fall back to `CGImageSourceCreateImageAtIndex` and apply the orientation yourself, or leave out `kCGImageSourceThumbnailMaxPixelSize`.

### ✅ 1.7 Medium — "1920px fit" (and CLI `scale` ≥ 100) writes a copy under a misleading name
`Sources/ImageOps.swift:85-93`, `Sources/ImageOps.swift:177`

`scaled()` returns the original when `factor >= 1`, but `save` still writes "photo 1920px.jpg". For a JPEG source it's also re-encoded, so you get quality loss with no change in size. The CLI's `scale150` likewise writes "photo 150%.png" at the original size.

*Fix:* if no resize is needed, skip the file and report it, as `.trim` does with `nothingToTrim`.

### ✅ 1.8 Medium — Compress can make files bigger and silently drops transparency
`Sources/ImageOps.swift:95-100`

- A JPEG/HEIC that is already compressed is re-encoded at quality 0.6 with no size check, so the "compressed" file can be larger and worse.
- A transparent PNG becomes a JPEG on a white background (`flattened`), and the user isn't told.

*Fix:* compare output and input size, and drop the output (or keep the original) if it isn't smaller. For PNG with alpha, use HEIC/WebP (which keep alpha) or do lossless PNG optimisation.

### 1.9 Low — Cancel can label a job that already finished as "Cancelled"
`Sources/Jobs.swift:48-61`, `Sources/Jobs.swift:151-153`

If Cancel is clicked after the last operation has finished, but before the barrier's `finish` reaches the main queue, `cancelRequested` is already set, so a job that produced every file is shown as "Cancelled". This is cosmetic, but confusing.

### 1.10 Low — Dropping onto Crop… while a crop window is open does nothing
`Sources/Wheel.swift:138`

`guard ..., cropper == nil else { return }` drops the request with no beep and doesn't bring the existing window forward.

### 1.11 Low — The crop failure alert can open behind other apps
`Sources/CropWindow.swift:290-295`

The job finishes after the crop window has closed, so the accessory app is usually not active, and `runModal()` can show up behind Finder. Activate the app first, or use a notification.

### 1.12 Low — The menu doesn't update while it's open
`Sources/main.swift:48-80`

Rows update live, but the list itself is built only in `menuNeedsUpdate`. If a job is added or pruned while the menu is open, or a row's height changes when its progress bar disappears, the menu isn't redrawn.

---

## 2. Weaknesses (quality, performance, robustness)

### Image quality
- ✅ **WebP is always lossy (q 0.85).** A PNG screenshot converted to WebP gets blurry text and edges. Use `WebPEncodeLosslessRGBA` (or `config.lossless`) when the source is lossless. `Sources/WebP.swift:25`
- ✅ (WebP part) **Colour space is flattened to sRGB with no ICC profile.** WebP encoding and `trimRect` draw into sRGB. Display-P3 iPhone photos lose their wide gamut in WebP. `scaled()` keeps the colour space, but `WebP.encode` doesn't embed a profile. `Sources/WebP.swift:14`
- **Bit depth is cut to 8 bits and HDR is dropped.** `scaled()`/`flattened()` use 8-bit RGBA contexts, so 16-bit PNG/TIFF and HDR HEIC (gain maps) lose quality on resize, compress, and PDF. `Sources/ImageOps.swift:180`, `:194`
- **Resized images gain an alpha channel.** `scaled()` always uses `premultipliedLast`, so opaque PNGs come out with an alpha channel and are bigger. `Sources/ImageOps.swift:182`
- **Stale metadata after resizing/cropping.** `{Exif}` `PixelXDimension`/`PixelYDimension` still hold the original size. `Sources/ImageOps.swift:151-152` removes only the top-level keys.
- **The "same format" fallback is PNG.** RAW (DNG/CR2/ARW) and other formats ImageIO can't write become very large PNGs on resize, strip, or crop. JPEG or HEIC would be a better default for photos. `Sources/ImageOps.swift:78`

### PDF
- **The page size comes from the image's DPI.** `PDFPage(image:)` turns a 6000 px, 72 dpi photo into an 83-inch page. Fit pages to A4/Letter, or use a fixed DPI. `Sources/ImageOps.swift:275`
- **A PDF is one unit,** so there's no progress (0/1), Cancel does nothing until it's done, and one unreadable image fails the whole PDF. `Sources/Jobs.swift:44`, `Sources/ImageOps.swift:275-277`

### Performance
- ✅ **The drag pasteboard is polled 60×/s even when idle.** `baselineChangeCount = dragPasteboard.changeCount` runs on every tick while the button is up, which means a pasteboard-server round-trip 60 times a second for the life of the app. Read the baseline only when the button goes down, and/or poll less often while the mouse is up. `Sources/DragWatcher.swift:37-39`
- ✅ **The crop window decodes full-resolution images just to show them.** Each arrow-key press starts a new full decode on a global queue (hundreds of MB each for big photos), and earlier ones aren't cancelled. A downsampled image at about 2× the window size is enough for display, and the crop itself already reloads at full size. `Sources/CropWindow.swift:106-115`
- **`CropController.start()` reads every file's properties on the main thread** (and fully decodes SVGs through NSImage). With a large drop, this freezes the UI before the window opens. `Sources/CropWindow.swift:219-221`
- **Memory per job:** 2–4 concurrent full decodes, each with more full-size copies (`trimRect`, `flattened`, WebP buffer). This is fine for normal photos but risky for 100 MP+ or very large TIFFs, with no guard.

### Robustness
- ✅ **Output always goes next to the original.** A read-only folder (mounted DMG, network share, another user's folder) fails with "Can't write" and there's no fallback (for example, Downloads or a chosen folder). `Sources/ImageOps.swift:211`
- **`reserveURL` creates an empty placeholder file first.** If the app crashes or is force-quit mid-job, 0-byte files are left behind. Write to a temp file and `link`/rename into the reserved name, or clean up on launch. `Sources/ImageOps.swift:292-303`
- **Only the first frame is used** for animated GIF/WebP/HEICS (documented). Resizing or converting an animated GIF quietly turns it into a still.

### Build & distribution
- **arm64 only, macOS 26+ only**, purely because of Homebrew's libwebp. Building libwebp from source (or vendoring it) with `-mmacosx-version-min=13` and `-arch x86_64 -arch arm64` would widen support a lot. `build.sh:17`
- **The app is ad-hoc signed and rebuilt each time,** so its code identity changes. Notification permission and Launch at Login may need re-approving after each rebuild, and Gatekeeper blocks it on other Macs. A Developer ID plus notarisation is needed to share it.
- **No tests.** `ImageOps`, `CropGeometry`, `reserveURL`, and `WheelModel.index(at:)` are pure and easy to unit-test. The `--run` CLI could drive a small golden-image test script.

---

## 3. Structure / cleanup

### 3.1 Wheel visibility is spread across too much state (root cause of 1.2 and 1.3)
`Sources/Wheel.swift:85-127`, `Sources/main.swift:26-33`

Whether the wheel is showing depends on `panel.isVisible`, `model.shown`, `model.status`, the `generation` counter, and delayed closures, all checked from `main.swift`, `perform`, `dragEnded`, and the hand-off timer. Replacing this with one explicit state enum (`hidden / appearing / idle / working / finishing / disappearing`) and a single `transition(to:)` would make races like 1.2 and 1.3 impossible, rather than patching each one.

### ✅ 3.2 Orientation handling should be one rule, not a per-action flag
Covered in 1.1: always bake the orientation in at load time, then delete the `oriented:` parameter and the special cases in `load`.

### 3.3 Dead or duplicated code
- `WheelModel.fileCount` is set in `show()` but never read. `Sources/Wheel.swift:27`, `:102`
- `perform()` runs `urls.filter(ImageOps.isImage)` in both branches, and `ImageOps.run` filters again. Filter once at the top. `Sources/Wheel.swift:136`, `:149`, `Sources/ImageOps.swift:70`
- `Settings.setAll` writes `UserDefaults` once per item through `didSet`. Build the new set, then assign it once. `Sources/Settings.swift:31-33`
- `index(at:)` accepts hits out to `size/2` (160 pt), while slices are drawn only to `outer` (150 pt), so the 10 pt ring outside the drawn wheel still selects a slice. Use `WheelGeometry.outer`. `Sources/Wheel.swift:74`

---

## 4. Ideas to make Halo better

**Workflow**
- **Output location setting:** next to the original (default), a fixed folder, or "ask". Add an option to replace the original, with the original moved to the Trash so it's recoverable.
- **Undo for the last job:** move its outputs to the Trash, from the menu or a notification action.
- **Presets:** let users add their own wheel slices (for example "WebP q70 max 2048px" or "JPG 1080px stripped"), one action combining resize, format, quality, and strip.
- **Batch rename** on save: patterns such as `{name}-{w}x{h}`, `{name}@2x`.
- **Copy the result to the clipboard** as an extra wheel slot or a modifier on drop. This is handy for pasting into chat apps.
- **Drop-to-Halo without a drag modifier:** a menu bar drop target, a Services menu entry, or Finder Quick Actions (a Share/Action extension), so it also works from the keyboard and for people who don't like modifier taps.

**Formats & tools**
- Lossless WebP/AVIF options, and a quality slider in Settings.
- Rotate/flip slices (90°, 180°, mirror).
- Animated GIF ↔ animated WebP/APNG, and MOV → GIF.
- Multi-page TIFF/PDF → images (the reverse of "Make PDF"), plus page-size and margin choices for Make PDF.
- Show the size saving on Compress ("2.4 MB → 610 KB, -75%").
- Background removal (Vision `VNGenerateForegroundInstanceMaskRequest`) as a tool slice.
- OCR/"copy text from image" (Vision) as a tool slice.

**UX**
- A small preview in the wheel's centre showing the dragged file count and type, which would also make `fileCount` useful.
- Remember the last aspect ratio in the crop window, and offer a typed pixel size ("1200 × 630").
- Keyboard nudging (arrow keys move the crop by 1 px, ⇧ by 10 px). Arrows currently switch images; ⌘/⌥-arrow could do that instead.
- A first-launch onboarding window showing the gesture. The menu's help line is the only hint today.
- Accessibility: VoiceOver labels on wheel slices, and Reduce Motion support for the spring animation.

**Engineering**
- Move to an Xcode project or a SwiftPM executable with a test target, add CI that builds and runs the `--run` golden tests, and adopt Swift 6 strict concurrency (`ImageOps` is called from `OperationQueue` threads; it's currently safe, but nothing enforces that).
- Universal build with a vendored libwebp, Developer ID signing, notarisation, and Sparkle for updates.

---

## 5. Priority order (suggested)

1. 1.1 orientation on convert, a visible wrong-output bug.
2. 1.2 / 1.3 / 3.1 wheel visibility races, ideally fixed with the state-machine refactor.
3. 1.4 shared crop breaks aspect ratio.
4. 1.5 notification reveal, 1.6 1×1 decode, 1.7 no-op fit copies, 1.8 compress growth/alpha.
5. The DragWatcher idle polling and the crop window's full-resolution decode (performance).
6. Lossless WebP, colour-profile handling, output-folder setting.
