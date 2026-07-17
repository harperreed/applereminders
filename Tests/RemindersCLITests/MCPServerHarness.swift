// ABOUTME: Test harness that runs MCPServer over in-memory request lines.
// ABOUTME: Returns each response line parsed into a JSON dictionary for assertions.

import Foundation
import RemindersCore
import RemindersTestSupport

@testable import reminders

/// Collects output lines across threads.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    func append(_ line: String) {
        lock.withLock { _lines.append(line) }
    }

    var lines: [String] { lock.withLock { _lines } }
}

/// Runs a full server session over the given request lines and returns each
/// response parsed as a JSON object, in write order.
func runMCPServer(
    lines requests: [String],
    backend: FakeEventStoreBackend
) async -> [[String: Any]] {
    let store = RemindersStore(backend: backend)
    let collector = OutputCollector()
    let input = AsyncThrowingStream<String, Error> { continuation in
        for request in requests {
            continuation.yield(request)
        }
        continuation.finish()
    }
    let server = MCPServer(store: store, input: input, output: { collector.append($0) })
    await server.run()
    return collector.lines.map { line in
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["__unparseable__": line]
        }
        return object
    }
}

/// Digs the text of the first content block out of a tools/call response.
func toolText(_ response: [String: Any]) -> String {
    let result = response["result"] as? [String: Any]
    let content = result?["content"] as? [[String: Any]]
    return content?.first?["text"] as? String ?? ""
}

/// Reads the isError flag of a tools/call response (false when absent).
func toolIsError(_ response: [String: Any]) -> Bool {
    let result = response["result"] as? [String: Any]
    return result?["isError"] as? Bool ?? false
}
