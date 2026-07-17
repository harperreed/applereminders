// ABOUTME: Bearer token file management: load, and generate with 0600 permissions.
// ABOUTME: The token authenticates every HTTP request (spec R5).

import Foundation

/// Errors from loading or generating the bearer token file. Messages point at
/// the fix because they surface directly as CLI output.
public enum TokenFileError: LocalizedError, Equatable {
    case missing(String)
    case empty(String)
    case alreadyExists(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path):
            return "No token file at \(path). Run 'reminders serve --generate-token' to create one."
        case .empty(let path):
            return "Token file at \(path) is empty. Delete it and run 'reminders serve --generate-token'."
        case .alreadyExists(let path):
            return "Token file already exists at \(path). Delete it first to rotate the token."
        case .writeFailed(let path):
            return "Could not write token file at \(path)."
        }
    }
}

/// Loads and creates the bearer token file (one line, mode 600).
public enum TokenFile {

    /// Default token location, per spec R5.
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/reminders-mcp/token").path
    }

    /// Reads and trims the token. Throws when the file is missing or blank.
    public static func load(from path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = String(data: data, encoding: .utf8) else {
            throw TokenFileError.missing(path)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw TokenFileError.empty(path)
        }
        return token
    }

    /// Generates a 32-byte random token as 64 hex characters, writes it with
    /// mode 600 (parent directories 700), and returns it. Refuses to overwrite:
    /// rotation is an explicit delete-then-generate act.
    public static func generate(at path: String) throws -> String {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path) else {
            throw TokenFileError.alreadyExists(path)
        }
        let directory = (path as NSString).deletingLastPathComponent
        try fileManager.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // SystemRandomNumberGenerator (behind UInt8.random) is cryptographically
        // secure on Apple platforms.
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let created = fileManager.createFile(
            atPath: path,
            contents: Data((token + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw TokenFileError.writeFailed(path)
        }
        return token
    }
}
