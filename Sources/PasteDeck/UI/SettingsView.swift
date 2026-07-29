import AppKit
import Carbon.HIToolbox
import PasteDeckCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show(model: DeckModel) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "PasteDeck Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct SettingsView: View {
    @ObservedObject var model: DeckModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            HistorySettings(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            PrivacySettings(model: model)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var model: DeckModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var pasteAutomatically = Preferences.shared.pasteAutomatically
    @State private var restoreFilter = Preferences.shared.restoreFilterOnOpen
    @State private var loginError: String?
    @State private var accessibilityTrusted = Permissions.isAccessibilityTrusted

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Open the deck")
                    Spacer()
                    HotKeyRecorder()
                }
                Toggle("Start PasteDeck at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        loginError = LoginItem.setEnabled(value)
                        Preferences.shared.launchAtLogin = value
                    }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Pasting") {
                Toggle("Paste immediately into the previous app", isOn: $pasteAutomatically)
                    .onChange(of: pasteAutomatically) { _, value in
                        Preferences.shared.pasteAutomatically = value
                    }
                HStack {
                    Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(accessibilityTrusted ? .green : .orange)
                    Text(accessibilityTrusted
                         ? "Accessibility access granted."
                         : "Accessibility access is required to press ⌘V for you.")
                    .font(.caption)
                    Spacer()
                    if !accessibilityTrusted {
                        Button("Grant…") {
                            Permissions.requestAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }
            }

            Section("Appearance") {
                Toggle("Remember the last category", isOn: $restoreFilter)
                    .onChange(of: restoreFilter) { _, value in
                        Preferences.shared.restoreFilterOnOpen = value
                    }
                LabeledContent("Deck height", value: "\(Int(Theme.deckHeight)) pt")
                Text("The panel sizes itself from its rows and card height.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            accessibilityTrusted = Permissions.isAccessibilityTrusted
        }
    }
}

// MARK: - History

private struct HistorySettings: View {
    @ObservedObject var model: DeckModel
    @State private var maxItems = Preferences.shared.maxItems
    @State private var maxAgeDays = Preferences.shared.maxAgeDays
    @State private var maxMegabytes = Preferences.shared.maxMegabytes
    @State private var usage = "…"
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Text("Pinned clippings and anything filed into a category are never removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Limits") {
                limitRow(
                    title: "Keep at most",
                    value: $maxItems,
                    unit: "clippings",
                    options: [0, 200, 500, 1000, 2000, 5000, 20000]
                ) { Preferences.shared.maxItems = $0 }

                limitRow(
                    title: "Delete after",
                    value: $maxAgeDays,
                    unit: "days",
                    options: [0, 1, 7, 14, 30, 90, 365]
                ) { Preferences.shared.maxAgeDays = $0 }

                limitRow(
                    title: "Use at most",
                    value: $maxMegabytes,
                    unit: "MB",
                    options: [0, 128, 512, 1024, 2048, 8192]
                ) { Preferences.shared.maxMegabytes = $0 }
            }

            Section("Storage") {
                LabeledContent("Currently using", value: usage)
                HStack {
                    Button("Clean Up Now") {
                        AppController.shared?.runMaintenance(force: true)
                        refreshUsage()
                    }
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                }
                Text(AppPaths.supportDirectory.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshUsage)
        .confirmationDialog(
            "Delete all unpinned clippings?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Delete Unpinned", role: .destructive) {
                _ = try? model.store.deleteAll()
                AppController.shared?.runMaintenance(force: true)
                model.reload(resetSelection: true)
                refreshUsage()
            }
            Button("Delete Everything, Including Pinned", role: .destructive) {
                _ = try? model.store.deleteAll(everything: true)
                AppController.shared?.runMaintenance(force: true)
                model.reload(resetSelection: true)
                refreshUsage()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func limitRow(
        title: String,
        value: Binding<Int>,
        unit: String,
        options: [Int],
        apply: @escaping (Int) -> Void
    ) -> some View {
        Picker(title, selection: value) {
            ForEach(options, id: \.self) { option in
                Text(option == 0 ? "No limit" : "\(option.formatted()) \(unit)").tag(option)
            }
        }
        .onChange(of: value.wrappedValue) { _, newValue in apply(newValue) }
    }

    private func refreshUsage() {
        guard let stats = try? Retention.usage(store: model.store) else {
            usage = "unavailable"
            return
        }
        usage = "\(stats.items.formatted()) clippings · \(ByteFormat.string(stats.bytes + stats.blobBytes))"
            + (stats.protectedItems > 0 ? " · \(stats.protectedItems) protected" : "")
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    @ObservedObject var model: DeckModel
    @State private var excluded = Preferences.shared.excludedBundleIDs
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Text("PasteDeck never records pasteboards marked as concealed — that covers 1Password, Keychain Access and most password managers. Add any other app you'd rather it ignored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ignored apps") {
                if excluded.isEmpty {
                    Text("No apps are ignored.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    List(selection: $selection) {
                        ForEach(excluded, id: \.self) { bundleID in
                            HStack(spacing: 8) {
                                if let icon = AppSourceResolver.shared.icon(forBundleID: bundleID) {
                                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                                }
                                Text(displayName(for: bundleID))
                                Spacer()
                                Text(bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .tag(bundleID)
                        }
                    }
                    .frame(height: 160)
                }

                HStack {
                    Button("Add App…", action: addApp)
                    Button("Remove") {
                        guard let selection else { return }
                        excluded.removeAll { $0 == selection }
                        Preferences.shared.excludedBundleIDs = excluded
                        self.selection = nil
                    }
                    .disabled(selection == nil)
                }
            }

            Section("Everything stays on this Mac") {
                Text("History lives in a local SQLite database. PasteDeck contains no networking code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { excluded = Preferences.shared.excludedBundleIDs }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
            if !excluded.contains(identifier) { excluded.append(identifier) }
        }
        Preferences.shared.excludedBundleIDs = excluded
    }
}

// MARK: - Hot key recorder

private struct HotKeyRecorder: View {
    @State private var shortcut = HotKeyCenter.Shortcut(
        keyCode: UInt32(Preferences.shared.hotKeyCode),
        modifiers: UInt32(Preferences.shared.hotKeyModifiers)
    )
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press keys…" : shortcut.displayString)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .frame(minWidth: 70)
                .padding(.horizontal, Theme.space2)
                .padding(.vertical, Theme.space1)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: Theme.focusRing)
                )
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let candidate = HotKeyCenter.Shortcut.from(event: event)
            // Require a modifier, or the shortcut would swallow ordinary typing.
            guard candidate.modifiers != 0 else { return nil }

            shortcut = candidate
            Preferences.shared.hotKeyCode = Int(candidate.keyCode)
            Preferences.shared.hotKeyModifiers = Int(candidate.modifiers)
            AppController.shared?.reloadHotKey()
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
