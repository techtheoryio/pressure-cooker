import Foundation
import Sparkle

/// Bare SwiftPM builds have no Info.plist, so updates, the login item and notifications only work inside the bundled .app.
@MainActor let isBundled = Bundle.main.bundleIdentifier != nil

/// Sparkle reads `appcast.xml` from the latest GitHub release (SUFeedURL in the Info.plist written by build-app.sh).
/// It refuses to start without the EdDSA public key, so local builds without one simply skip updates.
@MainActor let canUpdate = !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty

@MainActor let updater = SPUStandardUpdaterController(
    startingUpdater: canUpdate, updaterDelegate: updaterDelegate, userDriverDelegate: nil)

@MainActor private let updaterDelegate = UpdaterDelegate()  // Sparkle holds its delegate weakly

/// Pressure Cooker never quits on its own, so Sparkle's default of installing a downloaded update on quit would never happen.
/// Install and relaunch right away instead; there is nothing to save.
@MainActor final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        immediateInstallHandler()
        return true
    }
}
