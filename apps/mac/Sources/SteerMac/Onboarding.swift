import Foundation
import AppKit
import UserNotifications

enum OnboardingStepKind: String, CaseIterable, Identifiable {
    case cli
    case hooks
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cli: return "Install the steer CLI"
        case .hooks: return "Wire up Claude Stop hooks"
        case .notifications: return "Allow notifications"
        }
    }

    var detail: String {
        switch self {
        case .cli:
            return "Adds a steer command to your shell so you can launch wrapped Claude or Codex sessions from any terminal."
        case .hooks:
            return "Lets Claude Code tell Steer when it stops or asks a question. Without this, cards fall back to a less precise PTY heuristic."
        case .notifications:
            return "Steer posts a banner when a session needs your attention. You can change this later in System Settings."
        }
    }
}

enum OnboardingStepStatus: Equatable {
    case unknown
    case checking
    case satisfied(detail: String)
    case actionable(detail: String)
    case failed(detail: String)
    case skipped

    var isTerminal: Bool {
        switch self {
        case .satisfied, .skipped: return true
        case .unknown, .checking, .actionable, .failed: return false
        }
    }
}

struct OnboardingState: Equatable {
    var cli: OnboardingStepStatus = .unknown
    var hooks: OnboardingStepStatus = .unknown
    var notifications: OnboardingStepStatus = .unknown
}

@MainActor
final class OnboardingController: ObservableObject {
    static let didCompleteKey = "ai.steer.mac.didCompleteOnboarding"

    @Published private(set) var state = OnboardingState()
    @Published private(set) var isWorking = false

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: didCompleteKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: didCompleteKey)
    }

    static func resetForTesting() {
        UserDefaults.standard.removeObject(forKey: didCompleteKey)
    }

    func refreshAll() async {
        async let cli = OnboardingChecks.cliStatus()
        async let hooks = OnboardingChecks.hookStatus()
        async let notifications = OnboardingChecks.notificationStatus()
        let resolved = await (cli, hooks, notifications)
        state = OnboardingState(
            cli: resolved.0,
            hooks: resolved.1,
            notifications: resolved.2
        )
    }

    func runStep(_ kind: OnboardingStepKind) async {
        isWorking = true
        defer { isWorking = false }

        switch kind {
        case .cli:
            state.cli = .checking
            state.cli = await OnboardingActions.installCLI()
        case .hooks:
            state.hooks = .checking
            state.hooks = await OnboardingActions.installHooks()
        case .notifications:
            state.notifications = .checking
            state.notifications = await OnboardingActions.requestNotifications()
        }
    }

    func skipStep(_ kind: OnboardingStepKind) {
        switch kind {
        case .cli: state.cli = .skipped
        case .hooks: state.hooks = .skipped
        case .notifications: state.notifications = .skipped
        }
    }

    var isReadyToFinish: Bool {
        state.cli.isTerminal && state.hooks.isTerminal && state.notifications.isTerminal
    }
}

// MARK: - Status checks

enum OnboardingChecks {
    static func cliStatus() async -> OnboardingStepStatus {
        await Task.detached(priority: .utility) {
            for path in cliCandidatePaths() {
                if FileManager.default.isExecutableFile(atPath: path) {
                    return OnboardingStepStatus.satisfied(detail: "Installed at \(path).")
                }
            }
            return .actionable(detail: "Not found on PATH. Steer can install a symlink in your home bin.")
        }.value
    }

    static func hookStatus() async -> OnboardingStepStatus {
        await Task.detached(priority: .utility) {
            let url = claudeSettingsURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                return OnboardingStepStatus.actionable(detail: "No ~/.claude/settings.local.json found yet — Steer can create it.")
            }
            do {
                let data = try Data(contentsOf: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .actionable(detail: "Settings file is not a JSON object — Steer will rewrite the hooks section.")
                }
                let hooks = (json["hooks"] as? [String: Any]) ?? [:]
                let stop = hooks["Stop"] as? [Any] ?? []
                let notif = hooks["Notification"] as? [Any] ?? []
                let installed = describesSteer(stop) || describesSteer(notif)
                if installed {
                    return .satisfied(detail: "Stop / Notification hooks point to steer.")
                }
                return .actionable(detail: "Settings file exists but doesn't reference steer.")
            } catch {
                return .actionable(detail: "Could not read settings: \(error.localizedDescription).")
            }
        }.value
    }

    static func notificationStatus() async -> OnboardingStepStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .satisfied(detail: "Notifications are enabled.")
        case .denied:
            return .failed(detail: "Notifications were declined. Enable them in System Settings → Notifications.")
        case .notDetermined:
            return .actionable(detail: "macOS hasn't asked yet — Steer can prompt now.")
        @unknown default:
            return .actionable(detail: "Unknown authorization status; tap Allow to retry.")
        }
    }

    private static func describesSteer(_ blocks: [Any]) -> Bool {
        for entry in blocks {
            guard let dict = entry as? [String: Any],
                  let hooks = dict["hooks"] as? [[String: Any]] else { continue }
            for hook in hooks {
                if let command = hook["command"] as? String, command.contains("steer hook claude") {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Actions

enum OnboardingActions {
    static func installCLI() async -> OnboardingStepStatus {
        await Task.detached(priority: .utility) {
            // Always link the userland path first; a system path requires admin
            // and we shouldn't pop a sudo prompt unprompted.
            let target = packagedCLIPath()
            // packagedCLIPath() returns "steer" as a release-build fallback
            // when no bundled CLI was shipped. Resolve a real install in
            // that case rather than symlinking the literal string "steer".
            if target == "steer" {
                if let resolved = resolveSteerExecutable() {
                    return .satisfied(detail: "Found steer on PATH at \(resolved). No symlink needed.")
                }
                return .failed(detail: "No bundled steer CLI found. Install Node 22.5+ and run `npm install` in the Steer repo, then re-open onboarding.")
            }
            guard FileManager.default.fileExists(atPath: target) else {
                return OnboardingStepStatus.failed(detail: "Could not locate bundled CLI at \(target).")
            }
            let userBin = ("~/.local/bin" as NSString).expandingTildeInPath
            do {
                try FileManager.default.createDirectory(atPath: userBin, withIntermediateDirectories: true)
                let dest = (userBin as NSString).appendingPathComponent("steer")
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.createSymbolicLink(atPath: dest, withDestinationPath: target)
                return .satisfied(detail: "Linked \(dest) → \(target). Make sure ~/.local/bin is on your PATH.")
            } catch {
                return .failed(detail: "Could not create symlink: \(error.localizedDescription).")
            }
        }.value
    }

    static func installHooks() async -> OnboardingStepStatus {
        await Task.detached(priority: .utility) {
            let cli = resolveSteerExecutable()
            guard let cli else {
                return OnboardingStepStatus.failed(detail: "Install the steer CLI first.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = ["install-claude-hooks"]
            process.environment = invocationEnvironment()
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let stderr = Pipe()
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return .satisfied(detail: "Stop / Notification hooks installed.")
                }
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                return .failed(detail: "Hook install failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines)).")
            } catch {
                return .failed(detail: "Could not run steer: \(error.localizedDescription).")
            }
        }.value
    }

    static func requestNotifications() async -> OnboardingStepStatus {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                return .satisfied(detail: "Notifications are enabled.")
            }
            return .failed(detail: "Notifications were declined. Enable them in System Settings → Notifications.")
        } catch {
            return .failed(detail: "Authorization request failed: \(error.localizedDescription).")
        }
    }
}

// MARK: - Path helpers

private func cliCandidatePaths() -> [String] {
    var paths = [
        "/opt/homebrew/bin/steer",
        "/usr/local/bin/steer",
        ("~/.local/bin/steer" as NSString).expandingTildeInPath
    ]
    if let envPath = ProcessInfo.processInfo.environment["PATH"] {
        for component in envPath.split(separator: ":") {
            let candidate = (String(component) as NSString).appendingPathComponent("steer")
            if !paths.contains(candidate) {
                paths.append(candidate)
            }
        }
    }
    return paths
}

private func resolveSteerExecutable() -> String? {
    cliCandidatePaths().first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func packagedCLIPath() -> String {
    if let bundled = Bundle.main.url(forResource: "steer", withExtension: nil, subdirectory: "cli")?.path,
       FileManager.default.isExecutableFile(atPath: bundled) {
        return bundled
    }
#if DEBUG
    // Source-tree fallback for `swift run` developer launches only.
    // Never used in release builds — avoids TCC Document Access prompts.
    let fallback = "/Users/\(NSUserName())/Documents/Steer_ai/packages/cli/src/index.js"
    return fallback
#else
    // In release builds, fall back to a PATH-resolved steer.
    return "steer"
#endif
}

private func claudeSettingsURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".claude/settings.local.json")
}

private func invocationEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["PATH"] = [env["PATH"], defaultPath].compactMap(\.self).joined(separator: ":")
    return env
}
