// ABOUTME: Parse-level tests for the serve subcommand's flags and defaults.
// ABOUTME: No server starts here; these cover option wiring and port validation only.

import Foundation
import Testing
@testable import reminders

@Suite("serve command parsing")
struct ServeCommandValidationTests {

    @Test func defaultsMatchTheSpec() throws {
        let command = try ServeCommand.parse([])
        #expect(command.port == 7364)
        #expect(command.bind == nil)
        #expect(command.generateToken == false)
        #expect(command.tokenFile.hasSuffix(".config/reminders-mcp/token"))
    }

    @Test func flagsOverrideDefaults() throws {
        let command = try ServeCommand.parse([
            "--bind", "127.0.0.1",
            "--port", "8080",
            "--token-file", "/tmp/tok",
            "--generate-token",
        ])
        #expect(command.bind == "127.0.0.1")
        #expect(command.port == 8080)
        #expect(command.tokenFile == "/tmp/tok")
        #expect(command.generateToken == true)
    }

    @Test func portZeroFailsValidation() {
        #expect(throws: (any Error).self) {
            _ = try ServeCommand.parse(["--port", "0"])
        }
    }

    @Test func portAbove65535FailsValidation() {
        #expect(throws: (any Error).self) {
            _ = try ServeCommand.parse(["--port", "70000"])
        }
    }
}
