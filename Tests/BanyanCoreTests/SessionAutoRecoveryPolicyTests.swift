import Foundation
import Testing
@testable import BanyanCore

@Test func autoRecoveryTakesStrandedSessionsWithReadableProjectFolders() {
    #expect(SessionAutoRecoveryPolicy.canAutoRecover(
        needsRecovery: true,
        isImportedHistory: false,
        isSuspended: false,
        hasProjectFolderAccess: true
    ))
    #expect(!SessionAutoRecoveryPolicy.canAutoRecover(
        needsRecovery: false,
        isImportedHistory: false,
        isSuspended: false,
        hasProjectFolderAccess: true
    ))
}

@Test func autoRecoveryNeverRaisesAFolderPrompt() {
    // The launch pass runs while the window is still restoring, so a session
    // whose folder would need a macOS grant stays behind for the banner.
    #expect(!SessionAutoRecoveryPolicy.canAutoRecover(
        needsRecovery: true,
        isImportedHistory: false,
        isSuspended: false,
        hasProjectFolderAccess: false
    ))
}

@Test func autoRecoveryLeavesParkedAndImportedSessionsAlone() {
    // Parking is a deliberate "spend nothing on this"; a reboot is not the user
    // taking that back.
    #expect(!SessionAutoRecoveryPolicy.canAutoRecover(
        needsRecovery: true,
        isImportedHistory: false,
        isSuspended: true,
        hasProjectFolderAccess: true
    ))
    #expect(!SessionAutoRecoveryPolicy.canAutoRecover(
        needsRecovery: true,
        isImportedHistory: true,
        isSuspended: false,
        hasProjectFolderAccess: true
    ))
}

@Test func autoRecoveryBatchesSessionsInsteadOfForkingThemAllAtOnce() {
    #expect(SessionAutoRecoveryPolicy.batches([1, 2, 3, 4, 5], size: 2) == [[1, 2], [3, 4], [5]])
    #expect(SessionAutoRecoveryPolicy.batches([1, 2], size: 4) == [[1, 2]])
    #expect(SessionAutoRecoveryPolicy.batches([Int](), size: 4).isEmpty)
    // A nonsensical size must still start every session exactly once.
    #expect(SessionAutoRecoveryPolicy.batches([1, 2, 3], size: 0) == [[1, 2, 3]])
}

@Test func autoRecoveryBatchDefaultsStayBounded() {
    #expect(SessionAutoRecoveryPolicy.batchSize > 0)
    #expect(SessionAutoRecoveryPolicy.batchInterval > 0)
    let stranded = Array(1...29)
    let batches = SessionAutoRecoveryPolicy.batches(stranded)
    #expect(batches.flatMap { $0 } == stranded)
    #expect(batches.allSatisfy { $0.count <= SessionAutoRecoveryPolicy.batchSize })
}
