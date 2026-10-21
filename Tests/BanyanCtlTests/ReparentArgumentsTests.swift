import Testing
@testable import BanyanCtl

@Suite struct ReparentArgumentsTests {
    @Test func requiresAnExplicitDestinationWithoutInheritedParent() throws {
        let cli = BanyanCtl(arguments: [])
        #expect(try cli.reparentPayload(["--id", "child", "--parent", "parent"]) == ["id": "child", "parent": "parent"])
        #expect(try cli.reparentPayload(["--no-parent", "--id", "child"]) == ["id": "child", "parent": ""])
        for args in [
            ["--id", "child"], ["--no-parent"], ["--id", "" , "--no-parent"],
            ["--id", "child", "--parent"], ["--id", "--parent", "parent"],
            ["--id", "child", "--parent", "", "--no-parent"],
            ["--id", "child", "--parent", "parent", "--no-parent"],
            ["--id", "child", "--no-parent", "--parent", "parent"],
            ["--id", "child", "--no-parent", "--no-parent"],
            ["--id", "child", "--no-parent", "--cwd", "/tmp"]
        ] {
            #expect(throws: (any Error).self) { try cli.reparentPayload(args) }
        }
    }
}
