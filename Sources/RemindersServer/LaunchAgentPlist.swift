// ABOUTME: LaunchAgent plist generation for the reminders agent subcommand.
// ABOUTME: Pure string building so tests never touch launchctl or the filesystem.

import Foundation

/// Identifiers, paths, and plist content for the reminders-mcp LaunchAgent (spec R7).
public enum LaunchAgent {
    public static let label = "com.harperreed.reminders-mcp"

    /// The plist location inside the user's LaunchAgents directory.
    public static var plistPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    /// The directory that receives the server's stdout/stderr logs.
    public static var logDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/reminders-mcp").path
    }

    /// Escapes a string for use as text inside an XML element.
    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Builds the plist XML: run `<executable> serve` at load, restart on
    /// crashes but not on clean exits, logs under `logDirectory`.
    public static func plist(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(escapeXML(label))</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escapeXML(executablePath))</string>
                <string>serve</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StandardOutPath</key>
            <string>\(escapeXML(logDirectory))/stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(escapeXML(logDirectory))/stderr.log</string>
        </dict>
        </plist>
        """
    }
}
