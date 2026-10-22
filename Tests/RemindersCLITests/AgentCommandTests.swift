// ABOUTME: Unit tests for launchctl bootout result handling in the agent command.
// ABOUTME: Keeps uninstall idempotent without claiming success while a service remains loaded.

import Foundation
import Testing
import RemindersServer
@testable import reminders

@Suite("agent command")
struct AgentCommandTests {

    @Test func installedExecutableSurvivesSourceRemovalAndFailedUpdate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("build/reminders")
        let installed = directory.appendingPathComponent("Application Support/reminders-mcp/reminders")
        let original = Data("original executable".utf8)
        try AgentCommand.installExecutable(contents: original, atPath: source.path)
        try AgentCommand.installExecutable(contents: Data(contentsOf: source), atPath: installed.path)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())

        #expect(try Data(contentsOf: installed) == original)
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))

        struct InstallFailure: Error {}
        #expect(throws: InstallFailure.self) {
            try AgentCommand.performInstallation {
                try AgentCommand.installExecutable(contents: Data("updated executable".utf8), atPath: installed.path)
                throw InstallFailure()
            } rollback: {
                try AgentCommand.installExecutable(contents: original, atPath: installed.path)
            }
        }
        #expect(try Data(contentsOf: installed) == original)
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
    }

    @Test func installAcceptsACustomTailscaleServePath() throws {
        let command = try AgentCommand.Install.parse([
            "--tailscale-serve-path", "/custom/reminders-mcp",
        ])

        #expect(command.tailscaleServePath == "/custom/reminders-mcp")
    }

    @Test func installWithoutAPathKeepsTheExistingServeArguments() throws {
        let command = try AgentCommand.Install.parse([])

        #expect(command.tailscaleServePath == nil)
        #expect(AgentCommand.launchAgentServeArguments(path: nil).isEmpty)
    }

    @Test(
        "tailscale serve paths must be non-root mount paths",
        arguments: [
            "reminders",
            "/",
            "/reminders/",
            "/reminders//nested",
            "/reminders?query=yes",
            "/reminders#fragment",
            "/reminders path",
            "/reminders/../other",
            "/./reminders",
        ]
    )
    func invalidTailscaleServePath(path: String) {
        #expect(throws: (any Error).self) {
            _ = try AgentCommand.Install.parse([
                "--tailscale-serve-path", path,
            ])
        }
    }

    @Test func tailscaleServeArgumentsMountTheLoopbackServerAtTheCustomPath() {
        #expect(
            AgentCommand.tailscaleServeArguments(path: "/custom/reminders-mcp") == [
                "serve",
                "--bg",
                "--https=443",
                "--set-path=/custom/reminders-mcp",
                "http://127.0.0.1:7364",
            ]
        )
    }

    @Test func customPathFlowsIntoTheLaunchAgentArguments() {
        #expect(
            AgentCommand.launchAgentServeArguments(path: "/custom/reminders-mcp") == [
                "--bind", "127.0.0.1",
                "--port", "7364",
                "--external-base-path", "/custom/reminders-mcp",
            ]
        )
    }

    @Test func tailscaleServeOffArgumentsRemoveOnlyTheCustomPath() {
        #expect(
            AgentCommand.tailscaleServeOffArguments(path: "/custom/reminders-mcp") == [
                "serve",
                "--https=443",
                "--set-path=/custom/reminders-mcp",
                "off",
            ]
        )
    }

    @Test func customPathCanBeRecoveredFromTheInstalledPlist() throws {
        let plist = LaunchAgent.plist(
            executablePath: "/usr/local/bin/reminders",
            serveArguments: AgentCommand.launchAgentServeArguments(
                path: "/custom/reminders-mcp"
            )
        )

        #expect(
            try AgentCommand.tailscaleServePath(plistContents: plist)
                == "/custom/reminders-mcp"
        )
    }

    @Test func defaultPlistHasNoTailscaleServePathToRemove() throws {
        let plist = LaunchAgent.plist(executablePath: "/usr/local/bin/reminders")

        #expect(try AgentCommand.tailscaleServePath(plistContents: plist) == nil)
    }

    @Test func failedInstallationRunsRollbackAndRethrowsTheOriginalError() {
        struct InstallFailure: Error {}
        var didRollback = false

        do {
            try AgentCommand.performInstallation {
                throw InstallFailure()
            } rollback: {
                didRollback = true
            }
            Issue.record("Expected installation to fail")
        } catch {
            #expect(error is InstallFailure)
        }

        #expect(didRollback)
    }

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
