import XCTest
@testable import Uncommit

/// The test bundle runs inside Uncommit.app, so `UserDefaults.standard` here is
/// the installed app's real configuration. These tests exist because a test that
/// saved a view model destroyed a user's 79-repository list — twice.
@MainActor
final class PersistenceIsolationTests: XCTestCase {

    private let realKey = "uncommit.appConfiguration"

    /// Saving through an isolated view model must leave the real domain alone.
    func testSavingAnIsolatedViewModelDoesNotTouchTheRealDefaults() {
        let sentinel = Data("do-not-overwrite".utf8)
        let real = UserDefaults.standard
        let previous = real.data(forKey: realKey)
        real.set(sentinel, forKey: realKey)
        defer {
            if let previous { real.set(previous, forKey: realKey) }
            else { real.removeObject(forKey: realKey) }
        }

        let vm = makeIsolatedViewModel()
        vm.repositories = [
            GitRepository(id: UUID(), path: "/tmp/x", displayName: "x")
        ]
        vm.saveConfiguration()

        // This is the assertion that would have caught the data loss.
        XCTAssertEqual(real.data(forKey: realKey), sentinel)
    }

    /// The migration path specifically — it is what did the damage, because it
    /// saves as a side effect.
    func testMigrationDoesNotTouchTheRealDefaults() {
        let sentinel = Data("do-not-overwrite".utf8)
        let real = UserDefaults.standard
        let previous = real.data(forKey: realKey)
        real.set(sentinel, forKey: realKey)
        defer {
            if let previous { real.set(previous, forKey: realKey) }
            else { real.removeObject(forKey: realKey) }
        }

        let vm = makeIsolatedViewModel()
        var old = AppConfiguration()
        old.configVersion = 0
        vm.configuration = old
        vm.migrateIfNeeded()

        XCTAssertEqual(real.data(forKey: realKey), sentinel)
    }

    func testIsolatedViewModelsDoNotShareStorage() {
        let a = makeIsolatedViewModel()
        let b = makeIsolatedViewModel()
        a.repositories = [GitRepository(id: UUID(), path: "/tmp/a", displayName: "a")]
        a.saveConfiguration()

        XCTAssertTrue(b.configuration.repositories.isEmpty)
    }

    // MARK: - Recoverability

    /// An overwrite keeps the outgoing value one generation back, so a bad
    /// write is recoverable rather than final.
    func testSaveKeepsThePreviousConfiguration() {
        let suite = UserDefaults(suiteName: "com.uncommit.tests.\(UUID().uuidString)")!
        let service = PersistenceService(defaults: suite)

        var good = AppConfiguration()
        good.repositories = [GitRepository(id: UUID(), path: "/tmp/keep", displayName: "keep")]
        service.save(good)
        service.save(AppConfiguration())   // the destructive write

        XCTAssertTrue(service.load().repositories.isEmpty)
        XCTAssertEqual(service.loadPrevious()?.repositories.map(\.displayName), ["keep"])
    }

    func testFirstSaveHasNoPrevious() {
        let suite = UserDefaults(suiteName: "com.uncommit.tests.\(UUID().uuidString)")!
        let service = PersistenceService(defaults: suite)
        service.save(AppConfiguration())
        XCTAssertNil(service.loadPrevious())
    }
}
