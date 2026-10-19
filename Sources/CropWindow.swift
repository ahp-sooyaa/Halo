import AppKit
import SwiftUI

/// Opens a crop window for each dropped image in turn.
@MainActor
final class CropController: NSObject, NSWindowDelegate {
    var onFinish: (() -> Void)?
    private var queue: [URL]
    private var window: NSWindow?

    init(urls: [URL]) {
        queue = urls
    }

    func start() { showNext() }

    private func showNext() {
        if let window {
            window.delegate = nil
            window.close()
            self.window = nil
        }
        guard !queue.isEmpty else {
            onFinish?()
            return
        }
        let url = queue.removeFirst()
        guard let (image, _) = try? ImageOps.load(url, oriented: true) else {
            NSSound.beep()
            showNext()
            return
        }

        let editor = CropEditor(image: image, onCancel: { [weak self] in self?.showNext() }) { [weak self] rect in
            do {
                _ = try ImageOps.run(.crop(rect), on: url)
                NSSound(named: "Pop")?.play()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't crop \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            self?.showNext()
        }

        // Fit the image into at most 960×720, leaving room for the toolbar.
        let scale = min(1, 960 / CGFloat(image.width), 720 / CGFloat(image.height))
        let size = CGSize(width: max(480, CGFloat(image.width) * scale + 32),
                          height: CGFloat(image.height) * scale + 32 + CropEditor.toolbarHeight)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Crop \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: editor)
        window.delegate = self
        window.center()
        window.level = .floating
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closed with the red button: treat as cancel.
        window?.delegate = nil
        window = nil
        DispatchQueue.main.async { self.showNext() }
    }
}

struct CropEditor: View {
    static let toolbarHeight: CGFloat = 52

    enum Aspect: String, CaseIterable, Identifiable {
        case free = "Free", square = "1:1", fourThree = "4:3", threeTwo = "3:2", wide = "16:9", tall = "9:16"
        var id: Self { self }
        var ratio: CGFloat? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .fourThree: return 4.0 / 3
            case .threeTwo: return 3.0 / 2
            case .wide: return 16.0 / 9
            case .tall: return 9.0 / 16
            }
        }
    }

    let image: CGImage
    let onCancel: () -> Void
    let onSave: (CGRect) -> Void

    /// Normalised crop rect, origin top-left.
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect: Aspect = .free
    @State private var dragStart: CGRect?

    private var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                canvas(frame: fitted(in: geo.size))
            }
            .padding(16)
            .background(Color(white: 0.12))

            HStack(spacing: 12) {
                Picker("", selection: $aspect) {
                    ForEach(Aspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                Text("\(Int((rect.width * pixelSize.width).rounded())) × \(Int((rect.height * pixelSize.height).rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save Crop") { onSave(rect) }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.toolbarHeight)
        }
        .onChange(of: aspect) { _, newValue in rect = largestRect(for: newValue.ratio) }
    }

    // MARK: Canvas

    private func canvas(frame: CGRect) -> some View {
        let crop = CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                          width: rect.width * frame.width, height: rect.height * frame.height)

        func normalized(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - frame.minX) / frame.width, y: (p.y - frame.minY) / frame.height)
        }

        return ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)

            // Dim everything outside the crop.
            Path { p in
                p.addRect(frame)
                p.addRect(crop)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))

            // Drag on empty space draws a new selection.
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas")).onChanged { v in
                    let anchor = clamp(normalized(v.startLocation))
                    rect = resized(from: anchor, to: normalized(v.location))
                })

            // Drag inside the selection moves it.
            selectionOverlay(crop)
                .contentShape(Rectangle())
                .frame(width: crop.width, height: crop.height)
                .position(x: crop.midX, y: crop.midY)
                .gesture(DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { v in
                        let start = dragStart ?? rect
                        dragStart = start
                        rect.origin.x = min(max(0, start.minX + v.translation.width / frame.width), 1 - start.width)
                        rect.origin.y = min(max(0, start.minY + v.translation.height / frame.height), 1 - start.height)
                    }
                    .onEnded { _ in dragStart = nil })

            // Corner handles resize against the opposite corner.
            ForEach(0..<4, id: \.self) { corner in
                let isRight = corner == 1 || corner == 2, isBottom = corner >= 2
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .position(x: isRight ? crop.maxX : crop.minX, y: isBottom ? crop.maxY : crop.minY)
                    .gesture(DragGesture(coordinateSpace: .named("canvas"))
                        .onChanged { v in
                            let start = dragStart ?? rect
                            dragStart = start
                            let anchor = CGPoint(x: isRight ? start.minX : start.maxX, y: isBottom ? start.minY : start.maxY)
                            rect = resized(from: anchor, to: normalized(v.location))
                        }
                        .onEnded { _ in dragStart = nil })
            }
        }
        .coordinateSpace(name: "canvas")
    }

    private func selectionOverlay(_ crop: CGRect) -> some View {
        ZStack {
            Rectangle().strokeBorder(Color.white, lineWidth: 1.5)
            // Rule-of-thirds guides.
            Path { p in
                for i in 1...2 {
                    let x = crop.width * CGFloat(i) / 3, y = crop.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: crop.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: crop.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.75)
        }
    }

    // MARK: Geometry

    private func fitted(in size: CGSize) -> CGRect {
        let scale = min(size.width / pixelSize.width, size.height / pixelSize.height)
        let w = pixelSize.width * scale, h = pixelSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    /// Normalised height per unit of normalised width for the given pixel aspect ratio.
    private func heightFactor(_ ratio: CGFloat) -> CGFloat {
        pixelSize.width / pixelSize.height / ratio
    }

    private func largestRect(for ratio: CGFloat?) -> CGRect {
        guard let ratio else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let k = heightFactor(ratio)
        let w = k <= 1 ? 1 : 1 / k
        let h = w * k
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private func resized(from anchor: CGPoint, to point: CGPoint) -> CGRect {
        let p = clamp(point)
        let goingRight = p.x >= anchor.x, goingDown = p.y >= anchor.y
        var w = abs(p.x - anchor.x), h = abs(p.y - anchor.y)
        if let ratio = aspect.ratio {
            let k = heightFactor(ratio)
            if h > w * k { w = h / k } else { h = w * k }
            let maxW = goingRight ? 1 - anchor.x : anchor.x
            let maxH = goingDown ? 1 - anchor.y : anchor.y
            if w > maxW { w = maxW; h = w * k }
            if h > maxH { h = maxH; w = h / k }
        }
        w = max(w, 0.01)
        h = max(h, 0.01)
        return CGRect(x: goingRight ? anchor.x : anchor.x - w, y: goingDown ? anchor.y : anchor.y - h,
                      width: w, height: h)
    }
}
