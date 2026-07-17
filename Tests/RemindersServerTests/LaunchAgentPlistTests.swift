// ABOUTME: Tests for LaunchAgent plist generation and paths.
// ABOUTME: Parses the generated XML with PropertyListSerialization; never touches launchctl.

import Foundation
import Testing
@testable import RemindersServer

@Suite("LaunchAgent plist")
struct LaunchAgentPlistTests {

    @Test func plistParsesWithTheSpecifiedKeys() throws {
        let xml = LaunchAgent.plist(executablePath: "/usr/local/bin/reminders")
        let object = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8),
            format: nil
        )
        let dict = try #require(object as? [String: Any])

        #expect(dict["Label"] as? String == "com.harperreed.reminders-mcp")
        let arguments = try #require(dict["ProgramArguments"] as? [String])
        #expect(arguments == ["/usr/local/bin/reminders", "serve"])
        #expect(dict["RunAtLoad"] as? Bool == true)
        let keepAlive = try #require(dict["KeepAlive"] as? [String: Any])
        #expect(keepAlive["SuccessfulExit"] as? Bool == false)
        let stdoutPath = try #require(dict["StandardOutPath"] as? String)
        #expect(stdoutPath.hasSuffix("Library/Logs/reminders-mcp/stdout.log"))
        let stderrPath = try #require(dict["StandardErrorPath"] as? String)
        #expect(stderrPath.hasSuffix("Library/Logs/reminders-mcp/stderr.log"))
    }

    @Test func executablePathIsEscapedForXML() throws {
        let executablePath = "/Applications/R&D <Tools>/reminders"
        let xml = LaunchAgent.plist(executablePath: executablePath)
        let object = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8),
            format: nil
        )
        let dict = try #require(object as? [String: Any])
        let arguments = try #require(dict["ProgramArguments"] as? [String])
        #expect(arguments.first == executablePath)
    }

    @Test func pathsLandInTheUserDomain() {
        #expect(LaunchAgent.plistPath.hasSuffix("Library/LaunchAgents/com.harperreed.reminders-mcp.plist"))
        #expect(LaunchAgent.logDirectory.hasSuffix("Library/Logs/reminders-mcp"))
    }
}
