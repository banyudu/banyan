import Foundation
import Testing
@testable import BanyanCore

@Test(arguments: [nil, "C"] as [String?])
func tmuxAdmissionLookupPreservesTabsWithoutUTF8Locale(locale: String?) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-locale-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = TmuxBackend(environment: ProcessInfo.processInfo.environment, workingDirectory: root.path).executableURL
    let wrapper = root.appendingPathComponent("tmux")
    try "#!/bin/sh\nexec \(AgentLaunchCommand.shellQuote(tmux.path)) -f /dev/null \"$@\"\n"
        .write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    var environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/sh"]
    environment["LANG"] = locale
    let socket = "banyan-locale-\(UUID().uuidString)"
    let backend = TmuxBackend(executableURL: wrapper, workingDirectory: root.path, environment: environment, socketName: socket)
    defer { backend.killSession(named: "locale-probe") }
    try backend.ensureSession(named: "locale-probe", cwd: root.path, command: "/bin/sleep 30")
    let pane = try #require(backend.primaryPaneSnapshot(named: "locale-probe"))
    #expect(pane.rootPID > 1 && !pane.isDead)
    #expect(backend.primaryPaneSnapshots(named: ["locale-probe"])["locale-probe"] == pane)
    guard case .present(let inspected) = backend.agentAdmissionPane(named: "locale-probe") else {
        Issue.record("Admission lookup could not inspect a live private pane")
        return
    }
    #expect(inspected.rootPID == pane.rootPID)
}
