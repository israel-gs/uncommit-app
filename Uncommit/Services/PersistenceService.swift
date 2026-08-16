import Foundation

final class PersistenceService: Sendable {
    private let configKey = "uncommit.appConfiguration"
    /// Previous value, kept so a bad write is recoverable instead of final.
    private let backupKey = "uncommit.appConfiguration.previous"

    /// Injectable so tests never reach the real domain. The test bundle is
    /// hosted by the app itself, which makes `UserDefaults.standard` inside a
    /// test THE INSTALLED APP'S CONFIGURATION — a test that saved a view model
    /// silently destroyed the user's repository list.
    ///
    /// `nonisolated(unsafe)` because `UserDefaults` is documented as thread-safe
    /// but predates `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppConfiguration {
        guard let data = defaults.data(forKey: configKey),
              let config = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return AppConfiguration()
        }
        return config
    }

    func save(_ config: AppConfiguration) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        // Keep the outgoing value one generation back. Losing a repository list
        // is unrecoverable otherwise: there is no other copy anywhere.
        if let current = defaults.data(forKey: configKey), current != data {
            defaults.set(current, forKey: backupKey)
        }
        defaults.set(data, forKey: configKey)
    }

    /// The configuration as it was before the most recent save, if any.
    func loadPrevious() -> AppConfiguration? {
        guard let data = defaults.data(forKey: backupKey) else { return nil }
        return try? JSONDecoder().decode(AppConfiguration.self, from: data)
    }
}
