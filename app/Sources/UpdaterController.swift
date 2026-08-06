import Sparkle
import SwiftUI

/// Sparkle auto-update: single shared updater, started at app launch.
enum Updater {
    static let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                        updaterDelegate: nil,
                                                        userDriverDelegate: nil)
}

struct CheckForUpdatesCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Rechercher les mises à jour…") {
                Updater.controller.checkForUpdates(nil)
            }
        }
    }
}
