import AppKit
import Combine

@MainActor
final class SteerAppDelegate: NSObject, NSApplicationDelegate {
    static let status = SteerStatus()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
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
        item.button?.target = self
        item.button?.action = #selector(handleStatusClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Steer", action: #selector(openSteer), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open agent log", action: #selector(openAgentLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Steer", action: #selector(quitSteer), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }

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

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            openSteer()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
        } else {
            openSteer()
        }
    }

    @objc private func openSteer() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows where window.canBecomeKey {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    @objc private func openAgentLog() {
        let home = ProcessInfo.processInfo.environment["STEER_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".steer").path
        NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/agent.log"))
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
