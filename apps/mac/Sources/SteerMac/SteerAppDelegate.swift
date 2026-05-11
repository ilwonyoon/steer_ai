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
        startHeartbeatTimer()
    }

    /// Heartbeat must run independent of the main window — SteerRootView's
    /// reload loop is gated on the window being mounted, but the user
    /// often has Mac running with the window closed. Run a 60s timer
    /// here so /v1/sync/devices stays fresh and iPhone's chip stays
    /// accurate regardless of UI state.
    private var heartbeatTimer: Timer?
    private func startHeartbeatTimer() {
        // Wait 5s for refreshMe to settle isSignedIn, then fire the
        // first heartbeat. After that, repeat every 60s.
        // Timer must be retained (heartbeatTimer property) — earlier
        // version stored it as a local inside DispatchQueue.asyncAfter
        // and the closure freed it immediately, so the timer fired 0
        // times and the iPhone chip never saw the Mac.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.fireHeartbeat()
            self.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: 60,
                repeats: true
            ) { [weak self] _ in
                self?.fireHeartbeat()
            }
            if let timer = self.heartbeatTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func fireHeartbeat() {
        Task { @MainActor in
            let toggleOn = SteerSettings.shared.iPhoneSyncEnabled
            await SyncClient.shared.sendDeviceHeartbeat(syncEnabled: toggleOn)
        }
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

    /// Updates the menu-bar button. The icon is the Steer gear-shift
    /// mark exported as a template image — the shape is solid black
    /// with anti-aliased alpha, so macOS auto-tints it for the
    /// current menu-bar appearance (white on dark, black on light).
    /// waitingCount > 0 appends a small numeric badge.
    private func refreshStatusItem(waitingCount: Int) {
        guard let button = statusItem?.button else { return }
        // SwiftPM packages executableTarget resources under Bundle.module.
        // NSImage(named:) only looks at the main bundle, which is why we
        // load directly from .module here.
        let image: NSImage?
        if let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
           let loaded = NSImage(contentsOf: url) {
            image = loaded
        } else {
            // Fallback so the bar item is never blank in a broken build.
            image = NSImage(systemSymbolName: "rectangle.stack.fill",
                            accessibilityDescription: "Steer")
        }
        image?.isTemplate = true   // macOS auto-tints template images
        // Default menu-bar item size is 22pt; the @2x/@3x renditions
        // packaged alongside MenuBarIcon.png handle retina densities.
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = waitingCount > 0 ? .imageLeading : .imageOnly
        button.title = waitingCount > 0 ? " \(waitingCount)" : ""
    }

    @objc private func openSteer() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        ensureMainWindowVisible()
    }

    /// Bring the SteerRootView WindowGroup forward. Three states to
    /// handle, with an important asymmetry:
    ///
    ///   1. A key-able window already exists → just deminiaturize +
    ///      makeKeyAndOrderFront. Cheap path.
    ///   2. NO key-able window (user closed it; SwiftUI dismantled the
    ///      WindowGroup instance) → AppKit's "reopen" channel is
    ///      unreliable here because the SwiftUI Scene that listens for
    ///      `openWindow(id:)` was destroyed with the window. The
    ///      durable wake-up is `newDocument:` — SwiftUI WindowGroup
    ///      registers as the responder for it and instantiates a fresh
    ///      scene every time. We send it through `NSApp.sendAction`
    ///      with `to: nil` so the responder chain finds whatever
    ///      registered handler is alive.
    ///
    /// Each previous attempt (NotificationCenter post +
    /// applicationShouldHandleReopen) only worked while the
    /// in-WindowGroup receiver was still alive. After the user closed
    /// the last window the receiver was gone, which is exactly when
    /// "Open Steer" had to work and didn't.
    func ensureMainWindowVisible() {
        // Filter to "main"-shaped windows: the SteerRootView WindowGroup
        // sets a known title prefix and SwiftUI exposes it via
        // window.title. Settings/About sheets use their own NSWindow
        // chain so they never satisfy this predicate.
        let mainWindows = NSApplication.shared.windows.filter { window in
            guard window.canBecomeKey else { return false }
            let title = window.title
            return title == "Steer" || title.hasPrefix("Steer · ")
        }

        if let main = mainWindows.first {
            main.deminiaturize(nil)
            main.makeKeyAndOrderFront(nil)
            return
        }

        // No main window alive. The SwiftUI WindowGroup listens for
        // the `steerOpenMainWindow` notification via
        // OpenMainWindowReceiver and re-opens itself via
        // `openWindow(id: "main")`. We deliberately don't call
        // `newDocument:` — under macOS 26's LSUIElement apps it
        // surfaces a "No document could be created" alert instead of
        // wiring back to the SwiftUI WindowGroup.
        NotificationCenter.default.post(name: .steerOpenMainWindow, object: nil)
        // applicationShouldHandleReopen is the AppKit hook AppKit
        // itself calls on Dock click — invoking it manually nudges
        // macOS to recreate the scene when the receiver above was
        // already torn down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            _ = NSApplication.shared.delegate?.applicationShouldHandleReopen?(
                NSApplication.shared,
                hasVisibleWindows: false
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
