import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let wheel = WheelController()
    private let watcher = DragWatcher()
    private let settingsWindow = SettingsWindowController()
    /// The menu while it's open, and the job rows it was built with, so it can be rebuilt when
    /// jobs are added, removed or finish (rows change height) while it's showing.
    private var openMenu: NSMenu?
    private var menuJobs: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.idle

        let menu = NSMenu()
        menu.delegate = self // rebuilt each time it opens, see menuNeedsUpdate
        statusItem.menu = menu

        Notifier.setUp(delegate: self)
        JobCenter.shared.onChange = { [weak self] in self?.jobsChanged() }

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

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) { openMenu = menu }
    func menuDidClose(_ menu: NSMenu) { openMenu = nil }

    private static func rowKeys() -> [String] { JobCenter.shared.jobs.map { "\($0.id) \($0.isActive)" } }

    private func jobsChanged() {
        refreshIcon()
        if let openMenu, Self.rowKeys() != menuJobs { menuNeedsUpdate(openMenu) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuJobs = Self.rowKeys()
        let help = NSMenuItem(title: "Drag an image, tap ⇧ to convert, ⌘ for tools", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)

        let jobs = JobCenter.shared.jobs
        if !jobs.isEmpty {
            menu.addItem(.separator())
            // Newest first.
            for job in jobs.reversed() { menu.addItem(Self.rowItem(JobRow(job: job))) }
            if jobs.contains(where: { !$0.isActive }) {
                let clear = NSMenuItem(title: "Clear Finished", action: #selector(clearFinished), keyEquivalent: "")
                clear.target = self
                menu.addItem(clear)
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        if #available(macOS 27, *) { settingsItem.preferredImageVisibility = .hidden } // no automatic gear
        menu.addItem(settingsItem)
        // A switch row rather than a checkmark: a checked standard item makes the menu add a state
        // column that shifts the standard items right but not the job rows.
        menu.addItem(Self.rowItem(LoginRow { [weak self] in self?.setLaunchAtLogin($0) ?? false }))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Halo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// A menu item showing a SwiftUI row, stretched to the menu's width so trailing buttons sit at
    /// the right edge.
    private static func rowItem(_ row: some View) -> NSMenuItem {
        let host = NSHostingView(rootView: row)
        // Measure before dropping the sizing options: without them fittingSize is zero.
        let height = host.fittingSize.height
        host.sizingOptions = [] // or its maximum-size constraint stops the menu widening it
        host.frame = CGRect(origin: .zero, size: CGSize(width: MenuRow.minWidth, height: height))
        host.autoresizingMask = .width
        let item = NSMenuItem()
        item.view = host
        return item
    }

    private func refreshIcon() {
        statusItem.button?.image = JobCenter.shared.overallFraction.map(MenuBarIcon.progress) ?? MenuBarIcon.idle
    }

    @objc private func clearFinished() {
        JobCenter.shared.clearFinished()
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let urls = (response.notification.request.content.userInfo[Notifier.outputsKey] as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case UNNotificationDefaultActionIdentifier, Notifier.revealAction: Job.reveal(urls)
            case Notifier.trashAction: Job.trash(urls)
            default: break
            }
            completionHandler()
        }
    }

    // MARK: Actions

    @objc private func openSettings() {
        settingsWindow.show()
    }

    /// Returns whether Halo launches at login afterwards.
    private func setLaunchAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            openMenu?.cancelTracking() // the alert can't take clicks while the menu is open
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = "\(error.localizedDescription)\n\nTry moving Halo to /Applications first."
            alert.runModal()
        }
        return SMAppService.mainApp.status == .enabled
    }
}

// `Halo [--separator space|dash|underscore] --run <action> <files…>` runs one action headlessly
// (used for testing). Names match the original's separator unless --separator says otherwise.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--run"), args.count > i + 2 {
    let name = args[i + 1].lowercased()
    let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
    let action: ImageAction?
    switch name {
    case "pdf": action = .pdf
    case "compress": action = .compress
    case "strip": action = .strip
    case "trim": action = .trim
    case let s where s.hasPrefix("crop:"):
        // crop:x,y,w,h as fractions of the image, origin top-left
        let v = s.dropFirst(5).split(separator: ",").compactMap { Double($0) }
        action = v.count == 4 ? .crop(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) : nil
    case "fit": action = .fit(1920)
    case let s where s.hasPrefix("scale"):
        // Shrink only: 1…99 percent.
        action = Double(s.dropFirst(5)).flatMap { (1..<100).contains($0) ? .scale($0 / 100) : nil }
    default: action = ImageOps.formats.first { $0.name.lowercased() == name }.map { .convert($0.type) }
    }
    guard let action else {
        print("Unknown action. Formats: \(ImageOps.formats.map(\.name).joined(separator: ", "))")
        exit(2)
    }
    func printError(_ message: String) { FileHandle.standardError.write(Data("Error: \(message)\n".utf8)) }
    do {
        let separator = args.firstIndex(of: "--separator").flatMap { $0 + 1 < i ? NameSeparator(rawValue: args[$0 + 1]) : nil }
        let outcome = try ImageOps.run(action, on: files, separator: separator ?? .matchOriginal)
        for out in outcome.outputs { print(out.path) }
        for failure in outcome.failures { printError("\(failure.name): \(failure.reason)") }
        exit(outcome.failures.isEmpty ? 0 : 1)
    } catch {
        printError(error.localizedDescription)
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
