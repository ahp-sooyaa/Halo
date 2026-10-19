import AppKit

enum WheelMode { case convert, tools }

/// Watches for a file drag anywhere on screen and reports modifier-key taps during it.
///
/// Everything is polled (mouse buttons, modifier flags, drag pasteboard change count), which
/// needs no Accessibility or Input Monitoring permission.
@MainActor
final class DragWatcher {
    var onKeyTap: ((WheelMode, [URL]) -> Void)?
    var onDragEnd: (() -> Void)?

    private var timer: Timer?
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var baselineChangeCount = 0
    private var mouseWasDown = false
    private var lastFlags: NSEvent.ModifierFlags = []

    func start() {
        baselineChangeCount = dragPasteboard.changeCount
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        let flags = NSEvent.modifierFlags.intersection([.shift, .command])
        defer {
            mouseWasDown = down
            lastFlags = flags
        }

        if !down {
            // Remember the count while the button is up, so any change after mouse-down is a new drag.
            baselineChangeCount = dragPasteboard.changeCount
            if mouseWasDown { onDragEnd?() }
            return
        }
        guard dragPasteboard.changeCount != baselineChangeCount else { return }

        let pressed = flags.subtracting(lastFlags)
        let mode: WheelMode
        if pressed.contains(.shift) { mode = .convert }
        else if pressed.contains(.command) { mode = .tools }
        else { return }

        guard let urls = draggedImageURLs() else { return }
        onKeyTap?(mode, urls)
    }

    /// nil when the drag isn't files or has no images. An empty array means files are being
    /// dragged but their URLs couldn't be read yet; they're read again at drop time.
    private func draggedImageURLs() -> [URL]? {
        guard dragPasteboard.types?.contains(.fileURL) == true else { return nil }
        let urls = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty { return [] }
        let images = urls.filter(ImageOps.isImage)
        return images.isEmpty ? nil : images
    }
}
