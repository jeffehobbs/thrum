import SwiftUI
import Sparkle

/// Checks github.com/jeffehobbs/thrum for new releases and offers to install them.
///
/// Thrum is distributed outside the App Store with a Developer ID, which means
/// nothing tells anyone a new version exists — every copy in the field stays on
/// whatever version it was downloaded as, forever. Sparkle is the standard fix,
/// and it verifies an update twice over before running it: an Ed25519 signature
/// on the archive, made with a private key that never leaves the login keychain,
/// *and* a check that the new bundle's Developer ID matches the running one. Both
/// have to pass, so a compromised appcast alone cannot install anything.
///
/// Worth knowing about the rollout: this only helps versions that already have
/// it. Everyone on 1.3.2 or earlier has no updater to tell them 1.4.0 exists and
/// has to come and get it once by hand. 1.4.0 onward is the automatic part.
@MainActor
final class UpdateController: ObservableObject {
    /// False while a check is already in flight, so the menu item can dim rather
    /// than queue up three checks because nothing appeared to happen.
    @Published private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController

    init() {
        // `startingUpdater: true` starts the scheduled background checks. The
        // first run asks permission before it ever phones home; declining is
        // remembered, and "Check for Updates…" keeps working by hand.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                 updaterDelegate: nil,
                                                 userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// The menu item. Sits under the app menu next to About, where every other Mac
/// app keeps it.
struct UpdateCommands: Commands {
    @ObservedObject var updates: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updates.checkForUpdates() }
                .disabled(!updates.canCheck)
        }
    }
}
