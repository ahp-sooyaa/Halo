import AppKit
import SwiftUI

/// Which wheel items are turned on. Stored as the set of turned-off keys, so items added in
/// future versions appear enabled by default.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private static let defaultsKey = "disabledWheelItems"

    @Published private var disabled: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabled).sorted(), forKey: Self.defaultsKey) }
    }

    private init() {
        disabled = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    private static func key(_ item: WheelItem, _ mode: WheelMode) -> String {
        "\(mode == .convert ? "convert" : "tools").\(item.id)"
    }

    func isEnabled(_ item: WheelItem, in mode: WheelMode) -> Bool {
        !disabled.contains(Self.key(item, mode))
    }

    func setEnabled(_ enabled: Bool, _ item: WheelItem, in mode: WheelMode) {
        if enabled { disabled.remove(Self.key(item, mode)) } else { disabled.insert(Self.key(item, mode)) }
    }

    func setAll(_ enabled: Bool, in mode: WheelMode) {
        for item in WheelModel.catalog(for: mode) { setEnabled(enabled, item, in: mode) }
    }

    func binding(_ item: WheelItem, in mode: WheelMode) -> Binding<Bool> {
        Binding(get: { self.isEnabled(item, in: mode) }, set: { self.setEnabled($0, item, in: mode) })
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Halo Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: .shared))
            window.setContentSize(window.contentView!.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Convert", key: "⇧", mode: .convert)
            section("Tools", key: "⌘", mode: .tools)
            Text("Turned-off items are hidden from the wheel. If every item in a wheel is off, its key does nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
    }

    private func section(_ title: String, key: String, mode: WheelMode) -> some View {
        let items = WheelModel.catalog(for: mode)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(key)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.85)))
                    .foregroundStyle(.white)
                Text(title).font(.headline)
                Spacer()
                Button("All On") { settings.setAll(true, in: mode) }
                Button("All Off") { settings.setAll(false, in: mode) }
            }
            .controlSize(.small)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                      alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    Toggle(isOn: settings.binding(item, in: mode)) {
                        Text(item.subtitle.map { "\(item.title) \($0)" } ?? item.title)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}
