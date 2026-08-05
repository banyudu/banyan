import Foundation
import Testing
@testable import BanyanCore

/// `SessionStore.sidebarHistoryItems` renders only the top `sidebarBrowseLimit`
/// sessions by `updatedAt` when there is no query, instead of rendering every
/// candidate and letting `sidebarEntries` truncate afterwards. That shortcut is only
/// valid while the invariants below hold — if `sidebarEntries` ever gains a secondary
/// sort key or a browse-time filter, these fail and the store must be revisited.

private func candidate(_ index: Int, minutesAgo: Int) -> SessionHistorySidebarCandidate {
    SessionHistorySidebarCandidate(
        id: "s\(index)",
        projectName: "proj",
        displayTitle: "ENG-\(1000 + index) title \(index)",
        issueID: "ENG-\(1000 + index)",
        updatedAt: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo * 60))
    )
}

@Test func browseWindowIsDecidedOnlyByRecency() {
    let all = (0..<200).map { candidate($0, minutesAgo: $0) }
    let entries = SessionHistoryPresentation.sidebarEntries(from: all, query: "")

    #expect(entries.count == SessionHistoryPresentation.sidebarBrowseLimit)
    // Most recent first, and exactly the newest N — nothing about the rendered title
    // influences which rows survive.
    #expect(entries.map(\.id) == (0..<SessionHistoryPresentation.sidebarBrowseLimit).map { "s\($0)" })
}

@Test func preTruncatingByRecencyMatchesRenderingEverything() {
    let all = (0..<200).map { candidate($0, minutesAgo: $0) }

    let renderEverything = SessionHistoryPresentation.sidebarEntries(from: all, query: "")

    // What the store now does: take the window first, render only those.
    let preTruncated = SessionHistoryPresentation.sidebarEntries(
        from: Array(
            all.sorted { $0.updatedAt > $1.updatedAt }
                .prefix(SessionHistoryPresentation.sidebarBrowseLimit)
        ),
        query: ""
    )

    #expect(preTruncated == renderEverything)
}

@Test func preTruncatingIsUnsafeOnceAQueryIsPresent() {
    // A match that sits outside the browse window by recency must still be findable,
    // which is why the store keeps the query path exhaustive.
    var all = (0..<200).map { candidate($0, minutesAgo: $0) }
    all[150] = SessionHistorySidebarCandidate(
        id: "needle",
        projectName: "proj",
        displayTitle: "distinctive-needle-title",
        issueID: nil,
        updatedAt: Date(timeIntervalSince1970: 1_000_000 - Double(150 * 60))
    )

    let exhaustive = SessionHistoryPresentation.sidebarEntries(from: all, query: "needle")
    #expect(exhaustive.contains { $0.id == "needle" })

    let preTruncated = SessionHistoryPresentation.sidebarEntries(
        from: Array(
            all.sorted { $0.updatedAt > $1.updatedAt }
                .prefix(SessionHistoryPresentation.sidebarBrowseLimit)
        ),
        query: "needle"
    )
    #expect(!preTruncated.contains { $0.id == "needle" })
}

@Test func historyFilterSkipsIssueLinkLookupForRejectedSessions() {
    // `hasIssueLink` is an autoclosure so it is not evaluated for sessions the cheap
    // guards already reject — the sidebar walks every session, most of which are not
    // history rows at all.
    var evaluated = 0
    let result = SessionHistoryPolicy.isLocalHistorySession(
        status: .executing,
        isImportedHistory: false,
        provider: .claude,
        hasIssueLink: { evaluated += 1; return true }()
    )

    #expect(result == false)
    #expect(evaluated == 0)
}

@Test func historyFilterStillConsultsIssueLinkWhenGuardsPass() {
    var evaluated = 0
    let result = SessionHistoryPolicy.isLocalHistorySession(
        status: .closed,
        isImportedHistory: false,
        provider: .claude,
        hasIssueLink: { evaluated += 1; return true }()
    )

    #expect(result == true)
    #expect(evaluated == 1)
}
