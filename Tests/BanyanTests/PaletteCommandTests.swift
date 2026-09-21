@testable import Banyan
import Foundation
import Testing

@Test func paletteCommandsParseTitleCommandRunAndWhen() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}}"
        run: session
        when: issue
      - id: verify
        title: "Verify {{target}}"
        command: "~/bin/verify-linear {{target}}"
        run: background
        when: linear
    """)

    #expect(commands.map(\.id) == ["work", "verify"])
    #expect(commands[0].run == .session)
    #expect(commands[0].when == .issue)
    #expect(commands[1].run == .background)
    #expect(commands[1].when == .linear)
    #expect(commands[0].expandedTitle(target: "ENG-123", query: nil) == "Work on ENG-123")
    #expect(commands[0].expandedCommand(target: "ENG-123", query: nil) == "~/bin/workit ENG-123")
}

@Test func paletteCommandsDefaultToSessionAndAlways() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: quick
        title: Quick
        command: echo hi
    """)

    #expect(commands.count == 1)
    #expect(commands[0].run == .session)
    #expect(commands[0].when == .always)
}

@Test func paletteCommandsCoexistWithSessionLaunches() throws {
    let commands = try PaletteCommandLoader.parse("""
    session_launches:
      - id: claude
        label: Claude
        command: claude
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}}"
    """)

    #expect(commands.map(\.id) == ["work"])
}

@Test func paletteCommandTargetDetectionPrefersLinear() {
    #expect(PaletteCommandTarget.detect(in: "ENG-123") == .linear("ENG-123"))
    #expect(PaletteCommandTarget.detect(in: "verify ENG-456") == .linear("ENG-456"))
    #expect(PaletteCommandTarget.detect(in: "not-an-issue") == nil)
    let github = PaletteCommandTarget.detect(in: "https://github.com/owner/repo/issues/17")
    #expect(github == .github("https://github.com/owner/repo/issues/17"))
}

@Test func paletteCommandWhenFiltersTargets() {
    let linear = PaletteCommandTarget.linear("ENG-123")
    let github = PaletteCommandTarget.github("https://github.com/o/r/issues/1")
    let always = PaletteCommand(id: "a", title: "A", command: "echo", run: .session, when: .always)
    let issue = PaletteCommand(id: "i", title: "I", command: "echo", run: .session, when: .issue)
    let linearOnly = PaletteCommand(id: "l", title: "L", command: "echo", run: .session, when: .linear)
    let githubOnly = PaletteCommand(id: "g", title: "G", command: "echo", run: .session, when: .github)

    #expect(always.matches(target: linear))
    #expect(always.matches(target: github))
    #expect(issue.matches(target: linear))
    #expect(issue.matches(target: github))
    #expect(linearOnly.matches(target: linear))
    #expect(!linearOnly.matches(target: github))
    #expect(!githubOnly.matches(target: linear))
    #expect(githubOnly.matches(target: github))
    #expect(!always.matches(target: nil))
}

@Test func duplicatePaletteCommandIDsThrow() {
    #expect(throws: Error.self) {
        try PaletteCommandLoader.parse("""
        palette_commands:
          - id: work
            title: Work
            command: echo a
          - id: work
            title: Work again
            command: echo b
        """)
    }
    #expect(throws: Error.self) {
        try PaletteCommandLoader.parse("""
        palette_commands:
          - id: work
            title: Work
            command: echo a
            run: teleport
        """)
    }
}

private func paletteTestHome() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-palette-tests-\(UUID().uuidString)")
}

private func writePaletteTestFile(home: URL, name: String, contents: String) {
    let dir = home.appendingPathComponent(".banyan")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

@Test func paletteCommandsLoadFromDedicatedPaletteFile() {
    let home = paletteTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    writePaletteTestFile(home: home, name: "palette.yml", contents: """
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}}"
        run: background
        when: issue
    """)

    let result = PaletteCommandLoader.load(homeDirectory: home)

    #expect(result.commands.map(\.id) == ["work"])
    #expect(result.diagnostic == nil)
}

@Test func paletteCommandsMergeConfigFileAfterDedicatedFile() {
    let home = paletteTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    writePaletteTestFile(home: home, name: "palette.yml", contents: """
    palette_commands:
      - id: work
        title: Work
        command: echo work
    """)
    writePaletteTestFile(home: home, name: "config.yml", contents: """
    palette_commands:
      - id: verify
        title: Verify
        command: echo verify
    """)

    let result = PaletteCommandLoader.load(homeDirectory: home)

    #expect(result.commands.map(\.id) == ["work", "verify"])
    #expect(result.diagnostic == nil)
}

@Test func paletteCommandsPreferDedicatedFileOnDuplicateIDs() {
    let home = paletteTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    writePaletteTestFile(home: home, name: "palette.yml", contents: """
    palette_commands:
      - id: work
        title: Work local
        command: echo local
    """)
    writePaletteTestFile(home: home, name: "config.yml", contents: """
    palette_commands:
      - id: work
        title: Work config
        command: echo config
    """)

    let result = PaletteCommandLoader.load(homeDirectory: home)

    #expect(result.commands.map(\.title) == ["Work local"])
    #expect(result.diagnostic?.contains("Duplicate palette command id 'work'") == true)
}
