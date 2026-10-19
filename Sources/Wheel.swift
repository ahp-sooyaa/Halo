import AppKit
import SwiftUI

struct WheelItem: Identifiable, Equatable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let action: ImageAction
}

enum WheelGeometry {
    static let size: CGFloat = 320
    static let outer: CGFloat = 150
    static let inner: CGFloat = 58
    static let gap: CGFloat = 3
}

@MainActor
final class WheelModel: ObservableObject {
    enum Status: Equatable {
        case idle, working(done: Int, total: Int), failed(String)
        /// `note` is extra detail, e.g. Compress's "-75%".
        case done(saved: Int, failed: Int, note: String?)
    }

    @Published var mode: WheelMode = .convert
    @Published var items: [WheelItem] = []
    @Published var hovered: Int?
    @Published var status: Status = .idle
    @Published var shown = false

    /// What the wheel shows for these files: the catalog minus items turned off in Settings,
    /// and minus the files' own format on the Convert wheel.
    static func items(for mode: WheelMode, urls: [URL]) -> [WheelItem] {
        let settings = Settings.shared
        var list = catalog(for: mode).filter { settings.isEnabled($0, in: mode) }
        if mode == .convert {
            let sourceTypes = Set(urls.compactMap { ImageOps.type(of: $0)?.identifier })
            list.removeAll {
                if case .convert(let type) = $0.action {
                    return sourceTypes.count == 1 && sourceTypes.contains(type.identifier)
                }
                return false
            }
            if urls.count > 1, let i = list.firstIndex(where: { $0.action == .pdf }) {
                list[i].subtitle = "combine"
            }
        }
        return list
    }

    /// Every item a wheel can offer, in wheel order.
    static func catalog(for mode: WheelMode) -> [WheelItem] {
        switch mode {
        case .convert:
            return ImageOps.formats.map { WheelItem(id: $0.name, title: $0.name, action: .convert($0.type)) }
                + [WheelItem(id: "PDF", title: "PDF", action: .pdf)]
        case .tools:
            return [
                WheelItem(id: "75", title: "75%", subtitle: "resize", action: .scale(0.75)),
                WheelItem(id: "50", title: "50%", subtitle: "resize", action: .scale(0.5)),
                WheelItem(id: "25", title: "25%", subtitle: "resize", action: .scale(0.25)),
                WheelItem(id: "1920", title: "1920px", subtitle: "fit", action: .fit(1920)),
                WheelItem(id: "compress", title: "Compress", action: .compress),
                WheelItem(id: "strip", title: "Strip", subtitle: "metadata", action: .strip),
                WheelItem(id: "trim", title: "Trim", subtitle: "borders", action: .trim),
                WheelItem(id: "crop", title: "Crop…", action: .cropInteractive),
            ]
        }
    }

    /// Slice under a point in the wheel view's own (y-up) coordinates; nil in the centre = cancel.
    func index(at p: CGPoint, in bounds: CGRect) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = p.x - bounds.midX, dy = p.y - bounds.midY
        let r = hypot(dx, dy)
        guard r > WheelGeometry.inner, r < WheelGeometry.outer else { return nil }
        var angle = atan2(dx, dy) // clockwise from 12 o'clock
        if angle < 0 { angle += 2 * .pi }
        let width = 2 * .pi / Double(items.count)
        return Int((angle + width / 2) / width) % items.count
    }
}

// MARK: - Controller

@MainActor
final class WheelController {
    let model = WheelModel()
    private var panel: NSPanel?
    private var cropper: CropController?
    private var generation = 0

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ mode: WheelMode, urls: [URL]) {
        let items = WheelModel.items(for: mode, urls: urls)
        guard !items.isEmpty else {
            hide() // everything in this wheel is turned off in Settings
            return
        }
        generation += 1
        model.mode = mode
        model.items = items
        model.hovered = nil
        model.status = .idle

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            panel.setFrame(frameAroundCursor(), display: false)
            model.shown = false
            panel.orderFrontRegardless()
            DispatchQueue.main.async { self.model.shown = true }
        } else {
            model.shown = true // may be mid fade-out; the bumped generation cancelled the orderOut
        }
    }

    func hide(after delay: TimeInterval = 0, then completion: (() -> Void)? = nil) {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard gen == self.generation else { return }
            self.model.shown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                guard gen == self.generation else { return }
                self.panel?.orderOut(nil)
                completion?()
            }
        }
    }

    /// Mouse released. Over a slice the drop callback may still be on its way, so wait for it
    /// briefly; `perform` cancels this hide.
    func dragEnded() {
        guard model.status == .idle else { return }
        hide(after: model.hovered == nil ? 0 : 0.5)
    }

    func perform(_ item: WheelItem, on urls: [URL]) {
        // Cancel any hide queued by dragEnded, and undo its fade if it already started.
        generation += 1
        model.shown = true
        let images = urls.filter(ImageOps.isImage)
        if item.action == .cropInteractive {
            hide()
            guard !images.isEmpty else { return }
            if let cropper {
                // One crop window at a time: point at the open one.
                NSSound.beep()
                cropper.focus()
                return
            }
            // Open after the drag session has fully ended, or Finder keeps focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                let cropper = CropController(urls: images)
                cropper.onFinish = { [weak self] in self?.cropper = nil }
                self.cropper = cropper
                cropper.start()
            }
            return
        }
        guard !images.isEmpty else {
            model.status = .failed(ImageOpsError.noImages.localizedDescription)
            NSSound.beep()
            hide(after: 1.5)
            return
        }

        let center = JobCenter.shared
        let wasBusy = !center.activeJobs.isEmpty
        let job = center.submit(item, on: images)
        model.hovered = nil
        model.status = .working(done: 0, total: job.total)

        job.onChange = { [weak self, weak job] in
            guard let self, let job else { return }
            if job.isActive {
                self.model.status = .working(done: job.completed, total: job.total)
                return
            }
            job.onChange = nil
            if job.outputs.isEmpty, let failure = job.failures.first {
                self.model.status = .failed(failure.reason)
                NSSound.beep()
                self.hide(after: 2)
            } else {
                let note = job.savingPercent.map { "\($0)%" }
                self.model.status = .done(saved: job.outputs.count, failed: job.failures.count, note: note)
                NSSound(named: "Pop")?.play()
                self.hide(after: job.failures.isEmpty ? 0.8 : 1.6)
            }
        }

        // Still going after a moment (or stuck behind another job): hand it to the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasBusy ? 0.5 : 1.5)) { [weak self, weak job] in
            guard let self, let job, job.isActive, job.onChange != nil else { return }
            job.onChange = nil
            job.handedOff = true
            Notifier.requestPermission()
            self.hide { self.model.status = .idle }
        }
    }

    private func frameAroundCursor() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let s = WheelGeometry.size
        var frame = CGRect(x: mouse.x - s / 2, y: mouse.y - s / 2, width: s, height: s)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let v = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, v.minX), v.maxX - s)
            frame.origin.y = min(max(frame.minY, v.minY), v.maxY - s)
        }
        return frame
    }

    private func makePanel() -> NSPanel {
        let rect = CGRect(x: 0, y: 0, width: WheelGeometry.size, height: WheelGeometry.size)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let container = NSView(frame: rect)
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        // Transparent overlay on top so it, not SwiftUI, receives the drag.
        let drop = DropView(frame: rect)
        drop.controller = self
        drop.autoresizingMask = [.width, .height]
        container.addSubview(drop)

        panel.contentView = container
        return panel
    }
}

// MARK: - Drop target

final class DropView: NSView {
    weak var controller: WheelController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func slice(for info: NSDraggingInfo) -> Int? {
        controller?.model.index(at: convert(info.draggingLocation, from: nil), in: bounds)
    }

    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let model = controller?.model, model.status == .idle else { return [] }
        let index = slice(for: info)
        if model.hovered != index {
            model.hovered = index
            if index != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        return index == nil ? [] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.model.hovered = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let controller, controller.model.status == .idle,
              let index = slice(for: sender), controller.model.items.indices.contains(index) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        controller.perform(controller.model.items[index], on: urls)
        return true
    }
}

// MARK: - SwiftUI

private let accent = LinearGradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.18),
                                             Color(red: 0.98, green: 0.42, blue: 0.10)],
                                    startPoint: .top, endPoint: .bottom)

struct SliceShape: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let g = WheelGeometry.gap
        func point(_ t: Double, _ r: CGFloat) -> CGPoint {
            // Constant-width gaps: trim the angle by gap/r at each radius.
            let a = (start + Double(g / r)) + (end - start - 2 * Double(g / r)) * t
            return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
        }
        let steps = 32
        var p = Path()
        p.move(to: point(0, WheelGeometry.outer))
        for s in 1...steps { p.addLine(to: point(Double(s) / Double(steps), WheelGeometry.outer)) }
        for s in (0...steps).reversed() { p.addLine(to: point(Double(s) / Double(steps), WheelGeometry.inner)) }
        p.closeSubpath()
        return p
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        let n = max(model.items.count, 1)
        let width = 2 * Double.pi / Double(n)

        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().fill(Color.black.opacity(0.45)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .frame(width: WheelGeometry.outer * 2 + 8, height: WheelGeometry.outer * 2 + 8)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)

            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                let mid = Double(i) * width
                let selected = model.hovered == i
                SliceShape(start: mid - width / 2, end: mid + width / 2)
                    .fill(selected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.07)))
                label(item, selected: selected)
                    .offset(x: CGFloat(sin(mid)) * (WheelGeometry.inner + WheelGeometry.outer) / 2,
                            y: CGFloat(-cos(mid)) * (WheelGeometry.inner + WheelGeometry.outer) / 2)
            }
            .opacity(model.status == .idle ? 1 : 0.35)

            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: (WheelGeometry.inner - 6) * 2, height: (WheelGeometry.inner - 6) * 2)
            center
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
        .environment(\.colorScheme, .dark)
        .scaleEffect(model.shown ? 1 : 0.6)
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: model.shown)
        .animation(.easeOut(duration: 0.12), value: model.hovered)
        .animation(.easeOut(duration: 0.15), value: model.status)
    }

    private func label(_ item: WheelItem, selected: Bool) -> some View {
        VStack(spacing: 1) {
            Text(item.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.85))
        .scaleEffect(selected ? 1.12 : 1)
    }

    @ViewBuilder private var center: some View {
        switch model.status {
        case .idle:
            VStack(spacing: 3) {
                Image(systemName: model.mode == .convert ? "arrow.triangle.2.circlepath" : "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                Text(model.mode == .convert ? "Convert" : "Tools")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                HStack(spacing: 4) {
                    keycap("⇧", active: model.mode == .convert)
                    keycap("⌘", active: model.mode == .tools)
                }
            }
            .foregroundStyle(.white)
        case .working(let done, let total) where total > 1:
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: CGFloat(done) / CGFloat(total))
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(done)/\(total)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .frame(width: 66, height: 66)
            .animation(.easeOut(duration: 0.2), value: done)
        case .working:
            ProgressView().controlSize(.small)
        case .done(let saved, let failed, let note):
            VStack(spacing: 2) {
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 26)).foregroundStyle(failed == 0 ? .green : .orange)
                Text(failed > 0 ? "\(saved) saved · \(failed) failed" : saved == 1 ? "Saved" : "Saved \(saved)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                if let note {
                    Text(note)
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.green)
                }
            }
            .transition(.scale.combined(with: .opacity))
        case .failed(let message):
            VStack(spacing: 2) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 22)).foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(3).frame(width: 90)
            }
        }
    }

    private func keycap(_ glyph: String, active: Bool) -> some View {
        Text(glyph)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .frame(width: 18, height: 16)
            .background(RoundedRectangle(cornerRadius: 4).fill(active ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.12))))
    }
}
