import Foundation

/// Cadence for the periodic refreshes that feed on-screen chrome only — the
/// sidebar's branch chip and the selected session's issue status.
///
/// These are deliberately separate from `SessionSupervisorCadencePolicy`.
/// A supervisor tick is what turns an unattached session's new state into a
/// notification, so slowing it trades energy against attention latency. These
/// refreshes drive nothing but pixels: no notification, no persisted decision,
/// no agent input. Once nothing is on screen they can stop outright, because the
/// moment a window comes back the caller forces a refresh before anyone can read
/// a stale value.
public enum SessionBackgroundRefreshPolicy {
    /// Frontmost: `git checkout` in an attached pane should move the chip about
    /// as fast as the user can look at it.
    public static let activeBranchRefreshInterval: TimeInterval = 15

    /// On screen but not frontmost: the chip is readable, but the user is working
    /// in another app and is not watching it change. Each cycle costs a handful of
    /// `git` invocations per distinct working directory, so a large workspace pays
    /// this many times over.
    public static let backgroundVisibleBranchRefreshInterval: TimeInterval = 60

    /// How often to re-derive branch context, or `nil` to suspend it entirely.
    public static func branchRefreshInterval(
        activityLevel: SupervisorActivityLevel
    ) -> TimeInterval? {
        switch activityLevel {
        case .active:
            return activeBranchRefreshInterval
        case .backgroundVisible:
            return backgroundVisibleBranchRefreshInterval
        case .hidden:
            return nil
        }
    }

    /// Whether a poll whose only product is on-screen chrome should run now.
    public static func refreshesOnScreenChrome(
        activityLevel: SupervisorActivityLevel
    ) -> Bool {
        activityLevel != .hidden
    }
}
