import Combine
import Sparkle

/// Looks for a newer release in the feed at rulebook.duxi.ao and installs it, through Sparkle.
/// The feed address and the key that releases are signed with are in Info.plist.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// False while a check is already running.
    @Published private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isReleaseCopy, updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    /// A build run from Xcode, or one started with a stand-in folder for a demo, shouldn't replace itself.
    private static var isReleaseCopy: Bool {
        #if DEBUG
        return false
        #else
        return LaunchOptions.root == nil && LaunchOptions.storeDir == nil
        #endif
    }

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func check() { controller.checkForUpdates(nil) }
}
