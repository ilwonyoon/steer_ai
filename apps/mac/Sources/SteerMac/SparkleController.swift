import AppKit
import Sparkle

/// Thin wrapper around Sparkle's SPUStandardUpdaterController so the rest of
/// the app talks to a single object regardless of whether Sparkle is enabled
/// at build time.
///
/// Enablement is keyed off `SparkleEnabled` in Info.plist. Local dogfood
/// builds can leave it `NO` to skip the update check entirely; release
/// builds set it `YES` and ship `SUFeedURL` + `SUPublicEDKey` alongside.
@MainActor
final class SparkleController: NSObject {
    static let shared = SparkleController()

    private let isEnabled: Bool
    private var controller: SPUStandardUpdaterController?

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let enabled = (info["SparkleEnabled"] as? String)?.uppercased() == "YES"
        self.isEnabled = enabled
        super.init()
    }

    func start() {
        guard isEnabled else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "Updates are disabled in this build"
            alert.informativeText = "Run a release build with SparkleEnabled=YES to receive updates."
            alert.runModal()
            return
        }
        controller.checkForUpdates(sender)
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }
}
