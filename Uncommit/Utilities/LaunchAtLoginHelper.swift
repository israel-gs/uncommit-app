import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.uncommit.app", category: "LaunchAtLogin")

/// Manages whether Uncommit launches automatically when the user logs in,
/// using the modern `SMAppService` API (macOS 13+). This registers the main
/// app bundle itself as a login item — no separate helper executable needed.
enum LaunchAtLoginHelper {
    /// Whether the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item.
    /// - Returns: the resulting enabled state after the operation.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    logger.info("✅ Registered Uncommit as a login item")
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    logger.info("🛑 Unregistered Uncommit as a login item")
                }
            }
        } catch {
            logger.error("⚠️ Failed to update launch-at-login: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
