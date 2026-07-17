// ABOUTME: Unit tests for launchctl bootout result handling in the agent command.
// ABOUTME: Keeps uninstall idempotent without claiming success while a service remains loaded.

import Testing
@testable import reminders

@Suite("agent command")
struct AgentCommandTests {

    @Test func successfulBootoutIsAccepted() throws {
        try AgentCommand.validateBootout(
            status: 0,
            output: "",
            serviceStillLoaded: true
        )
    }

    @Test func missingServiceIsAccepted() throws {
        try AgentCommand.validateBootout(
            status: 3,
            output: "Could not find service",
            serviceStillLoaded: false
        )
    }

    @Test func failedBootoutWhileLoadedThrows() {
        #expect(throws: (any Error).self) {
            try AgentCommand.validateBootout(
                status: 5,
                output: "Permission denied",
                serviceStillLoaded: true
            )
        }
    }
}
