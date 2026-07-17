// ABOUTME: The `reminders agent` subcommand group: install, uninstall, status.
// ABOUTME: Writes the LaunchAgent plist and drives launchctl for always-on serving.

import ArgumentParser
import Foundation
import RemindersServer

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Manage the launchd agent that keeps the network server running.",
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    /// Runs launchctl with the given arguments, returning status and combined output.
    @discardableResult
    static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// The launchd service target for the current user's GUI domain.
    static var serviceTarget: String {
        "gui/\(getuid())/\(LaunchAgent.label)"
    }

    /// Accepts a failed bootout only when launchd confirms the service is gone.
    static func validateBootout(
        status: Int32,
        output: String,
        serviceStillLoaded: Bool
    ) throws {
        guard status == 0 || !serviceStillLoaded else {
            throw ValidationError("launchctl bootout failed (\(status)): \(output)")
        }
    }

    /// Unloads the service when present while keeping the operation idempotent.
    static func unloadIfLoaded() throws {
        let result = try launchctl(["bootout", serviceTarget])
        guard result.status != 0 else { return }
        let probe = try launchctl(["print", serviceTarget])
        try validateBootout(
            status: result.status,
            output: result.output,
            serviceStillLoaded: probe.status == 0
        )
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install and start the LaunchAgent (runs at login, restarts on crashes)."
        )

        func run() throws {
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            try FileManager.default.createDirectory(
                atPath: (LaunchAgent.plistPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: LaunchAgent.logDirectory,
                withIntermediateDirectories: true
            )
            try LaunchAgent.plist(executablePath: executable)
                .write(toFile: LaunchAgent.plistPath, atomically: true, encoding: .utf8)

            // Unload any previous version first so reinstalls are idempotent.
            _ = try? AgentCommand.unloadIfLoaded()
            let (status, output) = try AgentCommand.launchctl(
                ["bootstrap", "gui/\(getuid())", LaunchAgent.plistPath]
            )
            guard status == 0 else {
                throw ValidationError("launchctl bootstrap failed (\(status)): \(output)")
            }

            print("Installed \(LaunchAgent.label): runs '\(executable) serve' at login, restarts on crashes.")
            print("Logs: \(LaunchAgent.logDirectory)")
            print("""

            WARNING: macOS ties Reminders access to the binary's path and signature. If you \
            rebuild or move \(executable), macOS may silently re-prompt for Reminders access. \
            Nobody sees that prompt under launchd; the server then fails with a permission \
            error until you run the binary once by hand and grant access again. Check \
            'reminders agent status' if requests start failing.
            """)
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the LaunchAgent and remove its plist."
        )

        func run() throws {
            try AgentCommand.unloadIfLoaded()
            if FileManager.default.fileExists(atPath: LaunchAgent.plistPath) {
                try FileManager.default.removeItem(atPath: LaunchAgent.plistPath)
                print("Removed \(LaunchAgent.plistPath)")
            } else {
                print("No plist at \(LaunchAgent.plistPath); nothing to remove.")
            }
            print("Unloaded \(LaunchAgent.label) (if it was running).")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the LaunchAgent's launchd state, including the last exit status."
        )

        func run() throws {
            let (status, output) = try AgentCommand.launchctl(
                ["print", AgentCommand.serviceTarget]
            )
            if status == 0 {
                print(output)
            } else {
                print("\(LaunchAgent.label) is not loaded. Run 'reminders agent install' to set it up.")
            }
        }
    }
}
