import AppKit

@MainActor
final class SteerAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Steer"
        item.button?.toolTip = "Open Steer"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Steer", action: #selector(openSteer), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Steer", action: #selector(quitSteer), keyEquivalent: "q"))

        for menuItem in menu.items {
            menuItem.target = self
        }

        item.menu = menu
        statusItem = item
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
