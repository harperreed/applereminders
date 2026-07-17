// ABOUTME: The `reminders serve` subcommand: runs the network server (HTTP MCP + REST).
// ABOUTME: Resolves bind host, port, and bearer token, then runs Hummingbird until signalled.

import ArgumentParser
import Foundation
import RemindersCore
import RemindersServer

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the network server (MCP over HTTP + REST API) on the tailscale interface."
    )

    @Option(name: .long, help: "Interface address to bind (default: the tailscale interface).")
    var bind: String?

    @Option(name: .long, help: "Port to listen on.")
    var port: Int = 7364

    @Option(name: .long, help: "Path to the bearer token file.")
    var tokenFile: String = TokenFile.defaultPath

    @Flag(name: .long, help: "Create the token file, print the token once, and exit. Refuses to overwrite.")
    var generateToken = false

    func validate() throws {
        guard (1...65535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
    }

    func run() async throws {
        if generateToken {
            let token = try TokenFile.generate(at: tokenFile)
            print("Token written to \(tokenFile) (mode 600).")
            print(token)
            print("This is the only time the token prints. Clients send it as: Authorization: Bearer <token>")
            return
        }

        let token = try TokenFile.load(from: tokenFile)
        let host = try resolveBindHost(override: bind, interfaces: systemInterfaces())
        let store = RemindersStore()
        let app = buildApplication(
            store: store,
            configuration: ServerConfiguration(host: host, port: port, token: token)
        )
        FileHandle.standardError.write(
            Data("Serving on http://\(host):\(port) (MCP at /mcp, REST under /api)\n".utf8)
        )
        try await app.runService()
    }
}
