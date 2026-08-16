import XCTest
@testable import Uncommit

final class AppConfigurationTests: XCTestCase {

    private func decode(_ json: String) throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
    }

    func testFreshConfigChecksRemotesAutomatically() {
        let config = AppConfiguration()
        XCTAssertTrue(config.autoCheckRemote)
        XCTAssertEqual(config.remoteCheckIntervalSeconds, AppConstants.defaultRemoteCheckInterval)
        XCTAssertEqual(config.configVersion, AppConfiguration.currentVersion)
    }

    /// A config written before versioning existed must decode as v0 so the
    /// migration runs — it is the only way to tell "the user turned this off"
    /// from "there was never a switch to turn on".
    func testConfigWithoutVersionDecodesAsNeedingMigration() throws {
        let config = try decode(#"{"autoCheckRemote":false,"refreshIntervalSeconds":30}"#)
        XCTAssertEqual(config.configVersion, 0)
        XCTAssertFalse(config.autoCheckRemote)
    }

    func testCurrentConfigIsNotMigratedAgain() throws {
        let config = try decode(#"{"autoCheckRemote":false,"configVersion":1}"#)
        XCTAssertEqual(config.configVersion, AppConfiguration.currentVersion)
        XCTAssertFalse(config.autoCheckRemote, "an explicit opt-out must survive")
    }

    /// The whole point of the hand-written decoder: an unknown-shaped config
    /// must never fail to decode, because `PersistenceService` uses `try?` and
    /// would silently reset the user's repositories.
    func testEmptyObjectDecodesToDefaults() throws {
        let config = try decode("{}")
        XCTAssertTrue(config.autoCheckRemote)
        XCTAssertEqual(config.refreshIntervalSeconds, AppConstants.defaultRefreshInterval)
        XCTAssertEqual(config.maxDiscoveryDepth, AppConstants.defaultMaxDiscoveryDepth)
        XCTAssertTrue(config.repositories.isEmpty)
        XCTAssertEqual(config.configVersion, 0)
    }

    func testRoundTripPreservesTheUsersChoice() throws {
        var config = AppConfiguration()
        config.autoCheckRemote = false
        config.remoteCheckIntervalSeconds = 1800

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: data)

        XCTAssertFalse(decoded.autoCheckRemote)
        XCTAssertEqual(decoded.remoteCheckIntervalSeconds, 1800)
        XCTAssertEqual(decoded.configVersion, AppConfiguration.currentVersion)
    }
}
