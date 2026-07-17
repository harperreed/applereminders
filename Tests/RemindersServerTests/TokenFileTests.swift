// ABOUTME: Tests for bearer token file loading and generation.
// ABOUTME: Uses per-test temp directories; asserts 600 permissions and no-overwrite.

import Foundation
import Testing
@testable import RemindersServer

@Suite("Token file")
struct TokenFileTests {

    /// A unique not-yet-existing token path inside the temp directory.
    private func tempTokenPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("reminders-token-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("token").path
    }

    @Test func generateCreates64HexTokenWithMode600() throws {
        let path = tempTokenPath()
        let token = try TokenFile.generate(at: path)

        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit })

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600)

        let contents = try #require(FileManager.default.contents(atPath: path))
        #expect(String(data: contents, encoding: .utf8) == token + "\n")
    }

    @Test func loadReturnsTrimmedToken() throws {
        let path = tempTokenPath()
        let token = try TokenFile.generate(at: path)
        #expect(try TokenFile.load(from: path) == token)
    }

    @Test func generateRefusesToOverwrite() throws {
        let path = tempTokenPath()
        _ = try TokenFile.generate(at: path)
        #expect(throws: TokenFileError.alreadyExists(path)) {
            try TokenFile.generate(at: path)
        }
    }

    @Test func loadMissingFileThrows() {
        let path = tempTokenPath()
        #expect(throws: TokenFileError.missing(path)) {
            try TokenFile.load(from: path)
        }
    }

    @Test func loadBlankFileThrows() throws {
        let path = tempTokenPath()
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try Data("  \n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: TokenFileError.empty(path)) {
            try TokenFile.load(from: path)
        }
    }

    @Test func generatedTokensDiffer() throws {
        let first = try TokenFile.generate(at: tempTokenPath())
        let second = try TokenFile.generate(at: tempTokenPath())
        #expect(first != second)
    }

    @Test func errorsMentionTheGenerateFlag() {
        let missing = TokenFileError.missing("/tmp/x")
        #expect(missing.localizedDescription.contains("--generate-token"))
        let exists = TokenFileError.alreadyExists("/tmp/x")
        #expect(exists.localizedDescription.contains("Delete it first"))
    }

    @Test func generateTightensExistingDirectoryTo700() throws {
        let path = tempTokenPath()
        let directory = (path as NSString).deletingLastPathComponent
        // Pre-create the parent directory at 0o755 (world-readable).
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        _ = try TokenFile.generate(at: path)

        let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory)
        let dirMode = try #require(dirAttributes[.posixPermissions] as? NSNumber)
        #expect(dirMode.intValue == 0o700, "parent directory should be tightened to 0700")

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: path)
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue == 0o600, "token file should remain 0600")
    }
}
