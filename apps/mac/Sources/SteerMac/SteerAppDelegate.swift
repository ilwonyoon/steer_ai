import AppKit
import Combine

@MainActor
final class SteerAppDelegate: NSObject, NSApplicationDelegate {
    static let shared = SteerStatus()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        Self.shared.$waitingCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.refreshStatusItem(waitingCount: count)
            }
            .store(in: &cancellables)
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Steer", action: #selector(quitSteer), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }

        statusItem = item
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
            statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
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

    @objc private func quitSteer() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class SteerStatus: ObservableObject {
    @Published var waitingCount: Int = 0
}
