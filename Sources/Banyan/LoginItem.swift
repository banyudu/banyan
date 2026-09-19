import Foundation
import ServiceManagement

/// Banyan's macOS login-item registration.
///
/// Reboot recovery only reaches the user if the app itself comes back, and
/// macOS "reopen windows when logging back in" does not cover that: it relaunches
/// what was *running* at shutdown, so a deliberate Cmd+Q before a restart means
/// nothing reopens Banyan and its stranded sessions stay stranded. A login item
/// closes that gap.
enum LoginItem {
    enum RegistrationError: LocalizedError {
        case requiresApproval
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .requiresApproval:
                return "macOS is holding this until you allow Banyan under System Settings › General › Login Items."
            case .failed(let message):
                return message
            }
        }
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// What the Preferences toggle shows. `requiresApproval` means the
    /// registration exists and is waiting on the user, not that it failed, so
    /// the switch stays on and the diagnostic under it explains the rest.
    static var isRequested: Bool {
        status == .enabled || status == .requiresApproval
    }

    /// Registered, but macOS wants the user to confirm it in System Settings
    /// before honoring it. Common the first time, and after the user has ever
    /// switched Banyan off there by hand.
    static var needsSystemSettingsApproval: Bool {
        status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        do {
            if enabled {
                switch service.status {
                case .enabled:
                    return
                case .requiresApproval:
                    throw RegistrationError.requiresApproval
                default:
                    try service.register()
                }
            } else {
                guard service.status != .notRegistered else { return }
                try service.unregister()
            }
        } catch let error as RegistrationError {
            throw error
        } catch {
            throw RegistrationError.failed(error.localizedDescription)
        }
        // `register()` succeeds without enabling anything when the user has
        // previously switched Banyan off in System Settings.
        if enabled, service.status == .requiresApproval {
            throw RegistrationError.requiresApproval
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The bundle macOS would launch. Banyan ships two channels that share a
    /// bundle id (`dist/Banyan.app` and `/Applications/Banyan.app`), and the
    /// registration follows whichever one registered it — worth showing rather
    /// than leaving the user to guess which build logs in.
    static var registeredBundlePath: String {
        Bundle.main.bundleURL.path
    }
}
