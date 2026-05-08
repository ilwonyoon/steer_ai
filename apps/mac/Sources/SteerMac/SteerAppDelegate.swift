import AppKit
import Combine

@MainActor
final class SteerAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let status = SteerStatus()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items { item.image = nil }
    }
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items { item.image = nil }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        SparkleController.shared.start()
        Task.detached(priority: .background) {
            AttachmentService.cleanupStaleTempFiles()
        }
        Self.status.$waitingCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.refreshStatusItem(waitingCount: count)
            }
            .store(in: &cancellables)
        SteerSettings.shared.$alwaysOnTop
            .receive(on: RunLoop.main)
            .sink { onTop in
                Self.applyAlwaysOnTop(onTop)
            }
            .store(in: &cancellables)
    }

    static func applyAlwaysOnTop(_ enabled: Bool) {
        let level: NSWindow.Level = enabled ? .floating : .normal
        for window in NSApplication.shared.windows {
            if window.canBecomeKey { window.level = level }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "Open Steer"

        let menu = NSMenu()
        menu.showsStateColumn = false
        let openItem = NSMenuItem(title: "Open Steer", action: #selector(openSteer), keyEquivalent: "")
        openItem.target = self
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(handleConfigure), keyEquivalent: "")
        settingsItem.target = self
        let aboutItem = NSMenuItem(title: "About Steer", action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        let logItem = NSMenuItem(title: "Open agent log", action: #selector(openAgentLog), keyEquivalent: "")
        logItem.target = self
        let revealItem = NSMenuItem(title: "Reveal Steer logs in Finder", action: #selector(revealSteerHome), keyEquivalent: "")
        revealItem.target = self
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        let quitItem = NSMenuItem(title: "Quit Steer", action: #selector(quitSteer), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(openItem)
        menu.addItem(settingsItem)
        menu.addItem(aboutItem)
        menu.addItem(logItem)
        menu.addItem(revealItem)
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        for menuItem in menu.items {
            menuItem.image = nil
            menuItem.indentationLevel = 0
        }

        menu.delegate = self
        item.menu = menu
        statusItem = item
        statusMenu = menu
        refreshStatusItem(waitingCount: 0)
    }

    private func refreshStatusItem(waitingCount: Int) {
        guard let button = statusItem?.button else { return }
        if waitingCount > 0 {
            button.title = "Steer · \(waitingCount)"
        } else {
            button.title = "Steer"
        }
    }

    @objc private func openSteer() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeKey {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func handleConfigure() {
        openSettings()
    }

    private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        // First try to drive SwiftUI's auto-installed Settings command via the
        // app menu (the chain that Cmd+, would use). This is the path most
        // likely to exist on macOS 14+.
        if let appMenu = NSApp.mainMenu?.items.first?.submenu {
            for item in appMenu.items {
                let title = item.title
                if title.contains("Settings") || title.contains("Preferences") || title == "환경설정…" || title == "설정…" {
                    if let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                        return
                    }
                }
            }
        }

        // Fallbacks: try the documented selectors directly.
        let candidates: [Selector] = [
            Selector(("showSettingsWindow:")),
            Selector(("showPreferencesWindow:"))
        ]
        for selector in candidates {
            if NSApp.sendAction(selector, to: nil, from: nil) { return }
        }

        NSLog("Steer: could not open Settings window; main menu items = \(NSApp.mainMenu?.items.first?.submenu?.items.map(\.title) ?? [])")
    }

    @objc private func openAgentLog() {
        let home = ProcessInfo.processInfo.environment["STEER_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".steer").path
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/agent.log"))
    }

    @objc private func revealSteerHome() {
        let home = ProcessInfo.processInfo.environment["STEER_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".steer").path
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: home)])
    }

    @objc private func openAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        let bundleId = info["CFBundleIdentifier"] as? String ?? "ai.steer.mac"

        let alert = NSAlert()
        alert.messageText = "Steer"
        alert.informativeText = """
        version \(version) (\(build))
        bundle \(bundleId)

        Steer is an AI action queue for terminal-based coding agents. \
        Cards surface only when a wrapped session needs a human reply.
        """
        alert.addButton(withTitle: "Reveal logs")
        alert.addButton(withTitle: "Copy diagnostics")
        alert.addButton(withTitle: "Done")

        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            revealSteerHome()
        case .alertSecondButtonReturn:
            copyDiagnostics(version: version, build: build, bundleId: bundleId)
        default:
            break
        }
    }

    private func copyDiagnostics(version: String, build: String, bundleId: String) {
        let home = ProcessInfo.processInfo.environment["STEER_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".steer").path
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString

        let payload = """
        Steer diagnostics

        app version : \(version) (\(build))
        bundle id   : \(bundleId)
        macOS       : \(macOS)
        STEER_HOME  : \(home)
        """

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        SparkleController.shared.checkForUpdates(sender)
    }

    @objc private func quitSteer() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class SteerStatus: ObservableObject {
    @Published var waitingCount: Int = 0
    @Published var pendingFocusSessionId: String?
}
