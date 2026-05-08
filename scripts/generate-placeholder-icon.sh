#!/usr/bin/env bash
# Generate a temporary 1024x1024 placeholder icon so the build doesn't fail
# before a real icon is delivered. Replace apps/mac/Resources/AppIcon-master.png
# with the final art before any release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/apps/mac/Resources/AppIcon-master.png"
mkdir -p "$(dirname "$OUT")"

cat > /tmp/steer-icon-placeholder.swift <<'SWIFT'
import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)

let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.32, blue: 0.78, alpha: 1.0),
    NSColor(calibratedRed: 0.04, green: 0.18, blue: 0.52, alpha: 1.0)
])
let path = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
bg?.draw(in: path, angle: 270)

let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 640, weight: .heavy),
    .foregroundColor: NSColor.white
]
let text = "S" as NSString
let textSize = text.size(withAttributes: attrs)
let textOrigin = NSPoint(
    x: rect.midX - textSize.width / 2,
    y: rect.midY - textSize.height / 2 - 40
)
text.draw(at: textOrigin, withAttributes: attrs)
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write("failed to render placeholder icon\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: 1024, height: 1024)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode placeholder icon\n".data(using: .utf8)!)
    exit(1)
}

let outPath = CommandLine.arguments[1]
do {
    try png.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
SWIFT

swift /tmp/steer-icon-placeholder.swift "$OUT"
rm /tmp/steer-icon-placeholder.swift

sips -z 1024 1024 "$OUT" --out "$OUT" >/dev/null

echo "$OUT"
