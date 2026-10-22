// ABOUTME: The `reminders agent` subcommand group: install, uninstall, status.
// ABOUTME: Writes the LaunchAgent plist and drives launchctl for always-on serving.

import ArgumentParser
import Foundation
import RemindersServer

struct AgentCommand: ParsableCommand {
    static let localBindHost = "127.0.0.1"
    static let tailscaleHTTPSPort = 443

    struct LaunchAgentSnapshot {
        let plistContents: String?
        let wasLoaded: Bool
    }

    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Manage the launchd agent that keeps the network server running.",
        subcommands: [Install.self, Uninstall.self, Status.self]
    )

    /// Runs launchctl with the given arguments, returning status and combined output.
    @discardableResult
    static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try runCommand(executablePath: "/bin/launchctl", arguments: arguments)
    }

    private static func runCommand(
        executablePath: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Runs the Tailscale CLI inherited from the installer's shell environment.
    @discardableResult
    static func tailscale(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try runCommand(
            executablePath: "/usr/bin/env",
            arguments: ["tailscale"] + arguments
        )
    }

    static func tailscaleServeArguments(path: String) -> [String] {
        [
            "serve",
            "--bg",
            "--https=\(tailscaleHTTPSPort)",
            "--set-path=\(path)",
            "http://\(localBindHost):\(ServeCommand.defaultPort)",
        ]
    }

    static func tailscaleServeOffArguments(path: String) -> [String] {
        [
            "serve",
            "--https=\(tailscaleHTTPSPort)",
            "--set-path=\(path)",
            "off",
        ]
    }

    static func launchAgentServeArguments(path: String?) -> [String] {
        guard let path else { return [] }
        return [
            "--bind", localBindHost,
            "--port", String(ServeCommand.defaultPort),
            "--external-base-path", path,
        ]
    }

    static func tailscaleServePath(plistContents: String) throws -> String? {
        let plist = try PropertyListSerialization.propertyList(
            from: Data(plistContents.utf8),
            format: nil
        )
        guard
            let dictionary = plist as? [String: Any],
            let arguments = dictionary["ProgramArguments"] as? [String],
            let optionIndex = arguments.firstIndex(of: "--external-base-path"),
            arguments.indices.contains(optionIndex + 1)
        else {
            return nil
        }
        return arguments[optionIndex + 1]
    }

    static func installedTailscaleServePath() throws -> String? {
        guard FileManager.default.fileExists(atPath: LaunchAgent.plistPath) else {
            return nil
        }
        let contents = try String(contentsOfFile: LaunchAgent.plistPath, encoding: .utf8)
        return try tailscaleServePath(plistContents: contents)
    }

    static func bootstrapLaunchAgent(errorPrefix: String) throws {
        let result = try launchctl([
            "bootstrap", "gui/\(getuid())", LaunchAgent.plistPath,
        ])
        guard result.status == 0 else {
            throw ValidationError(
                "\(errorPrefix) (\(result.status)): \(result.output)"
            )
        }
    }

    static func captureLaunchAgentSnapshot() throws -> LaunchAgentSnapshot {
        let plistContents: String?
        if FileManager.default.fileExists(atPath: LaunchAgent.plistPath) {
            plistContents = try String(contentsOfFile: LaunchAgent.plistPath, encoding: .utf8)
        } else {
            plistContents = nil
        }
        let loaded = try launchctl(["print", serviceTarget]).status == 0
        guard plistContents != nil || !loaded else {
            throw ValidationError(
                "Cannot safely reinstall \(LaunchAgent.label): the service is loaded but its plist is missing."
            )
        }
        return LaunchAgentSnapshot(plistContents: plistContents, wasLoaded: loaded)
    }

    static func restoreLaunchAgent(_ snapshot: LaunchAgentSnapshot) throws {
        try unloadIfLoaded()
        if let plistContents = snapshot.plistContents {
            try plistContents.write(
                toFile: LaunchAgent.plistPath,
                atomically: true,
                encoding: .utf8
            )
            if snapshot.wasLoaded {
                try bootstrapLaunchAgent(errorPrefix: "launchctl rollback bootstrap failed")
            }
        } else if FileManager.default.fileExists(atPath: LaunchAgent.plistPath) {
            try FileManager.default.removeItem(atPath: LaunchAgent.plistPath)
        }
    }

    static func performInstallation(
        changes: () throws -> Void,
        rollback: () throws -> Void
    ) throws {
        do {
            try changes()
        } catch {
            do {
                try rollback()
            } catch let rollbackError {
                throw ValidationError(
                    "Installation failed: \(error). Rollback also failed: \(rollbackError)"
                )
            }
            throw error
        }
    }

    /// Atomic replacement also works when updating the currently running executable.
    static func installExecutable(contents: Data, atPath path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
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

        @Option(
            name: .long,
            help: "Expose the server through Tailscale Serve at this path (for example, /reminders)."
        )
        var tailscaleServePath: String?

        func validate() throws {
            if let tailscaleServePath {
                try validateExternalBasePath(tailscaleServePath)
            }
        }

        func run() throws {
            let source = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let executable = LaunchAgent.executablePath
            let executableContents = try Data(contentsOf: URL(fileURLWithPath: source))
            let previousExecutable = FileManager.default.fileExists(atPath: executable)
                ? try Data(contentsOf: URL(fileURLWithPath: executable)) : nil
            let serveArguments = AgentCommand.launchAgentServeArguments(
                path: tailscaleServePath
            )
            try FileManager.default.createDirectory(
                atPath: (LaunchAgent.plistPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: LaunchAgent.logDirectory,
                withIntermediateDirectories: true
            )
            let snapshot = try AgentCommand.captureLaunchAgentSnapshot()
            try AgentCommand.performInstallation {
                try AgentCommand.unloadIfLoaded()
                try AgentCommand.installExecutable(contents: executableContents, atPath: executable)
                try LaunchAgent.plist(
                    executablePath: executable,
                    serveArguments: serveArguments
                )
                    .write(toFile: LaunchAgent.plistPath, atomically: true, encoding: .utf8)

                try AgentCommand.bootstrapLaunchAgent(errorPrefix: "launchctl bootstrap failed")

                if let tailscaleServePath {
                    let arguments = AgentCommand.tailscaleServeArguments(
                        path: tailscaleServePath
                    )
                    let (status, output) = try AgentCommand.tailscale(arguments)
                    guard status == 0 else {
                        throw ValidationError("tailscale serve failed (\(status)): \(output)")
                    }
                    print(
                        "Tailscale Serve: \(tailscaleServePath) proxies to "
                            + "http://\(AgentCommand.localBindHost):\(ServeCommand.defaultPort)"
                    )
                }
            } rollback: {
                // Stop the replacement before restoring the binary used by the old plist.
                try AgentCommand.unloadIfLoaded()
                if let previousExecutable {
                    try AgentCommand.installExecutable(contents: previousExecutable, atPath: executable)
                } else if FileManager.default.fileExists(atPath: executable) {
                    try FileManager.default.removeItem(atPath: executable)
                }
                try AgentCommand.restoreLaunchAgent(snapshot)
            }

            print("Installed \(LaunchAgent.label): runs '\(executable) serve' at login, restarts on crashes.")
            print("Logs: \(LaunchAgent.logDirectory)")
            print("""

            The agent uses its own copy; rebuilding or moving the checkout will not change it.
            To update it, run 'reminders agent install' from the new build with the same options.

            macOS may require Reminders access for the installed copy after an install or update.
            Run this command in Terminal and grant access if prompted:
              "\(executable)" show-lists
            """)
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop the LaunchAgent and remove its plist."
        )

        func run() throws {
            if let tailscaleServePath = try AgentCommand.installedTailscaleServePath() {
                try validateExternalBasePath(tailscaleServePath)
                let result = try AgentCommand.tailscale(
                    AgentCommand.tailscaleServeOffArguments(path: tailscaleServePath)
                )
                guard result.status == 0 else {
                    throw ValidationError(
                        "tailscale serve route removal failed "
                            + "(\(result.status)): \(result.output)"
                    )
                }
                print("Removed Tailscale Serve route at \(tailscaleServePath).")
            }
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
