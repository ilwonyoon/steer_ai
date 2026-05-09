import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class SteerSettings: ObservableObject {
    static let shared = SteerSettings()

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) }
    }
    @Published var dndEnabled: Bool {
        didSet { defaults.set(dndEnabled, forKey: Key.dndEnabled) }
    }
    @Published var dndStartHour: Int {
        didSet { defaults.set(dndStartHour, forKey: Key.dndStartHour) }
    }
    @Published var dndEndHour: Int {
        didSet { defaults.set(dndEndHour, forKey: Key.dndEndHour) }
    }
    @Published var alwaysOnTop: Bool {
        didSet { defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop) }
    }
    @Published var runAtLogin: Bool {
        didSet {
            defaults.set(runAtLogin, forKey: Key.runAtLogin)
            applyRunAtLogin(runAtLogin)
        }
    }
    @Published var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: Key.iCloudSyncEnabled) }
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let notificationsEnabled = "steer.notifications.enabled"
        static let soundEnabled = "steer.notifications.sound"
        static let dndEnabled = "steer.notifications.dnd.enabled"
        static let dndStartHour = "steer.notifications.dnd.startHour"
        static let dndEndHour = "steer.notifications.dnd.endHour"
        static let alwaysOnTop = "steer.window.alwaysOnTop"
        static let runAtLogin = "steer.window.runAtLogin"
        static let iCloudSyncEnabled = "steer.sync.iCloud.enabled"
    }

    init() {
        defaults.register(defaults: [
            Key.notificationsEnabled: true,
            Key.soundEnabled: true,
            Key.dndEnabled: false,
            Key.dndStartHour: 22,
            Key.dndEndHour: 8,
            Key.alwaysOnTop: false,
            Key.runAtLogin: false,
            Key.iCloudSyncEnabled: false
        ])
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        dndEnabled = defaults.bool(forKey: Key.dndEnabled)
        dndStartHour = defaults.integer(forKey: Key.dndStartHour)
        dndEndHour = defaults.integer(forKey: Key.dndEndHour)
        alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        runAtLogin = defaults.bool(forKey: Key.runAtLogin)
        iCloudSyncEnabled = defaults.bool(forKey: Key.iCloudSyncEnabled)
    }

    func shouldNotify(category: String) -> Bool {
        guard notificationsEnabled else { return false }
        if isInDoNotDisturb() { return false }
        return ["blocker", "question", "decision", "waiting"].contains(category)
    }

    private func isInDoNotDisturb() -> Bool {
        guard dndEnabled else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        if dndStartHour == dndEndHour { return false }
        if dndStartHour < dndEndHour {
            return hour >= dndStartHour && hour < dndEndHour
        }
        return hour >= dndStartHour || hour < dndEndHour
    }

    private func applyRunAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status != .notRegistered { try service.unregister() }
            }
        } catch {
            NSLog("Steer run-at-login update failed: \(error.localizedDescription)")
        }
    }
}

struct SteerSettingsView: View {
    @ObservedObject var settings: SteerSettings = .shared

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationsPane(settings: settings)
                .tabItem { Label("Notifications", systemImage: "bell") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 440)
    }
}

private struct GeneralPane: View {
    @ObservedObject var settings: SteerSettings

    var body: some View {
        Form {
            Section("Window") {
                Toggle("Keep window on top of other apps", isOn: $settings.alwaysOnTop)
                Toggle("Open Steer at login", isOn: $settings.runAtLogin)
            }

            Section("iCloud sync (alpha)") {
                Toggle("Publish action cards to iCloud for the iPhone app", isOn: $settings.iCloudSyncEnabled)
                Text("When on, this Mac uploads card titles, summaries, and the visible terminal excerpt to your private iCloud database so Steer for iPhone can show them. Raw transcripts and attachments stay local. The toggle is alpha — expect rough edges until iPhone TestFlight ships.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Folder access") {
                Text("Steer usually doesn't need any extra permission. If a session under Documents, Desktop, or Downloads ever stops appearing, open Full Disk Access in System Settings, click the + button, and add Steer (the Reveal button below opens its location in Finder).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button("Open Full Disk Access…") { openFullDiskAccess() }
                    Button("Reveal Steer in Finder") { revealSteerInFinder() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func openFullDiskAccess() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for raw in candidates {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func revealSteerInFinder() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct NotificationsPane: View {
    @ObservedObject var settings: SteerSettings

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Show banners for new action cards", isOn: $settings.notificationsEnabled)
                Toggle("Play sound", isOn: $settings.soundEnabled)
                    .disabled(!settings.notificationsEnabled)
            }

            Section("Quiet hours") {
                Toggle("Mute notifications during quiet hours", isOn: $settings.dndEnabled)
                HStack(spacing: 18) {
                    Stepper(value: $settings.dndStartHour, in: 0...23) {
                        Text("Start \(formatHour(settings.dndStartHour))")
                    }
                    Stepper(value: $settings.dndEndHour, in: 0...23) {
                        Text("End \(formatHour(settings.dndEndHour))")
                    }
                    Spacer()
                }
                .disabled(!settings.dndEnabled)
            }
            .disabled(!settings.notificationsEnabled)
        }
        .formStyle(.grouped)
    }

    private func formatHour(_ hour: Int) -> String {
        let h = max(0, min(23, hour))
        return String(format: "%02d:00", h)
    }
}

private struct AboutPane: View {
    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        let bundleId = info["CFBundleIdentifier"] as? String ?? "ai.steer.mac"
        let steerHome = ProcessInfo.processInfo.environment["STEER_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".steer").path

        return Form {
            Section("Steer") {
                LabeledContent("Version") {
                    Text("\(version) (\(build))")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Bundle") {
                    Text(bundleId)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                Text(steerHome)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button("Open data folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: steerHome))
                    }
                    Button("Open agent log") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "\(steerHome)/agent.log"))
                    }
                    Button("Copy diagnostics") {
                        copyDiagnostics(version: version, build: build, bundleId: bundleId, steerHome: steerHome)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func copyDiagnostics(version: String, build: String, bundleId: String, steerHome: String) {
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        let payload = """
        Steer diagnostics

        app version : \(version) (\(build))
        bundle id   : \(bundleId)
        macOS       : \(macOS)
        STEER_HOME  : \(steerHome)
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
    }
}
