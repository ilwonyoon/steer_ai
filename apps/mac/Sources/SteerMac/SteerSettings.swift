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
    @Published var notifyBlocker: Bool {
        didSet { defaults.set(notifyBlocker, forKey: Key.notifyBlocker) }
    }
    @Published var notifyQuestion: Bool {
        didSet { defaults.set(notifyQuestion, forKey: Key.notifyQuestion) }
    }
    @Published var notifyDecision: Bool {
        didSet { defaults.set(notifyDecision, forKey: Key.notifyDecision) }
    }
    @Published var notifyWaiting: Bool {
        didSet { defaults.set(notifyWaiting, forKey: Key.notifyWaiting) }
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

    private let defaults = UserDefaults.standard

    private enum Key {
        static let notificationsEnabled = "steer.notifications.enabled"
        static let soundEnabled = "steer.notifications.sound"
        static let notifyBlocker = "steer.notifications.category.blocker"
        static let notifyQuestion = "steer.notifications.category.question"
        static let notifyDecision = "steer.notifications.category.decision"
        static let notifyWaiting = "steer.notifications.category.waiting"
        static let dndEnabled = "steer.notifications.dnd.enabled"
        static let dndStartHour = "steer.notifications.dnd.startHour"
        static let dndEndHour = "steer.notifications.dnd.endHour"
        static let alwaysOnTop = "steer.window.alwaysOnTop"
        static let runAtLogin = "steer.window.runAtLogin"
    }

    init() {
        defaults.register(defaults: [
            Key.notificationsEnabled: true,
            Key.soundEnabled: true,
            Key.notifyBlocker: true,
            Key.notifyQuestion: true,
            Key.notifyDecision: true,
            Key.notifyWaiting: true,
            Key.dndEnabled: false,
            Key.dndStartHour: 22,
            Key.dndEndHour: 8,
            Key.alwaysOnTop: false,
            Key.runAtLogin: false
        ])
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        notifyBlocker = defaults.bool(forKey: Key.notifyBlocker)
        notifyQuestion = defaults.bool(forKey: Key.notifyQuestion)
        notifyDecision = defaults.bool(forKey: Key.notifyDecision)
        notifyWaiting = defaults.bool(forKey: Key.notifyWaiting)
        dndEnabled = defaults.bool(forKey: Key.dndEnabled)
        dndStartHour = defaults.integer(forKey: Key.dndStartHour)
        dndEndHour = defaults.integer(forKey: Key.dndEndHour)
        alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        runAtLogin = defaults.bool(forKey: Key.runAtLogin)
    }

    func shouldNotify(category: String) -> Bool {
        guard notificationsEnabled else { return false }
        if isInDoNotDisturb() { return false }
        switch category {
        case "blocker": return notifyBlocker
        case "question": return notifyQuestion
        case "decision": return notifyDecision
        case "waiting": return notifyWaiting
        default: return false
        }
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
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 360)
    }

    private var generalTab: some View {
        Form {
            Toggle("Always on top", isOn: $settings.alwaysOnTop)
            Toggle("Open Steer at login", isOn: $settings.runAtLogin)
        }
        .padding(20)
    }

    private var notificationsTab: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $settings.notificationsEnabled)
                Toggle("Play sound", isOn: $settings.soundEnabled)
                    .disabled(!settings.notificationsEnabled)
            }
            Section("Notify on") {
                Toggle("Blocker", isOn: $settings.notifyBlocker)
                Toggle("Question", isOn: $settings.notifyQuestion)
                Toggle("Decision", isOn: $settings.notifyDecision)
                Toggle("Waiting", isOn: $settings.notifyWaiting)
            }
            .disabled(!settings.notificationsEnabled)
            Section("Do not disturb") {
                Toggle("Quiet hours", isOn: $settings.dndEnabled)
                HStack {
                    Stepper("Start: \(formatHour(settings.dndStartHour))",
                            value: $settings.dndStartHour, in: 0...23)
                    Stepper("End: \(formatHour(settings.dndEndHour))",
                            value: $settings.dndEndHour, in: 0...23)
                }
                .disabled(!settings.dndEnabled)
            }
            .disabled(!settings.notificationsEnabled)
        }
        .padding(20)
    }

    private var aboutTab: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let steerHome = ProcessInfo.processInfo.environment["STEER_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".steer").path
        return VStack(alignment: .leading, spacing: 12) {
            Text("Steer")
                .font(.system(size: 20, weight: .semibold))
            Text("Version \(version) (\(build))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Steer home").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(steerHome).font(.system(size: 11, design: .monospaced))
            }
            HStack(spacing: 12) {
                Button("Open agent log") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "\(steerHome)/agent.log"))
                }
                Button("Open data folder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: steerHome))
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
    }

    private func formatHour(_ hour: Int) -> String {
        let h = max(0, min(23, hour))
        return String(format: "%02d:00", h)
    }
}
