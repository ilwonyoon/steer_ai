import AppKit
import Foundation

/// Polls NSPasteboard.general for newly arrived image data and reports it.
///
/// We do this instead of intercepting Cmd+V because SwiftUI's onPasteCommand
/// and NSEvent local monitors both fail to fire reliably while the underlying
/// TextField is the first responder. The Backtick app uses the same trick.
@MainActor
final class ClipboardImageMonitor: ObservableObject {
    /// Newly detected attachments are appended here. Drive your UI off
    /// `.onChange(of: detected)` or `objectWillChange` rather than a
    /// closure callback — closures captured in `.onAppear` get stale
    /// binding references on view rebuilds.
    @Published var detected: [ReplyAttachment] = []

    private var lastChangeCount: Int
    private var timer: Timer?
    private let pollInterval: TimeInterval
    private var requestedActive = false
    private var becomeActiveObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?

    init(pollInterval: TimeInterval = 0.4) {
        self.pollInterval = pollInterval
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard !requestedActive else { return }
        requestedActive = true
        installAppActivationObserversIfNeeded()
        // Reset the baseline so anything already on the pasteboard before the
        // user opened Steer doesn't immediately attach itself.
        lastChangeCount = NSPasteboard.general.changeCount
        if NSApp?.isActive == true {
            startTimerLoop()
        }
    }

    func stop() {
        requestedActive = false
        stopTimerLoop()
        if let observer = becomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            becomeActiveObserver = nil
        }
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            resignActiveObserver = nil
        }
    }

    private func startTimerLoop() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.poll()
            }
        }
    }

    private func stopTimerLoop() {
        timer?.invalidate()
        timer = nil
    }

    /// Foreground-only polling. We registered `start()` once but only run
    /// the timer while Steer is the frontmost app; otherwise a paste in
    /// some unrelated tool would silently attach itself the next time the
    /// user came back to Steer.
    private func installAppActivationObserversIfNeeded() {
        guard becomeActiveObserver == nil else { return }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.requestedActive else { return }
                // Reset baseline so anything pasted while Steer was in the
                // background doesn't ride in on the next foreground tick.
                self.lastChangeCount = NSPasteboard.general.changeCount
                self.startTimerLoop()
            }
        }
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopTimerLoop()
            }
        }
    }

    /// Force a check (used right after the user gives Steer focus, so a paste
    /// they made off-window still gets picked up immediately).
    func refreshNow() {
        poll()
    }

    private func poll() {
        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        var newlyFound: [ReplyAttachment] = []

        // File URL paste/copy from Finder: surface as-is.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls where ClipboardImageMonitor.isImageURL(url) {
                newlyFound.append(ReplyAttachment(
                    id: UUID(),
                    url: url,
                    displayName: url.lastPathComponent,
                    isManaged: false
                ))
            }
        }

        // Raw image data: PNG and TIFF often coexist on the same pasteboard;
        // we only materialize one to avoid duplicate temp files.
        if newlyFound.isEmpty {
            if let pngData = pb.data(forType: .png), !pngData.isEmpty {
                if let attachment = AttachmentService.writeImageData(pngData, pathExtension: "png") {
                    newlyFound.append(attachment)
                }
            } else if let tiffData = pb.data(forType: .tiff), !tiffData.isEmpty {
                if let attachment = AttachmentService.writeImageData(tiffData, pathExtension: "tiff") {
                    newlyFound.append(attachment)
                }
            }
        }

        if !newlyFound.isEmpty {
            detected.append(contentsOf: newlyFound)
        }
    }

    /// ReplyDock calls this after consuming the buffered `detected` array so
    /// the same attachments aren't re-applied across SwiftUI view rebuilds.
    func clearDetected() {
        detected.removeAll()
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "webp", "bmp"].contains(ext)
    }
}
