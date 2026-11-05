import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    /// Watches the launch-config sources so agent-list edits apply without a
    /// restart. The picker, project "+" menu, and palette agent profiles all
    /// read `sessionLaunchProfiles`, so republishing it updates every consumer.
    func installLaunchConfigWatcher() {
        guard launchConfigWatcher == nil else { return }
        let home = host.homeDirectory
        let watcher = LaunchConfigWatcher(
            homeDirectory: home,
            watchedFiles: [
                SessionLaunchProfileLoader.configURL(homeDirectory: home),
                PaletteCommandLoader.paletteURL(homeDirectory: home),
                SessionLaunchProfileLoader.agentsURL(homeDirectory: home),
            ]
        ) { [weak self] in
            self?.reloadLaunchConfiguration()
        }
        watcher.start()
        launchConfigWatcher = watcher
    }

    /// Re-reads shortcuts, launches and palette commands after a file-system event.
    /// Equality-checked so a no-op save does not churn SwiftUI; a dropped
    /// palette pick (removed agent) falls back to Auto via the existing coerce.
    func reloadLaunchConfiguration() {
        let home = host.homeDirectory
        let shortcutConfiguration = SessionShortcutConfiguration.load(homeDirectory: home)
        if shortcutConfiguration.configuration != sessionShortcutConfiguration {
            sessionShortcutConfiguration = shortcutConfiguration.configuration
        }
        if shortcutConfiguration.diagnostic != sessionShortcutConfigurationDiagnostic {
            sessionShortcutConfigurationDiagnostic = shortcutConfiguration.diagnostic
        }
        let launchConfiguration = SessionLaunchProfileLoader.load(homeDirectory: home)
        if launchConfiguration.profiles != sessionLaunchProfiles {
            sessionLaunchProfiles = launchConfiguration.profiles
        }
        if launchConfiguration.diagnostic != sessionLaunchConfigurationDiagnostic {
            sessionLaunchConfigurationDiagnostic = launchConfiguration.diagnostic
        }
        coercePaletteAgentProfile()
        let paletteConfiguration = PaletteCommandLoader.load(homeDirectory: home)
        if paletteConfiguration.commands != paletteCommands {
            paletteCommands = paletteConfiguration.commands
        }
        if paletteConfiguration.diagnostic != paletteConfigurationDiagnostic {
            paletteConfigurationDiagnostic = paletteConfiguration.diagnostic
        }
    }

    /// Installs, retimes, or tears down the branch-refresh timer for how visible the
    /// app currently is. Tearing it down while hidden removes the wakeup itself, not
    /// just the git work it would have done.
    func rescheduleBranchRefreshTimer() {
        guard let interval = SessionBackgroundRefreshPolicy.branchRefreshInterval(
            activityLevel: supervisorActivityLevel
        ) else {
            branchRefreshTimer?.invalidate()
            branchRefreshTimer = nil
            currentBranchRefreshInterval = 0
            return
        }
        if branchRefreshTimer != nil, abs(interval - currentBranchRefreshInterval) < 0.01 {
            return
        }
        branchRefreshTimer?.invalidate()
        currentBranchRefreshInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBranchContextsIfNeeded()
                self?.refreshSelectedContextInfoIfStale()
            }
        }
        // Let macOS coalesce these wakeups with other timers to cut energy use.
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        branchRefreshTimer = timer
    }
}
