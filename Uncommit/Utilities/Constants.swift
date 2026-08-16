import Foundation

enum AppConstants {
    static let defaultRefreshInterval: TimeInterval = 30
    /// 15 minutes. Remote checks cost a network round trip per repo, so this is
    /// the "background awareness" cadence — the Fetch All button covers "tell me
    /// right now". At 40 repos this is ~160 fetches/hour instead of the ~480 a
    /// 5-minute cadence would cost.
    static let defaultRemoteCheckInterval: TimeInterval = 900
    static let defaultMaxDiscoveryDepth = 3
    static let appName = "Uncommit"
}
