import Foundation
import Testing
@testable import Banyan

@Test func missingProjectFolderIsReportedSeparatelyFromPermissionDenial() {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .path

    #expect(ProjectFolderAccess.evaluate(for: path) == .missingFolder)
}
