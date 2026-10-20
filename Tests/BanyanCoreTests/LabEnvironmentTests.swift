import Testing
@testable import BanyanCore

@Suite struct LabEnvironmentTests {
    @Test func acceptsSafeTmuxSocketOverride() {
        #expect(LabEnvironment.tmuxSocketName(from: ["BANYAN_TMUX_SOCKET": "banyan-lab-7843"]) == "banyan-lab-7843")
        #expect(LabEnvironment.tmuxSocketName(from: ["BANYAN_TMUX_SOCKET": "lab.v2_test"]) == "lab.v2_test")
    }

    @Test func rejectsUnsafeTmuxSocketOverride() {
        #expect(LabEnvironment.tmuxSocketName(from: [:]) == nil)
        #expect(LabEnvironment.tmuxSocketName(from: ["BANYAN_TMUX_SOCKET": "  "]) == nil)
        #expect(LabEnvironment.tmuxSocketName(from: ["BANYAN_TMUX_SOCKET": "../banyan"]) == nil)
        #expect(LabEnvironment.tmuxSocketName(from: ["BANYAN_TMUX_SOCKET": "banyan lab"]) == nil)
        #expect(LabEnvironment.tmuxSocketName(from: ["BANYAN_TMUX_SOCKET": ".hidden"]) == nil)
    }

    @Test func parsesControlPortOverride() {
        #expect(LabEnvironment.controlPort(from: ["BANYAN_CONTROL_PORT": "7843"]) == 7843)
        #expect(LabEnvironment.controlPort(from: ["BANYAN_CONTROL_PORT": " 7844 "]) == 7844)
        #expect(LabEnvironment.controlPort(from: ["BANYAN_CONTROL_PORT": "0"]) == nil)
        #expect(LabEnvironment.controlPort(from: ["BANYAN_CONTROL_PORT": "70000"]) == nil)
        #expect(LabEnvironment.controlPort(from: ["BANYAN_CONTROL_PORT": "not-a-port"]) == nil)
    }
}
