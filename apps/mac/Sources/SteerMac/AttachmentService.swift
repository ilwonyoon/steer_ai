import Foundation
import AppKit
import UniformTypeIdentifiers

struct ReplyAttachment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let displayName: String
    let isManaged: Bool   // true = Steer wrote a temp PNG and owns its lifecycle

    static func == (lhs: ReplyAttachment, rhs: ReplyAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

enum AttachmentSource {
    case pasteboard(NSPasteboard)
    case providers([NSItemProvider])
}

enum AttachmentService {
    private static let tempPrefix = "steer-paste"

    /// Inspect a paste / drop and return any image attachments. fileURL items
    /// are surfaced as-is; raw image data is materialized into a temp PNG so
    /// the wrapper has a path to hand off to codex / claude.
    static func attachments(from pasteboard: NSPasteboard) -> [ReplyAttachment] {
        var result: [ReplyAttachment] = []

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            for url in urls where isProbablyImage(url: url) {
                result.append(ReplyAttachment(
                    id: UUID(),
                    url: url,
                    displayName: url.lastPathComponent,
                    isManaged: false
                ))
            }
        }

        if !result.isEmpty { return result }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            for image in images {
                if let written = writeImage(image) {
                    result.append(written)
                }
            }
        }

        return result
    }

    /// Drag-and-drop variant. NSItemProviders may carry either fileURLs or
    /// image data; we honor whichever ships first.
    @MainActor
    static func attachments(from providers: [NSItemProvider]) async -> [ReplyAttachment] {
        var result: [ReplyAttachment] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider), isProbablyImage(url: url) {
                result.append(ReplyAttachment(
                    id: UUID(),
                    url: url,
                    displayName: url.lastPathComponent,
                    isManaged: false
                ))
                continue
            }
            if let image = await loadImage(from: provider), let written = writeImage(image) {
                result.append(written)
            }
        }
        return result
    }

    /// Called when the user removes an attachment row or clears the dock.
    /// Removes only Steer-managed temp files; leaves user-supplied originals
    /// alone.
    static func discard(_ attachment: ReplyAttachment) {
        guard attachment.isManaged else { return }
        try? FileManager.default.removeItem(at: attachment.url)
    }

    /// Called at app launch to clear any orphaned steer-paste-* files older
    /// than the cutoff (defaults to 60 minutes — long enough that an in-flight
    /// model read won't 404, short enough that we don't accumulate forever).
    static func cleanupStaleTempFiles(olderThan minutes: Double = 60) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("\(tempPrefix)-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Private

    private static func writeImage(_ image: NSImage) -> ReplyAttachment? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        let id = UUID()
        let timestamp = Int(Date().timeIntervalSince1970)
        let suffix = id.uuidString.split(separator: "-").first.map(String.init) ?? "img"
        let filename = "\(tempPrefix)-\(timestamp)-\(suffix).png"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        do {
            try png.write(to: url, options: .atomic)
            return ReplyAttachment(
                id: id,
                url: url,
                displayName: filename,
                isManaged: true
            )
        } catch {
            return nil
        }
    }

    private static func isProbablyImage(url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    @MainActor
    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    private static func loadImage(from provider: NSItemProvider) async -> NSImage? {
        for identifier in [UTType.png.identifier, UTType.tiff.identifier, UTType.image.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            if let image: NSImage = await withCheckedContinuation({ continuation in
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                    guard let data, let image = NSImage(data: data) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: image)
                }
            }) {
                return image
            }
        }
        return nil
    }
}
