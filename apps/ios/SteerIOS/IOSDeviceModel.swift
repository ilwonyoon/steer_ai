import Foundation
import UIKit

/// Maps the raw `utsname.machine` identifier (e.g. "iPhone15,2") to
/// the marketing name Apple uses ("iPhone 14 Pro"). UIDevice doesn't
/// expose this directly; we need the user-readable name so the Mac
/// presence label says "iPhone 14 Pro" instead of just "iPhone".
///
/// Unknown identifiers fall back to the raw machine string so newer
/// hardware shows *something* meaningful in the meantime (the user
/// at least sees their phone's identifier instead of "iPhone").
enum IOSDeviceModel {
    static func marketingName() -> String {
        let identifier = machineIdentifier()
        if let mapped = map[identifier] {
            return mapped
        }
        // Simulator: $SIMULATOR_MODEL_IDENTIFIER carries the modeled
        // device id. Useful for dogfood on Xcode, less useful in
        // production but harmless.
        if identifier == "i386" || identifier == "x86_64" || identifier == "arm64" {
            if let env = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
               let mapped = map[env] {
                return mapped
            }
        }
        return identifier.isEmpty ? "iPhone" : identifier
    }

    private static func machineIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let raw = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
        return raw.trimmingCharacters(in: .controlCharacters)
    }

    /// Identifier → marketing name. Covers iPhone 11 through current,
    /// plus a few iPads in case someone signs in on one. Apple keeps
    /// a more exhaustive list at theiphonewiki; we only need recent
    /// devices realistic for users today. Older devices that fall
    /// through hit the raw-identifier fallback and still get *some*
    /// label.
    private static let map: [String: String] = [
        // iPhone 11 family
        "iPhone12,1": "iPhone 11",
        "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        // iPhone 12 family
        "iPhone13,1": "iPhone 12 mini",
        "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        // iPhone 13 family
        "iPhone14,4": "iPhone 13 mini",
        "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        // iPhone 14 family
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        // iPhone 15 family
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        // iPhone 16 family
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        // iPad — a few common ones; comprehensive list isn't worth
        // the bytes when Steer is iPhone-first.
        "iPad14,3": "iPad Pro 11\" (M2)",
        "iPad14,4": "iPad Pro 11\" (M2)",
        "iPad14,5": "iPad Pro 12.9\" (M2)",
        "iPad14,6": "iPad Pro 12.9\" (M2)",
        "iPad14,8": "iPad Air (M2)",
        "iPad14,9": "iPad Air (M2)",
        "iPad14,10": "iPad Air 13\" (M2)",
        "iPad14,11": "iPad Air 13\" (M2)",
        "iPad16,1": "iPad mini (A17 Pro)",
        "iPad16,2": "iPad mini (A17 Pro)",
        "iPad16,3": "iPad Pro 11\" (M4)",
        "iPad16,4": "iPad Pro 11\" (M4)",
        "iPad16,5": "iPad Pro 13\" (M4)",
        "iPad16,6": "iPad Pro 13\" (M4)"
    ]
}
