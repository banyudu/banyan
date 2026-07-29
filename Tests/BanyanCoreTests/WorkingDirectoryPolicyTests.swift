import Foundation
import Testing
@testable import BanyanCore

@Test func workingDirectoryPolicyUsesExistingProposedDirectory() {
    #expect(WorkingDirectoryPolicy.resolve(
        proposedDirectory: "/tmp",
        currentDirectory: "/does/not/exist",
        homeDirectory: "/var"
    ) == "/tmp")
}

@Test func workingDirectoryPolicyUsesCurrentDirectoryWhenProposalIsMissing() {
    #expect(WorkingDirectoryPolicy.resolve(
        proposedDirectory: nil,
        currentDirectory: "/tmp",
        homeDirectory: "/var"
    ) == "/tmp")
    #expect(WorkingDirectoryPolicy.resolve(
        proposedDirectory: "",
        currentDirectory: "/tmp",
        homeDirectory: "/var"
    ) == "/tmp")
}

@Test func workingDirectoryPolicyFallsBackToCanonicalHomeForInvalidDirectory() {
    #expect(WorkingDirectoryPolicy.resolve(
        proposedDirectory: "/does/not/exist",
        currentDirectory: "/also/does/not/exist",
        homeDirectory: "/tmp/../tmp"
    ) == "/tmp")
}
