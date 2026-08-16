import Foundation
@testable import Uncommit

/// Builds a view model that cannot touch the real configuration.
///
/// The test bundle is hosted by Uncommit.app (`TEST_HOST`), so a test running
/// `UserDefaults.standard` is reading and writing THE INSTALLED APP'S settings.
/// A test that saved a view model wiped the user's repository list for real —
/// that is not a hypothetical, it happened. Every test that builds an
/// AppViewModel must go through here.
@MainActor
func makeIsolatedViewModel() -> AppViewModel {
    let suite = UserDefaults(suiteName: "com.uncommit.tests.\(UUID().uuidString)")!
    return AppViewModel(persistence: PersistenceService(defaults: suite))
}
