import Testing
@testable import BanyanCore

@Suite struct SessionReparentingPolicyTests {
    private let items: [SessionRelationshipItem] = [
        .init(id: "root", parentSessionID: nil, status: .idle),
        .init(id: "source", parentSessionID: "root", status: .idle),
        .init(id: "child", parentSessionID: "source", status: .idle),
        .init(id: "leaf", parentSessionID: "child", status: .idle),
        .init(id: "target", parentSessionID: nil, status: .completed, isSuspended: true),
        .init(id: "closed", parentSessionID: nil, status: .closed),
        .init(id: "history", parentSessionID: nil, status: .idle, isImportedHistory: true),
        .init(id: "foreign", parentSessionID: nil, status: .idle, projectGroupID: "other")
    ]

    @Test func acceptsActiveTargetsAndNormalizesRootMoves() throws {
        #expect(try SessionRelationshipPolicy.validatedParentID(for: "source", proposedParentID: " target ", in: items) == "target")
        #expect(try SessionRelationshipPolicy.validatedParentID(for: "source", proposedParentID: "root", in: items) == "root")
        #expect(SessionRelationshipPolicy.validParentIDs(for: "source", in: items) == ["root", "target"])
        #expect(SessionRelationshipPolicy.validParentIDs(for: "closed", in: items).isEmpty)
        for root in [nil, "", " \n "] as [String?] {
            #expect(try SessionRelationshipPolicy.validatedParentID(for: "source", proposedParentID: root, in: items) == nil)
        }
    }

    @Test func rejectsInvalidSourcesParentsAndDescendants() {
        let moves: [(String, String?, SessionReparentingError)] = [
            ("missing", nil, .sourceNotFound("missing")),
            ("closed", nil, .inactiveSource("closed")),
            ("history", "root", .inactiveSource("history")),
            ("source", "source", .selfParent),
            ("source", "child", .cycle),
            ("source", "leaf", .cycle),
            ("source", "missing", .parentNotFound("missing")),
            ("source", "closed", .inactiveParent("closed")),
            ("source", "history", .inactiveParent("history")),
            ("source", "foreign", .differentProjectGroup)
        ]
        for (source, parent, error) in moves {
            #expect(throws: error) {
                try SessionRelationshipPolicy.validatedParentID(for: source, proposedParentID: parent, in: items)
            }
        }
    }

    @Test func rejectsPreexistingCyclesAndTraversesClosedAncestors() {
        let malformed = items + [
            .init(id: "a", parentSessionID: "b", status: .idle),
            .init(id: "b", parentSessionID: "a", status: .idle),
            .init(id: "closed-link", parentSessionID: "source", status: .closed),
            .init(id: "descendant", parentSessionID: "closed-link", status: .idle)
        ]
        for parent in ["a", "descendant"] {
            #expect(throws: SessionReparentingError.cycle) {
                try SessionRelationshipPolicy.validatedParentID(for: "source", proposedParentID: parent, in: malformed)
            }
        }
    }
}
