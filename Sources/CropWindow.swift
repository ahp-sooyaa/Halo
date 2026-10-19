import AppKit
import ImageIO
import SwiftUI

// MARK: - Session

/// All images dropped on Crop…, each with its own crop rect.
@MainActor
final class CropSession: ObservableObject {
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

    struct Entry: Identifiable {
        let id = UUID()
        let url: URL
        /// Pixel size after EXIF rotation.
        let pixelSize: CGSize
        var thumbnail: CGImage?
        /// Normalised, origin top-left.
        var rect = CropGeometry.full
        /// Touched by hand; aspect changes then re-fit it instead of resetting it.
        var edited = false

        var willCrop: Bool { rect.width < 0.999 || rect.height < 0.999 }
    }

    @Published var entries: [Entry]
    @Published var current = 0 { didSet { if current != oldValue { loadCurrentImage() } } }
    @Published private(set) var aspect: Aspect = .free
    @Published private(set) var sameForAll = false
    /// Full-resolution image for the current entry; the thumbnail stands in until it loads.
    @Published private(set) var currentImage: CGImage?

    init(entries: [Entry]) {
        self.entries = entries
        loadCurrentImage()
        loadThumbnails()
    }

    var entry: Entry { entries[current] }
    var cropCount: Int { entries.filter(\.willCrop).count }

    /// True when the images have different shapes, so one shared crop lands in different places.
    var shapesDiffer: Bool {
        let ratios = entries.map { $0.pixelSize.width / $0.pixelSize.height }
        guard let first = ratios.first else { return false }
        return ratios.contains { abs($0 - first) / first > 0.01 }
    }

    /// The current image's crop. Setting it with "Same crop for all" on sets every image's crop.
    var rect: CGRect {
        get { entries[current].rect }
        set {
            for i in sameForAll ? Array(entries.indices) : [current] {
                entries[i].rect = newValue
                entries[i].edited = true
            }
        }
    }

    func setAspect(_ aspect: Aspect) {
        self.aspect = aspect
        if sameForAll {
            rect = entries[current].edited
                ? CropGeometry.conform(rect, ratio: aspect.ratio, pixelSize: entry.pixelSize)
                : CropGeometry.largest(ratio: aspect.ratio, pixelSize: entry.pixelSize)
            return
        }
        for i in entries.indices {
            let e = entries[i]
            entries[i].rect = e.edited
                ? CropGeometry.conform(e.rect, ratio: aspect.ratio, pixelSize: e.pixelSize)
                : CropGeometry.largest(ratio: aspect.ratio, pixelSize: e.pixelSize)
        }
    }

    func setSameForAll(_ on: Bool) {
        sameForAll = on
        if on { rect = entries[current].rect }
    }

    func resetCurrent() {
        let fresh = CropGeometry.largest(ratio: aspect.ratio, pixelSize: entry.pixelSize)
        for i in sameForAll ? Array(entries.indices) : [current] {
            entries[i].rect = fresh
            entries[i].edited = false
        }
    }

    func step(_ delta: Int) {
        current = (current + delta + entries.count) % entries.count
    }

    private func loadCurrentImage() {
        currentImage = nil
        let index = current, url = entries[current].url
        DispatchQueue.global(qos: .userInitiated).async {
            let image = try? ImageOps.load(url, oriented: true).0
            DispatchQueue.main.async {
                if self.current == index { self.currentImage = image }
            }
        }
    }

    private func loadThumbnails() {
        for (i, e) in entries.enumerated() {
            let url = e.url
            DispatchQueue.global(qos: .utility).async {
                let thumb = CropSession.thumbnail(url)
                DispatchQueue.main.async {
                    if i < self.entries.count, self.entries[i].url == url { self.entries[i].thumbnail = thumb }
                }
            }
        }
    }

    nonisolated static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Oriented pixel size from the file's properties, without decoding it.
    nonisolated static func pixelSize(of url: URL) -> CGSize? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        // Formats ImageIO can't read (e.g. SVG) go through NSImage, as ImageOps.load does.
        return (try? ImageOps.load(url, oriented: true)).map { CGSize(width: $0.0.width, height: $0.0.height) }
    }
}

// MARK: - Geometry

enum CropGeometry {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Normalised height per unit of normalised width for a pixel aspect ratio.
    static func heightFactor(_ ratio: CGFloat, _ size: CGSize) -> CGFloat {
        size.width / size.height / ratio
    }

    static func largest(ratio: CGFloat?, pixelSize: CGSize) -> CGRect {
        guard let ratio else { return full }
        let k = heightFactor(ratio, pixelSize)
        let w = k <= 1 ? 1 : 1 / k
        let h = w * k
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Reshape an existing crop to a ratio, keeping its centre and width where it fits.
    static func conform(_ rect: CGRect, ratio: CGFloat?, pixelSize: CGSize) -> CGRect {
        guard let ratio else { return rect }
        let k = heightFactor(ratio, pixelSize)
        var w = rect.width, h = w * k
        if h > 1 { h = 1; w = h / k }
        if w > 1 { w = 1; h = w * k }
        let x = min(max(rect.midX - w / 2, 0), 1 - w)
        let y = min(max(rect.midY - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    static func resized(from anchor: CGPoint, to point: CGPoint, ratio: CGFloat?, pixelSize: CGSize) -> CGRect {
        let p = clamp(point)
        let goingRight = p.x >= anchor.x, goingDown = p.y >= anchor.y
        var w = abs(p.x - anchor.x), h = abs(p.y - anchor.y)
        if let ratio {
            let k = heightFactor(ratio, pixelSize)
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

// MARK: - Window

@MainActor
final class CropController: NSObject, NSWindowDelegate {
    var onFinish: (() -> Void)?
    private let urls: [URL]
    private var window: NSWindow?
    private var session: CropSession?

    init(urls: [URL]) {
        self.urls = urls
    }

    func start() {
        let entries = urls.compactMap { url in
            CropSession.pixelSize(of: url).map { CropSession.Entry(url: url, pixelSize: $0) }
        }
        guard !entries.isEmpty else {
            NSSound.beep()
            onFinish?()
            return
        }
        let session = CropSession(entries: entries)
        self.session = session

        let editor = CropEditor(session: session, onCancel: { [weak self] in self?.close(confirm: true) },
                                onSave: { [weak self] in self?.save() })

        // Size for the first image within 960×640, plus strip and toolbar.
        let size = entries[0].pixelSize
        let scale = min(960 / size.width, 640 / size.height)
        let chrome = CropEditor.toolbarHeight + (entries.count > 1 ? CropEditor.stripHeight : 0) + 32
        let contentSize = CGSize(width: max(720, size.width * scale + 32), height: max(360, size.height * scale) + chrome)

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = entries.count == 1 ? "Crop \(entries[0].url.lastPathComponent)" : "Crop \(entries.count) Images"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: editor)
        window.contentMinSize = CGSize(width: 560, height: 420)
        window.delegate = self
        window.center()
        window.level = .floating
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close(confirm: true)
        return false
    }

    /// Asks before throwing away crops that were set but not saved.
    private func close(confirm: Bool) {
        if confirm, let session, session.cropCount > 0 {
            let alert = NSAlert()
            alert.messageText = "Discard your crops?"
            alert.informativeText = "\(session.cropCount) \(session.cropCount == 1 ? "image has" : "images have") a crop that hasn't been saved."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Editing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        window?.delegate = nil
        window?.close()
        window = nil
        session = nil
        onFinish?()
    }

    private func save() {
        guard let session else { return }
        let units = session.entries.filter(\.willCrop).map { Job.Unit(action: .crop($0.rect), urls: [$0.url]) }
        guard !units.isEmpty else { return }

        let job = Job(title: units.count == 1 ? "Crop" : "Crop \(units.count) images", units: units)
        // Big batches report in the menu bar with a notification; small ones just chime.
        job.handedOff = units.count > 3
        if job.handedOff { Notifier.requestPermission() }
        job.onChange = { [weak job] in
            guard let job, !job.isActive else { return }
            job.onChange = nil
            if job.failures.isEmpty {
                if !job.handedOff { NSSound(named: "Pop")?.play() }
            } else if !job.handedOff {
                let alert = NSAlert()
                alert.messageText = "Some crops failed"
                alert.informativeText = job.failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
                alert.runModal()
            }
        }
        JobCenter.shared.submit(job)
        close(confirm: false)
    }
}

// MARK: - Editor

struct CropEditor: View {
    static let toolbarHeight: CGFloat = 52
    static let stripHeight: CGFloat = 84

    @ObservedObject var session: CropSession
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var dragStart: CGRect?

    private var multiple: Bool { session.entries.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                canvas(frame: fitted(in: geo.size))
            }
            .padding(16)
            .background(Color(white: 0.12))

            if multiple {
                strip
            }

            if session.sameForAll && session.shapesDiffer {
                Label("These images have different shapes, so the shared crop lands in a different place on each.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            toolbar
        }
    }

    // MARK: Toolbar

    /// One row when it fits; otherwise aspect + size on top and the buttons underneath.
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                aspectPicker
                sizeLabel
                Spacer(minLength: 12)
                actionButtons
            }
            .frame(height: Self.toolbarHeight)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    aspectPicker
                    sizeLabel
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    actionButtons
                }
            }
            .padding(.vertical, 10)
        }
        .padding(.horizontal, 16)
    }

    private var aspectPicker: some View {
        Picker("", selection: Binding(get: { session.aspect }, set: { session.setAspect($0) })) {
            ForEach(CropSession.Aspect.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize() // never squeezed; the toolbar wraps instead
        .help("Applies to every image")
    }

    private var sizeLabel: some View {
        // verbatim: no thousands separators. Minimum width so the toolbar doesn't jump as it changes.
        Text(verbatim: "\(Int((session.rect.width * session.entry.pixelSize.width).rounded())) × \(Int((session.rect.height * session.entry.pixelSize.height).rounded()))")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 104, alignment: .leading)
    }

    @ViewBuilder private var actionButtons: some View {
        Button("Reset") { session.resetCurrent() }
            .disabled(!session.entry.willCrop)
            .fixedSize()
        Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .fixedSize()
        Button(action: onSave) {
            // Sized for the longest title it can show, so it never truncates or changes width.
            ZStack {
                Text(longestSaveTitle).hidden()
                Text(saveTitle)
            }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(session.cropCount == 0)
        .fixedSize()
    }

    private var longestSaveTitle: String {
        let n = session.entries.count
        return n > 1 ? "Crop \(n) of \(n)" : "Save Crop"
    }

    private var saveTitle: String {
        guard multiple else { return "Save Crop" }
        let n = session.cropCount
        return n == session.entries.count ? "Crop All \(n)" : "Crop \(n) of \(session.entries.count)"
    }

    // MARK: Thumbnail strip

    private var strip: some View {
        HStack(spacing: 8) {
            Button { session.step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .buttonStyle(.borderless)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Not lazy: LazyHStack can leave thumbnails blank after the window is resized.
                    HStack(spacing: 8) {
                        ForEach(Array(session.entries.enumerated()), id: \.element.id) { i, entry in
                            thumbnail(entry, selected: i == session.current)
                                .id(i)
                                .onTapGesture { session.current = i }
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 2)
                }
                .onChange(of: session.current) { _, i in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) }
                }
            }

            Button { session.step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .buttonStyle(.borderless)

            Text("\(session.current + 1) of \(session.entries.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 56)

            Divider().frame(height: 28)

            Toggle("Same crop for all", isOn: Binding(get: { session.sameForAll }, set: { session.setSameForAll($0) }))
                .toggleStyle(.checkbox)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.stripHeight)
        .background(Color(white: 0.09))
    }

    private func thumbnail(_ entry: CropSession.Entry, selected: Bool) -> some View {
        let h: CGFloat = 60
        let w = max(36, min(110, h * entry.pixelSize.width / entry.pixelSize.height))
        let crop = CGRect(x: entry.rect.minX * w, y: entry.rect.minY * h,
                          width: entry.rect.width * w, height: entry.rect.height * h)
        return ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = entry.thumbnail {
                    Image(decorative: thumb, scale: 1).resizable()
                } else {
                    Color(white: 0.2)
                }
            }
            .frame(width: w, height: h)
            .overlay {
                if entry.willCrop {
                    Path { p in
                        p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                        p.addRect(crop)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Color.orange : Color.white.opacity(0.15), lineWidth: selected ? 2.5 : 1))

            if entry.willCrop {
                Image(systemName: "crop")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.orange))
                    .offset(x: 4, y: -4)
            }
        }
        .help(entry.url.lastPathComponent)
    }

    // MARK: Canvas

    private func canvas(frame: CGRect) -> some View {
        let rect = session.rect
        let pixelSize = session.entry.pixelSize
        let ratio = session.aspect.ratio
        let crop = CGRect(x: frame.minX + rect.minX * frame.width, y: frame.minY + rect.minY * frame.height,
                          width: rect.width * frame.width, height: rect.height * frame.height)

        func normalized(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - frame.minX) / frame.width, y: (p.y - frame.minY) / frame.height)
        }

        return ZStack {
            Group {
                if let image = session.currentImage ?? session.entry.thumbnail {
                    Image(decorative: image, scale: 1).resizable()
                } else {
                    ProgressView()
                }
            }
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
                    let anchor = CropGeometry.clamp(normalized(v.startLocation))
                    session.rect = CropGeometry.resized(from: anchor, to: normalized(v.location),
                                                        ratio: ratio, pixelSize: pixelSize)
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
                        var moved = start
                        moved.origin.x = min(max(0, start.minX + v.translation.width / frame.width), 1 - start.width)
                        moved.origin.y = min(max(0, start.minY + v.translation.height / frame.height), 1 - start.height)
                        session.rect = moved
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
                            session.rect = CropGeometry.resized(from: anchor, to: normalized(v.location),
                                                                ratio: ratio, pixelSize: pixelSize)
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

    private func fitted(in size: CGSize) -> CGRect {
        let px = session.entry.pixelSize
        let scale = min(size.width / px.width, size.height / px.height)
        let w = px.width * scale, h = px.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
