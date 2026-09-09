import Foundation
import Testing
@testable import BanyanCore

private func indexLine(id: String, name: String, updatedAt: String) -> String {
    let payload: [String: Any] = ["id": id, "thread_name": name, "updated_at": updatedAt]
    let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

@Test func codexTitleIndexReportsTheRenamedThreadName() {
    let contents = [
        indexLine(id: "thread-a", name: "I want you to deploy the latest co", updatedAt: "2026-07-01T10:00:00.000Z"),
        indexLine(id: "thread-a", name: "Deploy the release build", updatedAt: "2026-07-01T10:00:06.000Z")
    ].joined(separator: "\n")

    #expect(CodexSessionTitleIndex.generatedTitles(indexContents: contents) == ["thread-a": "Deploy the release build"])
}

@Test func codexTitleIndexIgnoresAThreadThatWasNeverRenamed() {
    // Title generation never completed: the truncated first prompt is all Codex
    // ever wrote, and Banyan derives a better title from the prompt itself.
    let contents = indexLine(
        id: "thread-b",
        name: "check the failing integration tes",
        updatedAt: "2026-07-01T10:00:00.000Z"
    )

    #expect(CodexSessionTitleIndex.generatedTitles(indexContents: contents).isEmpty)
}

@Test func codexTitleIndexIgnoresRepeatedIdenticalNames() {
    let contents = [
        indexLine(id: "thread-c", name: "check the failing integration tes", updatedAt: "2026-07-01T10:00:00.000Z"),
        indexLine(id: "thread-c", name: "check the failing integration tes", updatedAt: "2026-07-01T11:00:00.000Z")
    ].joined(separator: "\n")

    #expect(CodexSessionTitleIndex.generatedTitles(indexContents: contents).isEmpty)
}

@Test func codexTitleIndexKeepsTheLastNameWhenAThreadIsRenamedAgain() {
    let contents = [
        indexLine(id: "thread-d", name: "look at the sidebar bug in the ter", updatedAt: "2026-07-01T10:00:00.000Z"),
        indexLine(id: "thread-d", name: "Fix sidebar ordering", updatedAt: "2026-07-01T10:00:05.000Z"),
        indexLine(id: "thread-d", name: "Sidebar ordering rewrite", updatedAt: "2026-07-01T12:00:00.000Z")
    ].joined(separator: "\n")

    #expect(CodexSessionTitleIndex.generatedTitles(indexContents: contents) == ["thread-d": "Sidebar ordering rewrite"])
}

@Test func codexTitleIndexSkipsUnusableRows() {
    let contents = [
        "not json",
        #"{"thread_name":"Missing an id","updated_at":"2026-07-01T10:00:00.000Z"}"#,
        indexLine(id: "thread-e", name: "run the shell", updatedAt: "2026-07-01T10:00:00.000Z"),
        // "Shell" is one of Banyan's own generic placeholders, never a title.
        indexLine(id: "thread-e", name: "Shell", updatedAt: "2026-07-01T10:00:05.000Z")
    ].joined(separator: "\n")

    #expect(CodexSessionTitleIndex.generatedTitles(indexContents: contents).isEmpty)
}

@Test func codexTitleIndexReadsFromTheHomeDirectory() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-codex-index-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".codex"),
        withIntermediateDirectories: true
    )

    try [
        indexLine(id: "thread-f", name: "please rework the importer so tha", updatedAt: "2026-07-01T10:00:00.000Z"),
        indexLine(id: "thread-f", name: "Rework history importer", updatedAt: "2026-07-01T10:00:07.000Z")
    ].joined(separator: "\n").write(
        to: CodexSessionTitleIndex.indexURL(homeDirectory: home),
        atomically: true,
        encoding: .utf8
    )

    #expect(CodexSessionTitleIndex.generatedTitles(homeDirectory: home) == ["thread-f": "Rework history importer"])
}

@Test func codexTitleIndexIsEmptyWithoutAnIndexFile() {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-codex-missing-\(UUID().uuidString)")

    #expect(CodexSessionTitleIndex.generatedTitles(homeDirectory: home).isEmpty)
}
