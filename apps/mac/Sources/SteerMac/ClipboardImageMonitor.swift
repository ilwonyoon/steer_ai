import AppKit
import Foundation

/// Polls NSPasteboard.general for newly arrived image data and reports it.
///
/// We do this instead of intercepting Cmd+V because SwiftUI's onPasteCommand
/// and NSEvent local monitors both fail to fire reliably while the underlying
/// TextField is the first responder. The Backtick app uses the same trick.
@MainActor
final class ClipboardImageMonitor: ObservableObject {
    var onImageDetected: ((ReplyAttachment) -> Void)?

    private var lastChangeCount: Int
    private var timer: Timer?
    private let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 0.4) {
        self.pollInterval = pollInterval
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        // Reset the baseline so anything already on the pasteboard before the
        // user opened Steer doesn't immediately attach itself.
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
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

        // File URL paste/copy from Finder: surface as-is.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls where ClipboardImageMonitor.isImageURL(url) {
                onImageDetected?(ReplyAttachment(
                    id: UUID(),
                    url: url,
                    displayName: url.lastPathComponent,
                    isManaged: false
                ))
            }
        }

        // Raw image data (cmd+option+shift+4 puts PNG/TIFF directly on the
        // clipboard). Materialize once into a temp file the wrapper can hand
        // to the model.
        if let pngData = pb.data(forType: .png), !pngData.isEmpty {
            if let attachment = AttachmentService.writeImageData(pngData, pathExtension: "png") {
                onImageDetected?(attachment)
            }
        } else if let tiffData = pb.data(forType: .tiff), !tiffData.isEmpty {
            if let attachment = AttachmentService.writeImageData(tiffData, pathExtension: "tiff") {
                onImageDetected?(attachment)
            }
        }
    }

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "webp", "bmp"].contains(ext)
    }
}
