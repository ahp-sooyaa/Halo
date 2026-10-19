import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let wheel = WheelController()
    private let watcher = DragWatcher()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Halo")

        let menu = NSMenu()
        let help = NSMenuItem(title: "Drag an image, tap ⇧ to convert, ⌘ for tools", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit Halo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        refreshLoginItem()

        watcher.onKeyTap = { [weak self] mode, urls in
            guard let self else { return }
            if self.wheel.isVisible && self.wheel.model.mode == mode && self.wheel.model.status == .idle {
                self.wheel.hide() // tapping the same key again closes the wheel
            } else if self.wheel.model.status == .idle || !self.wheel.isVisible {
                self.wheel.show(mode, urls: urls)
            }
        }
        watcher.onDragEnd = { [weak self] in self?.wheel.dragEnded() }
        watcher.start()

        // `Halo --demo [tools]` shows the wheel for a few seconds, for checking the look.
        if CommandLine.arguments.contains("--demo") {
            let mode: WheelMode = CommandLine.arguments.contains("tools") ? .tools : .convert
            wheel.show(mode, urls: [])
            wheel.model.hovered = 1
            wheel.hide(after: 6)
        }
    }

    private func refreshLoginItem() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = "\(error.localizedDescription)\n\nTry moving Halo to /Applications first."
            alert.runModal()
        }
        refreshLoginItem()
    }
}

// `Halo --run <action> <files…>` runs one action headlessly (used for testing).
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--run"), args.count > i + 2 {
    let name = args[i + 1].lowercased()
    let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
    let action: ImageAction?
    switch name {
    case "pdf": action = .pdf
    case "compress": action = .compress
    case "strip": action = .strip
    case "fit": action = .fit(1920)
    case let s where s.hasPrefix("scale"): action = Double(s.dropFirst(5)).map { .scale($0 / 100) }
    default: action = ImageOps.formats.first { $0.name.lowercased() == name }.map { .convert($0.type) }
    }
    guard let action else {
        print("Unknown action. Formats: \(ImageOps.formats.map(\.name).joined(separator: ", "))")
        exit(2)
    }
    do {
        for out in try ImageOps.run(action, on: files) { print(out.path) }
        exit(0)
    } catch {
        print("Error: \(error.localizedDescription)")
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
