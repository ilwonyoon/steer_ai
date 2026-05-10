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
        // Touch SyncClient so it init's and (if a session JWT exists)
        // restores the signed-in state + WebSocket without waiting for
        // the main window to open. The status bar can be the only
        // visible UI while sync still needs to run in the background.
        _ = SyncClient.shared
        // Background launches (Open at Login, `open -g`) sometimes finish
        // with NSApplication.windows == [] because AppKit never auto-
        // creates a window for a backgrounded process. The status bar is
        // up but the user has nothing to click. Force-activate then
        // post the bridge notification so the SwiftUI WindowGroup
        // materializes via openWindow(id:).
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            self.ensureMainWindowVisible()
        }
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
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleConfigure), keyEquivalent: ",")
        settingsItem.target = self
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        let quitItem = NSMenuItem(title: "Quit Steer", action: #selector(quitSteer), keyEquivalent: "q")
        quitItem.target = self

        menu.addItem(openItem)
        menu.addItem(settingsItem)
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
        ensureMainWindowVisible()
    }

    /// Bring the SteerRootView WindowGroup forward, creating it if no
    /// instance exists. Handles three cases:
    ///   1. Window exists and is key/visible -> bring forward
    ///   2. Window exists but minimized/hidden -> deminiaturize
    ///   3. No window (background launch / user quit all windows) ->
    ///      post bridge notification; SwiftUI's openWindow modifier in
    ///      SteerMacApp picks it up and instantiates the scene.
    func ensureMainWindowVisible() {
        var reopened = false
        for window in NSApplication.shared.windows where window.canBecomeKey {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            reopened = true
        }
        if !reopened {
            NotificationCenter.default.post(name: .steerOpenMainWindow, object: nil)
            // applicationShouldHandleReopen as a belt-and-braces fallback
            // for Dock-icon clicks on macOS versions where the
            // notification doesn't get a receiver in time.
            _ = NSApplication.shared.delegate?.applicationShouldHandleReopen?(
                NSApplication.shared, hasVisibleWindows: false
            )
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Returning true tells AppKit to reopen the SwiftUI WindowGroup.
        return true
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
