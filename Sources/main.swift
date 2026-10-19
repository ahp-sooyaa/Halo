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
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.idle

        let menu = NSMenu()
        menu.delegate = self // rebuilt each time it opens, see menuNeedsUpdate
        statusItem.menu = menu
        loginItem.target = self

        Notifier.setUp(delegate: self)
        JobCenter.shared.onChange = { [weak self] in self?.refreshIcon() }

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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let help = NSMenuItem(title: "Drag an image, tap ⇧ to convert, ⌘ for tools", action: nil, keyEquivalent: "")
        help.isEnabled = false
        menu.addItem(help)

        let jobs = JobCenter.shared.jobs
        if !jobs.isEmpty {
            menu.addItem(.separator())
            // Newest first.
            for job in jobs.reversed() {
                let host = NSHostingView(rootView: JobRow(job: job))
                host.frame = CGRect(origin: .zero, size: CGSize(width: JobRow.width, height: host.fittingSize.height))
                let item = NSMenuItem()
                item.view = host
                menu.addItem(item)
            }
            if jobs.contains(where: { !$0.isActive }) {
                let clear = NSMenuItem(title: "Clear Finished", action: #selector(clearFinished), keyEquivalent: "")
                clear.target = self
                menu.addItem(clear)
            }
        }

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        refreshLoginItem()
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Halo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        let paths = response.notification.request.content.userInfo[Notifier.outputsKey] as? [String] ?? []
        let tapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == Notifier.revealAction
        DispatchQueue.main.async {
            if tapped { Job.reveal(paths.map { URL(fileURLWithPath: $0) }) }
            completionHandler()
        }
    }

    // MARK: Actions

    @objc private func openSettings() {
        settingsWindow.show()
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
