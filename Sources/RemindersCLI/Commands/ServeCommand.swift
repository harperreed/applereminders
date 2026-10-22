// ABOUTME: The `reminders serve` subcommand: runs the network server (HTTP MCP + REST).
// ABOUTME: Resolves bind host, port, and bearer token, then runs Hummingbird until signalled.

import ArgumentParser
import Foundation
import RemindersCore
import RemindersServer

func validateExternalBasePath(_ path: String) throws {
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.hasPrefix("/"),
          path != "/",
          !path.hasSuffix("/"),
          !path.contains("//"),
          !path.contains("?"),
          !path.contains("#"),
          !path.contains(where: { $0.isWhitespace }),
          !segments.contains("."),
          !segments.contains("..")
    else {
        throw ValidationError(
            "External base path must be a non-root path such as '/reminders', "
                + "with no trailing slash, repeated slash, dot segment, query, fragment, or whitespace."
        )
    }
}

struct ServeCommand: AsyncParsableCommand {
    static let defaultPort = 7364

    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the network server (MCP over HTTP + REST API) on the tailscale interface."
    )

    @Option(name: .long, help: "Interface address to bind (default: the tailscale interface).")
    var bind: String?

    @Option(name: .long, help: "Port to listen on.")
    var port: Int = Self.defaultPort

    @Option(name: .long, help: "Path to the bearer token file.")
    var tokenFile: String = TokenFile.defaultPath

    @Option(name: .long, help: "External URL path advertised by OpenAPI (default: /).")
    var externalBasePath: String = "/"

    @Flag(name: .long, help: "Create the token file, print the token once, and exit. Refuses to overwrite.")
    var generateToken = false

    func validate() throws {
        guard (1...65535).contains(port) else {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        if externalBasePath != "/" {
            try validateExternalBasePath(externalBasePath)
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
            configuration: ServerConfiguration(
                host: host,
                port: port,
                token: token,
                externalBasePath: externalBasePath
            )
        )
        FileHandle.standardError.write(
            Data("Serving on http://\(host):\(port) (MCP at /mcp, REST under /api)\n".utf8)
        )
        try await app.runService()
    }
}
