import Testing
@testable import BanyanCore

@Suite struct SessionBackgroundPolicyTests {
    @Test func descendantsInheritVisibilityAndRestoreTheirRootsWithoutLooping() {
        let parents = ["child": "root", "later-child": "child", "cycle-a": "cycle-b", "cycle-b": "cycle-a"]
        #expect(SessionBackgroundPolicy.hiddenIDs(roots: ["root"], parents: parents) == ["root", "child", "later-child"])
        #expect(SessionBackgroundPolicy.revealing("later-child", roots: ["root", "unrelated"], parents: parents) == ["unrelated"])
        #expect(SessionBackgroundPolicy.hiddenIDs(roots: ["cycle-a"], parents: parents) == ["cycle-a", "cycle-b"])
        #expect(SessionBackgroundPolicy.revealing("cycle-b", roots: ["cycle-a"], parents: parents).isEmpty)
    }
}
