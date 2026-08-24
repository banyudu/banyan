import Testing
@testable import BanyanCore

@Suite struct TelemetryConfigTests {
    @Test func parsesFullTelemetrySection() {
        let yaml = """
        session_launches:
          - id: zsh
            label: zsh
            command: ""

        telemetry:
          axiom_api_token: "xaat-test-token"
          axiom_dataset: my-dataset
          enabled: true
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.axiomAPIToken == "xaat-test-token")
        #expect(config.axiomDataset == "my-dataset")
        #expect(config.enabled == true)
        #expect(config.isActive == true)
    }

    @Test func defaultsDatasetWhenOmitted() {
        let yaml = """
        telemetry:
          axiom_api_token: xaat-abc
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.axiomAPIToken == "xaat-abc")
        #expect(config.axiomDataset == "banyan-logs")
        #expect(config.isActive == true)
    }

    @Test func disabledWhenNoTelemetrySection() {
        let yaml = """
        session_launches:
          - id: zsh
            label: zsh
            command: ""
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.isActive == false)
    }

    @Test func disabledWhenEmptyToken() {
        let yaml = """
        telemetry:
          axiom_api_token: ""
          enabled: true
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.isActive == false)
    }

    @Test func disabledExplicitly() {
        let yaml = """
        telemetry:
          axiom_api_token: xaat-valid
          enabled: false
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.axiomAPIToken == "xaat-valid")
        #expect(config.enabled == false)
        #expect(config.isActive == false)
    }

    @Test func enabledImplicitlyWhenTokenPresent() {
        let yaml = """
        telemetry:
          axiom_api_token: xaat-implicit
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.enabled == true)
        #expect(config.isActive == true)
    }

    @Test func handlesSingleQuotedToken() {
        let yaml = """
        telemetry:
          axiom_api_token: 'xaat-single'
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.axiomAPIToken == "xaat-single")
    }

    @Test func ignoresComments() {
        let yaml = """
        # Telemetry config
        telemetry:
          axiom_api_token: xaat-commented  # inline comment
          axiom_dataset: test-ds
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.axiomAPIToken == "xaat-commented")
        #expect(config.axiomDataset == "test-ds")
    }

    @Test func stopsAtNextTopLevelSection() {
        let yaml = """
        telemetry:
          axiom_api_token: xaat-first
        other_section:
          axiom_api_token: xaat-should-be-ignored
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.axiomAPIToken == "xaat-first")
    }

    @Test func telemetrySectionAfterSessionLaunches() {
        let yaml = """
        session_launches:
          - id: "zsh"
            label: "zsh"
            command: ""
          - id: "claude"
            label: "Claude"
            command: "claude"

        telemetry:
          axiom_api_token: xaat-after-launches
          axiom_dataset: banyan-prod
          enabled: true
        """
        let config = TelemetryConfig.parse(yaml)
        #expect(config.axiomAPIToken == "xaat-after-launches")
        #expect(config.axiomDataset == "banyan-prod")
        #expect(config.isActive == true)
    }

    @Test func disabledConfigIsNotActive() {
        let config = TelemetryConfig.disabled
        #expect(config.isActive == false)
        #expect(config.enabled == false)
    }
}
