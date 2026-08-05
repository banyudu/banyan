import Foundation
import Testing
@testable import Banyan

/// `LinearIssueClient.cleanCommandOutput` is a duplicate of the one in
/// `SessionContextResolver` and carried the same broken raw-string ANSI pattern. This
/// is the copy that actually crashed: `refreshSelectedLinearListIssue` runs on a
/// 20-second timer, so the trap in the regex's one-time initializer was reached
/// reliably rather than occasionally.
private let esc = "\u{001B}"

@Test func linearClientAnsiPatternCompiles() {
    #expect(LinearIssueClient.ansiEscapeRegex.numberOfCaptureGroups == 0)
}

@Test func linearClientStripsAnsiFromCommandOutput() {
    let coloured = "\(esc)[1;34mENG-8838\(esc)[0m  Fix the hang"
    let cleaned = LinearIssueClient.cleanCommandOutput(coloured)
    #expect(cleaned == "ENG-8838  Fix the hang")
    #expect(!cleaned.contains(esc))
}

@Test func linearClientLeavesJSONPayloadIntact() {
    // Command output is parsed as JSON downstream, so stripping must not disturb it.
    let payload = #"{"identifier":"ENG-1","title":"a [b] c 0-9"}"#
    #expect(LinearIssueClient.cleanCommandOutput(payload) == payload)
}
