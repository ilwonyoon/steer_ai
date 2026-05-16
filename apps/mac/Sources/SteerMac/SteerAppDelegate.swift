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
    /// often has Mac running with the window closed. Run a 15s timer
    /// here so /v1/sync/devices stays fresh and iPhone's chip flips
    /// Connected ↔ Stale within ~20s of the Mac going offline (down
    /// from the prior 60s cadence the user noticed as laggy).
    private var heartbeatTimer: Timer?
    private func startHeartbeatTimer() {
        // Wait 5s for refreshMe to settle isSignedIn, then fire the
        // first heartbeat. After that, repeat every 15s.
        // Timer must be retained (heartbeatTimer property) — earlier
        // version stored it as a local inside DispatchQueue.asyncAfter
        // and the closure freed it immediately, so the timer fired 0
        // times and the iPhone chip never saw the Mac.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.fireHeartbeat()
            self.heartbeatTimer = Timer.scheduledTimer(
                withTimeInterval: 15,
                repeats: true
            ) { [weak self] _ in
                // Timer fires on a nonisolated runloop tick. Hop back
                // to the main actor before calling fireHeartbeat,
                // which is @MainActor-isolated (touches AppKit).
                Task { @MainActor [weak self] in
                    self?.fireHeartbeat()
                }
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
        button.image = Self.menuBarImage
        button.imagePosition = waitingCount > 0 ? .imageLeading : .imageOnly
        button.title = waitingCount > 0 ? " \(waitingCount)" : ""
    }

    /// Builds the multi-representation menu-bar image once and
    /// caches it. Without explicit per-scale reps, AppKit only sees
    /// the 1x asset and scales it on retina, producing the soft/blurry
    /// rendering the user reported.
    private static let menuBarImage: NSImage = {
        // 22pt is the canonical menu-bar height; we draw at 22 so the
        // mark uses the full vertical slot. The packaged renditions
        // are 24/48/72px so each retina scale gets a crisp source.
        let pointSize = NSSize(width: 22, height: 22)
        let composite = NSImage(size: pointSize)
        var added = false
        for (suffix, scale) in [("", 1.0), ("@2x", 2.0), ("@3x", 3.0)] {
            guard let url = Bundle.module.url(
                forResource: "MenuBarIcon\(suffix)",
                withExtension: "png"
            ),
            let rep = NSImageRep(contentsOf: url) else { continue }
            // Force the rep to advertise a logical point size, not pixel
            // size, so AppKit picks the right rep at each backing scale.
            rep.size = pointSize
            _ = scale  // scale derived from rep pixel size automatically
            composite.addRepresentation(rep)
            added = true
        }
        if !added {
            // Fallback: SF Symbol so the menu bar is never empty.
            return NSImage(
                systemSymbolName: "rectangle.stack.fill",
                accessibilityDescription: "Steer"
            ) ?? NSImage()
        }
        composite.isTemplate = true  // auto-tints to menu-bar appearance
        composite.size = pointSize
        return composite
    }()

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

        // No main window alive. Try the SwiftUI receiver first —
        // it still works if the user closed only a secondary window
        // but a Settings or similar scene kept the modifier alive.
        NotificationCenter.default.post(name: .steerOpenMainWindow, object: nil)

        // Fallback: send ourselves the same AppleEvent the Dock
        // sends when the user clicks the app icon
        // (`kAEReopenApplication`). AppKit's reopen path is what
        // actually instantiates a SwiftUI WindowGroup whose
        // modifier was torn down with the last window — invoking
        // `applicationShouldHandleReopen` directly only returns the
        // delegate's verdict, it doesn't run the AppKit work that
        // a real Dock click triggers. The 0.05s delay gives the
        // notification path a chance to win when it can.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Skip if the notification path already produced a
            // key-able window. We deliberately don't filter on
            // window.title here — SwiftUI sets the title
            // asynchronously after the window appears, so a strict
            // title match would treat a freshly-opened window as
            // "still missing" and double-open via the AppleEvent
            // path below.
            let alreadyOpen = NSApplication.shared.windows.contains { window in
                window.canBecomeKey && !window.className.contains("NSStatusBarWindow")
            }
            guard !alreadyOpen else { return }

            let target = NSAppleEventDescriptor(processIdentifier: getpid())
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            _ = try? event.sendEvent(options: .defaultOptions, timeout: 5)
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
