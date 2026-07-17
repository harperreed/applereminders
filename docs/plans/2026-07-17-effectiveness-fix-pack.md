# reminders-mcp Effectiveness Fix Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MCP server truthful and robust for LLM clients (stable-id addressing, fresh data, protocol-safe errors, survivable auth failures) and close the CLI validation, CI, and documentation gaps found in the 2026-07-17 expert-panel audit.

**Architecture:** All changes stay inside the existing two-target layout. `RemindersCore` (the EventKit actor) gains a richer `delete` return type and external-change observation. The `reminders` executable target gets JSON-RPC envelopes built by `JSONEncoder` (replacing hand-rolled string escaping), truthful tool schemas/descriptions, lazy authorization, and due-date validation. CI and a README land alongside.

**Tech Stack:** Swift 6 (strict concurrency), swift-argument-parser, EventKit, swift-testing (`@Suite`/`@Test`/`#expect`/`#require`), GitHub Actions on `macos-15`.

## Global Constraints

- Swift 6 language mode. `swift build` must produce **zero new warnings**.
- macOS platform floor stays `.v14`. Do not raise it.
- All work happens on branch `effectiveness-fix-pack`. Conventional commits, imperative present tense.
- NEVER bypass git hooks. Forbidden flags: `--no-verify`, `--no-hooks`, `--no-pre-commit-hook`.
- The MCP wire contract keeps the parameter name `index` on mutating tools (existing clients depend on it). Only its schema and description change.
- CLI stdout strings must not change except where a task explicitly shows a changed string.
- Hand-written source files start with two `// ABOUTME:` comment lines (existing repo convention; `# ABOUTME:` in Makefiles/YAML, `<!-- ABOUTME: -->` not needed for Markdown).
- Tests live in `Tests/RemindersCLITests/` (which uses `@testable import reminders`) and `Tests/RemindersCoreTests/` (which imports `RemindersCore`). Use swift-testing (`@Suite`, `@Test`, `#expect`), not XCTest.
- **No test may touch live EventKit** — CI runners have no TCC grant. EventKit-touching behavior gets explicit manual verification steps instead; say so honestly in commit messages and reports.
- Run all commands from the repo root: `/Users/harper/Public/src/personal/applereminders`.

---

### Task 1: CI workflow and canonical `make check` target

There is currently no CI at all — `release.yml` only fires on version tags. Every later task in this plan lands under CI protection once this merges.

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `Makefile` (`.PHONY` line and new `check` target)

**Interfaces:**
- Consumes: nothing.
- Produces: `make check` (runs `swift build` then `swift test`) — the canonical verification command every later task uses. CI job `test` on `macos-15` running the same two commands on pushes to `main` and all PRs.

- [ ] **Step 1: Verify the pinned SHA for actions/checkout v4.2.2**

Run:
```bash
gh api repos/actions/checkout/commits/v4.2.2 --jq .sha
```
Expected: `11bd71901bbe5b1630ceea73d27597364c9af683`. If the output differs, use the returned value in Step 2 and keep the `# v4.2.2` comment accurate.

- [ ] **Step 2: Create `.github/workflows/ci.yml`**

```yaml
# ABOUTME: Continuous integration — builds and tests every push to main and every PR.
# ABOUTME: Runs on macOS 15 for the Swift 6 toolchain (matches release.yml).
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  test:
    name: Build and test
    runs-on: macos-15
    steps:
      - name: Check out source
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

- [ ] **Step 3: Add the `check` target to `Makefile`**

Change the `.PHONY` line from:

```makefile
.PHONY: all build release test install uninstall clean lint tag
```

to (note: `run` was already a phony target but was missing from `.PHONY` — pre-existing bug, fixed while touching this line):

```makefile
.PHONY: all build release test check install uninstall clean lint run tag
```

Then insert a `check` target directly after the existing `test:` target (recipe lines must be TAB-indented):

```makefile
check: build test
```

- [ ] **Step 4: Run the canonical check locally**

Run: `make check`
Expected: `swift build` succeeds with zero warnings, `swift test` passes (existing suites: DateParsing, MCPTypes, RemindersCore Errors/Models). If any *pre-existing* test fails (e.g. a timezone-sensitive date test), STOP and report it — do not skip or delete it.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml Makefile
git commit -m "feat: add CI workflow and canonical make check target"
```

---

### Task 2: Correct TCC usage-description key in Info.plist

The embedded Info.plist carries only the legacy `NSRemindersUsageDescription`. The code calls `requestFullAccessToReminders()` (macOS 14+), whose TCC prompt reads `NSRemindersFullAccessUsageDescription`. With the wrong key the authorization flow can fail or show no usage string.

**Files:**
- Modify: `Sources/RemindersCLI/Resources/Info.plist`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing code-visible; the binary's embedded plist gains the correct key.

- [ ] **Step 1: Replace the plist content**

Full new content of `Sources/RemindersCLI/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>This app needs access to your reminders to manage them from the command line.</string>
</dict>
</plist>
```

(Single key, replacing `NSRemindersUsageDescription`. We do not keep both: the platform floor is macOS 14 and only the full-access API is called.)

- [ ] **Step 2: Verify the key is embedded in the binary**

Run:
```bash
swift build && otool -P .build/debug/reminders
```
Expected: the printed plist XML contains `NSRemindersFullAccessUsageDescription` and no longer contains `NSRemindersUsageDescription`.

Do NOT run `tccutil reset Reminders` — that would revoke Harper's existing grants on this machine. The live prompt re-verification is an optional step listed in Task 12 for Harper to run if he chooses.

- [ ] **Step 3: Commit**

```bash
git add Sources/RemindersCLI/Resources/Info.plist
git commit -m "fix: use NSRemindersFullAccessUsageDescription for macOS 14+ TCC prompt"
```

---

### Task 3: Build JSON-RPC envelopes with JSONEncoder

`makeErrorResponse` hand-escapes only `\`, `"`, and `\n` — a tab, carriage return, or control character in an error message (which interpolates user data like list names and OS error strings) emits invalid JSON and corrupts the protocol stream. `encodeID` has the same flaw for string IDs. Replace all manual envelope string-building with `Encodable` structs.

**Files:**
- Modify: `Sources/RemindersCLI/MCPTypes.swift` (add envelope types)
- Modify: `Sources/RemindersCLI/MCPServer.swift` (replace response builders, delete `encodeID`, simplify `handleToolsList`/`handleToolsCall`)
- Create: `Tests/RemindersCLITests/JSONRPCEnvelopeTests.swift`

**Interfaces:**
- Consumes: `RequestID`, `MCPToolDefinition`, `JSONSchema`, `MCPToolResult` (existing, unchanged).
- Produces (used by Task 7):
  - `struct JSONRPCResponse<Payload: Encodable & Sendable>: Encodable, Sendable` — `init(id: RequestID?, result: Payload)`
  - `struct JSONRPCErrorBody: Encodable, Sendable, Equatable` — `init(code: Int, message: String)`
  - `struct JSONRPCErrorResponse: Encodable, Sendable` — `init(id: RequestID?, error: JSONRPCErrorBody)`
  - `struct ToolsListResult: Encodable, Sendable` — `init(tools: [MCPToolDefinition])`
  - `MCPServer.encodeEnvelope<T: Encodable>(_ envelope: T, id: RequestID?) -> String` (private instance method on the actor)

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersCLITests/JSONRPCEnvelopeTests.swift`:

```swift
// ABOUTME: Tests for JSON-RPC envelope types encoded via JSONEncoder.
// ABOUTME: Proves error messages and string IDs with special characters survive encoding.

import Foundation
import Testing

@testable import reminders

@Suite("JSON-RPC envelopes")
struct JSONRPCEnvelopeTests {

    private struct DecodedError: Decodable {
        struct Body: Decodable {
            let code: Int
            let message: String
        }
        let jsonrpc: String
        let error: Body
    }

    @Test("error message with quotes, tabs, CR, and control chars stays valid JSON")
    func errorMessageSurvivesSpecialCharacters() throws {
        let hostile = "path \"quoted\"\twith\ttabs\r\nand control\u{01}chars\\backslash"
        let envelope = JSONRPCErrorResponse(
            id: .int(3),
            error: JSONRPCErrorBody(code: -32603, message: hostile)
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(DecodedError.self, from: data)

        #expect(decoded.jsonrpc == "2.0")
        #expect(decoded.error.code == -32603)
        #expect(decoded.error.message == hostile)
    }

    @Test("string request ID with quote and backslash round-trips")
    func stringIDSurvivesSpecialCharacters() throws {
        let envelope = JSONRPCErrorResponse(
            id: .string("req \"7\" \\ end"),
            error: JSONRPCErrorBody(code: -32700, message: "Parse error")
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["id"] as? String == "req \"7\" \\ end")
    }

    @Test("missing request ID encodes as explicit null")
    func nilIDEncodesAsNull() throws {
        let envelope = JSONRPCErrorResponse(
            id: nil,
            error: JSONRPCErrorBody(code: -32700, message: "Parse error")
        )

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object != nil)
        #expect(object?.keys.contains("id") == true)
        #expect(object?["id"] is NSNull)
    }

    @Test("success envelope wraps the result under 'result'")
    func successEnvelopeShape() throws {
        let envelope = JSONRPCResponse(id: .int(1), result: MCPToolResult.success("ok"))

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["jsonrpc"] as? String == "2.0")
        #expect(object?["id"] as? Int == 1)
        let result = object?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "ok")
    }

    @Test("tools/list result nests tools under the result object")
    func toolsListResultShape() throws {
        let tool = MCPToolDefinition(
            name: "demo",
            description: "Demo tool",
            inputSchema: JSONSchema(type: "object", properties: nil, required: nil)
        )
        let envelope = JSONRPCResponse(id: .string("a"), result: ToolsListResult(tools: [tool]))

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = object?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]

        #expect(tools?.count == 1)
        #expect(tools?.first?["name"] as? String == "demo")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter JSONRPCEnvelopeTests`
Expected: BUILD FAILURE — `cannot find 'JSONRPCErrorResponse' in scope` (and friends). A compile failure is the red phase here.

- [ ] **Step 3: Add the envelope types to MCPTypes.swift**

Insert into `Sources/RemindersCLI/MCPTypes.swift` immediately after the `JSONRPCRequest` struct (after line 138, before `// MARK: - MCP Tool Definitions`):

```swift
// MARK: - JSON-RPC Responses

/// An outgoing JSON-RPC 2.0 success envelope. Encoding via JSONEncoder guarantees
/// correct escaping of IDs and results — never build these by string concatenation.
struct JSONRPCResponse<Payload: Encodable & Sendable>: Encodable, Sendable {
    let id: RequestID?
    let result: Payload

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        // JSON-RPC 2.0 requires an explicit `"id": null` when the request ID is unknown.
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        try container.encode(result, forKey: .result)
    }
}

/// The `error` member of a JSON-RPC 2.0 error response.
struct JSONRPCErrorBody: Encodable, Sendable, Equatable {
    let code: Int
    let message: String
}

/// An outgoing JSON-RPC 2.0 error envelope.
struct JSONRPCErrorResponse: Encodable, Sendable {
    let id: RequestID?
    let error: JSONRPCErrorBody

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encodeNil(forKey: .id)
        }
        try container.encode(error, forKey: .error)
    }
}

/// The `result` payload for `tools/list`.
struct ToolsListResult: Encodable, Sendable {
    let tools: [MCPToolDefinition]
}
```

- [ ] **Step 4: Replace the response builders in MCPServer.swift**

In `Sources/RemindersCLI/MCPServer.swift`, replace the entire `// MARK: - Response Builders` section AND the entire `// MARK: - Encoding Helpers` section (currently lines 250–290: `makeSuccessResponse`, `makeErrorResponse`, and `encodeID`) with:

```swift
    // MARK: - Response Builders

    /// Encodes a JSON-RPC envelope to a single-line string via JSONEncoder.
    /// Falls back to an error response (and finally to a constant) so the server
    /// always writes valid JSON no matter what encoding throws.
    private func encodeEnvelope<T: Encodable>(_ envelope: T, id: RequestID?) -> String {
        do {
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw MCPToolError.encodingFailed
            }
            return json
        } catch {
            logStderr("envelope encode error: \(error.localizedDescription)")
            return makeErrorResponse(id: id, code: -32603, message: "Failed to encode response")
        }
    }

    /// Builds a JSON-RPC success response string.
    private func makeSuccessResponse(id: RequestID?, result: JSONValue) -> String {
        encodeEnvelope(JSONRPCResponse(id: id, result: result), id: id)
    }

    /// Builds a JSON-RPC error response string.
    private func makeErrorResponse(id: RequestID?, code: Int, message: String) -> String {
        let envelope = JSONRPCErrorResponse(
            id: id,
            error: JSONRPCErrorBody(code: code, message: message)
        )
        do {
            let data = try encoder.encode(envelope)
            guard let json = String(data: data, encoding: .utf8) else {
                throw MCPToolError.encodingFailed
            }
            return json
        } catch {
            // Deliberately contains no interpolated data: it must always be valid JSON.
            logStderr("error envelope encode failed: \(error.localizedDescription)")
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error: failed to encode response"}}"#
        }
    }
```

- [ ] **Step 5: Replace `handleToolsList` to use the envelope**

Replace the whole `handleToolsList` method (currently lines 154–182) with:

```swift
    /// Responds to `tools/list` with the full array of tool definitions.
    private func handleToolsList(_ request: JSONRPCRequest) {
        let tools = registry.allDefinitions()
        let line = encodeEnvelope(
            JSONRPCResponse(id: request.id, result: ToolsListResult(tools: tools)),
            id: request.id
        )
        writeLine(line)
        logStderr("Returned \(tools.count) tool definitions")
    }
```

- [ ] **Step 6: Replace the result-encoding tail of `handleToolsCall`**

In `handleToolsCall`, replace everything from `let toolResult = await registry.call(...)` through the end of the method's `do/catch` block (currently lines 213–231) with:

```swift
        let toolResult = await registry.call(tool: toolName, params: arguments)

        let line = encodeEnvelope(
            JSONRPCResponse(id: request.id, result: toolResult),
            id: request.id
        )
        writeLine(line)
        logStderr("Tool \(toolName) completed (isError: \(toolResult.isError ?? false))")
```

(`MCPToolError.encodingFailed` remains referenced by `encodeEnvelope` and `makeErrorResponse` — keep the enum.)

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: PASS, all suites including `JSONRPCEnvelopeTests` (5 tests). `swift build` must show zero warnings — in particular no unused-function warning, which would mean a leftover `encodeID` reference or definition.

- [ ] **Step 8: Commit**

```bash
git add Sources/RemindersCLI/MCPTypes.swift Sources/RemindersCLI/MCPServer.swift Tests/RemindersCLITests/JSONRPCEnvelopeTests.swift
git commit -m "fix: build JSON-RPC envelopes with JSONEncoder to escape all control characters"
```

---

### Task 4: PropertySchema union types

The mutating tools accept `index` as a string OR an integer (`extractIndex` handles both), but the schema declares only `"type": "string"` — an LLM sending a bare integer technically violates the declared schema. JSON Schema expresses this as `"type": ["string", "integer"]`.

**Files:**
- Modify: `Sources/RemindersCLI/MCPTypes.swift` (`PropertySchema`)
- Modify: `Tests/RemindersCLITests/MCPTypesTests.swift` (append a new suite)

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 6): `PropertySchema.init(types: [String], description: String, enum: [String]?)` and internal property `let types: [String]`. The existing `init(type: String, description: String, enum: [String]?)` keeps working — all current call sites compile unchanged.

- [ ] **Step 1: Write the failing tests**

Append to the end of `Tests/RemindersCLITests/MCPTypesTests.swift`:

```swift
// MARK: - PropertySchema Union Type Tests

@Suite("PropertySchema union types")
struct PropertySchemaUnionTests {

    @Test("single type still encodes as a bare string")
    func singleTypeEncodesAsString() throws {
        let prop = PropertySchema(type: "string", description: "A field", enum: nil)
        let data = try JSONEncoder().encode(prop)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["type"] as? String == "string")
    }

    @Test("multiple types encode as a JSON array")
    func multipleTypesEncodeAsArray() throws {
        let prop = PropertySchema(
            types: ["string", "integer"],
            description: "ID or position",
            enum: nil
        )
        let data = try JSONEncoder().encode(prop)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(dict["type"] as? [String] == ["string", "integer"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PropertySchemaUnionTests`
Expected: BUILD FAILURE — no `init(types:description:enum:)` on `PropertySchema`.

- [ ] **Step 3: Replace PropertySchema**

In `Sources/RemindersCLI/MCPTypes.swift`, replace the entire `PropertySchema` struct with:

```swift
/// Schema for a single property within a JSON Schema.
/// `types` holds one or more JSON Schema types; a single entry encodes as a bare
/// string (`"type": "string"`), multiple entries as an array (`"type": ["string", "integer"]`).
struct PropertySchema: Encodable, Sendable {
    let types: [String]
    let description: String
    let `enum`: [String]?

    init(type: String, description: String, enum enumValues: [String]?) {
        self.init(types: [type], description: description, enum: enumValues)
    }

    init(types: [String], description: String, enum enumValues: [String]?) {
        self.types = types
        self.description = description
        self.enum = enumValues
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case `enum`
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if types.count == 1 {
            try container.encode(types[0], forKey: .type)
        } else {
            try container.encode(types, forKey: .type)
        }
        try container.encode(description, forKey: .description)
        if let enumValues = self.enum {
            try container.encode(enumValues, forKey: .enum)
        }
    }
}
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: PASS — including the pre-existing `MCPToolDefinitionTests` (which construct `PropertySchema(type:description:enum:)` and must keep compiling and passing untouched).

- [ ] **Step 5: Commit**

```bash
git add Sources/RemindersCLI/MCPTypes.swift Tests/RemindersCLITests/MCPTypesTests.swift
git commit -m "feat: support JSON Schema type unions in PropertySchema"
```

---

### Task 5: `delete` returns the deleted reminder

`RemindersStore.delete` returns only the title string, so `delete_reminder` is the sole mutating MCP tool that answers with prose (`"Deleted reminder: X"`) instead of JSON. Return the full `ReminderItem` snapshot (captured before removal) and encode it like every other mutating tool.

**Files:**
- Modify: `Sources/RemindersCore/RemindersStore.swift` (`delete` method, lines 278–313)
- Modify: `Sources/RemindersCLI/Commands/DeleteCommand.swift` (`run()`)
- Modify: `Sources/RemindersCLI/MCPServer.swift` (`handleDeleteReminder`)

**Interfaces:**
- Consumes: `mapReminder(_:)`, `resolveReminder(from:at:)` (existing private helpers).
- Produces (used by Task 6's description text): `public func delete(itemAtIndex:onList:includeCompleted:onlyCompleted:) async throws -> ReminderItem` (return type changes from `String`; both in-repo callers are updated in this task — no other consumers exist).

- [ ] **Step 1: Replace `RemindersStore.delete`**

Replace the whole `delete` method (the `// MARK: - Deleting Reminders` section) with:

```swift
    /// Deletes a reminder from a list.
    ///
    /// - Parameters:
    ///   - itemAtIndex: An integer index (as a string) or an external identifier.
    ///   - listName: The name of the list containing the reminder.
    ///   - includeCompleted: Whether to include completed reminders when resolving the index.
    ///   - onlyCompleted: If `true`, only completed reminders are considered when resolving the index.
    /// - Returns: A snapshot of the deleted reminder, captured before removal.
    public func delete(
        itemAtIndex: String,
        onList listName: String,
        includeCompleted: Bool = false,
        onlyCompleted: Bool = false
    ) async throws -> ReminderItem {
        let targetCalendar = try resolveCalendar(named: listName)
        let filtered = try await fetchFilteredEKReminders(
            on: [targetCalendar],
            includeCompleted: includeCompleted,
            onlyCompleted: onlyCompleted
        )
        let (ekReminder, _) = try resolveReminder(from: filtered, at: itemAtIndex)

        // Snapshot before removal: EventKit invalidates the object once it is deleted.
        let deleted = mapReminder(ekReminder)

        do {
            try eventStore.remove(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to delete reminder \"\(deleted.title)\": \(error.localizedDescription)"
            )
        }

        return deleted
    }
```

- [ ] **Step 2: Update DeleteCommand**

In `Sources/RemindersCLI/Commands/DeleteCommand.swift`, replace the body of `run()`'s `withGracefulErrors` closure with:

```swift
            let store = try await makeStore()
            let deleted = try await store.delete(
                itemAtIndex: index,
                onList: listName
            )
            print("Deleted: \(deleted.title)")
```

(CLI stdout is unchanged: still `Deleted: <title>`.)

- [ ] **Step 3: Update the MCP delete handler**

In `Sources/RemindersCLI/MCPServer.swift`, in `handleDeleteReminder`, replace the `do/catch` block with:

```swift
        do {
            let deleted = try await store.delete(itemAtIndex: index, onList: listName)
            let text = prettyEncodeJSON(deleted)
            return .success(text)
        } catch {
            return .error("Failed to delete reminder: \(error.localizedDescription)")
        }
```

- [ ] **Step 4: Verify**

Run: `make check`
Expected: build with zero warnings, all tests pass.

Honest limitation: no unit test can cover this path — it requires a live `EKEventStore` (the missing test seam is a phase-2 backlog item). Live behavior is exercised by the manual MCP smoke session in Task 12.

- [ ] **Step 5: Commit**

```bash
git add Sources/RemindersCore/RemindersStore.swift Sources/RemindersCLI/Commands/DeleteCommand.swift Sources/RemindersCLI/MCPServer.swift
git commit -m "feat: return the full deleted reminder from delete, as JSON over MCP"
```

---

### Task 6: Truthful tool definitions (id addressing, honest index semantics)

The worst audit finding: `show_reminders`'s description promises an `index` field that does not exist in the output, while the genuinely stable `id` field goes unmentioned — so LLMs address reminders by fragile positional indexes computed from field-less output. Also: `uncomplete_reminder` hides that its index space is the *completed-only* view, and mutating tools don't say they can only target reminders visible in their filter view.

**Files:**
- Modify: `Sources/RemindersCLI/MCPServer.swift` (`buildToolDefinitions` — 6 descriptions, 4 index property schemas, and its access level)
- Create: `Tests/RemindersCLITests/ToolDefinitionContentTests.swift`

**Interfaces:**
- Consumes: `PropertySchema(types:description:enum:)` from Task 4; delete-returns-JSON behavior from Task 5.
- Produces: `MCPServer.buildToolDefinitions()` becomes `static` (drops `private`) so tests can call it. Wire contract: tool names, parameter names, and `required` arrays are unchanged.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersCLITests/ToolDefinitionContentTests.swift`:

```swift
// ABOUTME: Guards the truthfulness of MCP tool definitions against actual handler behavior.
// ABOUTME: Locks in stable-id addressing guidance and honest index semantics for LLM clients.

import Foundation
import Testing

@testable import reminders

@Suite("MCP tool definition content")
struct ToolDefinitionContentTests {

    private func definition(named name: String) throws -> MCPToolDefinition {
        try #require(MCPServer.buildToolDefinitions().first { $0.name == name })
    }

    @Test("show_reminders lists the real output fields and no phantom index field")
    func showRemindersDescription() throws {
        let def = try definition(named: "show_reminders")
        #expect(def.description.contains("id, title, notes"))
        #expect(!def.description.contains("index"))
    }

    @Test("show_all_reminders advertises stable-id addressing")
    func showAllRemindersDescription() throws {
        let def = try definition(named: "show_all_reminders")
        #expect(def.description.contains("stable id"))
    }

    @Test("mutating tools accept string or integer for index", arguments: [
        "complete_reminder", "uncomplete_reminder", "delete_reminder", "edit_reminder",
    ])
    func indexAcceptsBothTypes(toolName: String) throws {
        let def = try definition(named: toolName)
        let index = try #require(def.inputSchema.properties?["index"])
        #expect(index.types == ["string", "integer"])
    }

    @Test("mutating tools tell the model to prefer the stable id", arguments: [
        "complete_reminder", "uncomplete_reminder", "delete_reminder", "edit_reminder",
    ])
    func indexDescriptionPrefersID(toolName: String) throws {
        let def = try definition(named: toolName)
        let index = try #require(def.inputSchema.properties?["index"])
        #expect(index.description.contains("stable id"))
    }

    @Test("uncomplete_reminder explains its completed-only index space")
    func uncompleteIndexSpace() throws {
        let def = try definition(named: "uncomplete_reminder")
        #expect(def.description.contains("only_completed"))
    }

    @Test("delete_reminder says it returns the deleted reminder as JSON")
    func deleteReturnsJSON() throws {
        let def = try definition(named: "delete_reminder")
        #expect(def.description.contains("Returns the deleted reminder as JSON"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ToolDefinitionContentTests`
Expected: BUILD FAILURE — `buildToolDefinitions` is inaccessible (`private`). After Step 3's access change alone, the content assertions must FAIL against the old descriptions; both count as red.

- [ ] **Step 3: Make `buildToolDefinitions` testable**

In `Sources/RemindersCLI/MCPServer.swift`, change:

```swift
    private static func buildToolDefinitions() -> [MCPToolDefinition] {
```

to:

```swift
    static func buildToolDefinitions() -> [MCPToolDefinition] {
```

- [ ] **Step 4: Rewrite the six untruthful definitions**

Still in `buildToolDefinitions()`, apply these exact replacements. Tools not listed here (`show_lists`, `add_reminder`, `create_list`) are untouched.

**`show_reminders`** — replace only the `description:` argument with:

```swift
                description: "Show reminders from a specific list. By default only returns "
                    + "incomplete reminders. Use include_completed to also see finished items, "
                    + "or only_completed to see exclusively completed reminders. "
                    + "Returns a JSON array of reminder objects with id, title, notes, "
                    + "isCompleted, completionDate, priority, dueDate, listID, and listName "
                    + "fields. Pass a reminder's id to complete_reminder, uncomplete_reminder, "
                    + "delete_reminder, or edit_reminder to target it reliably.",
```

**`show_all_reminders`** — replace only the `description:` argument with:

```swift
                description: "Show reminders from all lists at once. Each reminder includes its "
                    + "list name. By default only returns incomplete reminders. "
                    + "Useful for getting a full overview of all pending tasks. "
                    + "Returns the same JSON reminder objects as show_reminders; each object's "
                    + "id is a stable identifier accepted by the mutating tools.",
```

**`complete_reminder`** — replace the `description:` argument and the `"index"` property:

```swift
                description: "Mark a reminder as completed. Only incomplete reminders can be "
                    + "targeted. Pass the reminder's stable id (preferred) or its zero-based "
                    + "position among the list's incomplete reminders. Returns the updated "
                    + "reminder as JSON.",
```

```swift
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
                            enum: nil
                        ),
```

**`uncomplete_reminder`** — replace the `description:` argument and the `"index"` property:

```swift
                description: "Mark a completed reminder as incomplete (reopen it). Only completed "
                    + "reminders can be targeted. Pass the reminder's stable id (preferred) or "
                    + "its zero-based position among the COMPLETED reminders only — the view "
                    + "shown by show_reminders with only_completed=true, not the default view. "
                    + "Returns the updated reminder as JSON.",
```

```swift
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred), "
                                + "or its zero-based position among the list's COMPLETED reminders "
                                + "(as listed by show_reminders with only_completed=true).",
                            enum: nil
                        ),
```

**`delete_reminder`** — replace the `description:` argument and the `"index"` property:

```swift
                description: "Permanently delete a reminder from a list. This action cannot be "
                    + "undone. Only incomplete reminders can be targeted. Pass the reminder's "
                    + "stable id (preferred) or its zero-based position among the list's "
                    + "incomplete reminders. Returns the deleted reminder as JSON.",
```

```swift
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
                            enum: nil
                        ),
```

**`edit_reminder`** — replace the `description:` argument and the `"index"` property:

```swift
                description: "Edit an existing reminder's title and/or notes. Only the fields you "
                    + "provide will be changed; omitted fields remain untouched. Only incomplete "
                    + "reminders can be targeted. Pass the reminder's stable id (preferred) or "
                    + "its zero-based position among the list's incomplete reminders. Returns "
                    + "the updated reminder as JSON.",
```

```swift
                        "index": PropertySchema(
                            types: ["string", "integer"],
                            description: "The reminder's stable id from show_reminders (preferred; "
                                + "unaffected by list changes), or its zero-based position among "
                                + "the list's incomplete reminders (fragile: positions shift as "
                                + "reminders change).",
                            enum: nil
                        ),
```

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: PASS — all `ToolDefinitionContentTests` (10 test cases including parameterized) green.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersCLI/MCPServer.swift Tests/RemindersCLITests/ToolDefinitionContentTests.swift
git commit -m "fix: make MCP tool definitions truthful and advertise stable-id addressing"
```

---

### Task 7: Surface authorization failure as a tool error instead of dying

Today `--mcp` calls `makeStore()` before the server loop; if Reminders access is denied the process exits and the MCP client sees an unexplained EOF before the handshake. Move authorization to a lazy per-`tools/call` check: the protocol stream always stays alive, `initialize`/`tools/list` always work, and denial becomes an actionable tool error.

**Files:**
- Modify: `Sources/RemindersCLI/Main.swift` (`run()`)
- Modify: `Sources/RemindersCLI/MCPServer.swift` (`handleToolsCall`)

**Interfaces:**
- Consumes: `encodeEnvelope(_:id:)` and `JSONRPCResponse` from Task 3; `RemindersStore.requestAccess()` (existing — idempotent and cheap once granted: it early-returns on `.fullAccess`).
- Produces: MCP mode no longer requests TCC access at startup. CLI subcommands are untouched (`makeStore()` in `Helpers.swift` stays as-is for them).

- [ ] **Step 1: Stop requesting access at server startup**

In `Sources/RemindersCLI/Main.swift`, replace the `run()` method with:

```swift
    func run() async throws {
        if mcp {
            // Do not request Reminders access up front: a TCC denial here would kill
            // the process before the MCP handshake and the client would only see EOF.
            // MCPServer requests access per tools/call and reports denial as a tool error.
            let store = RemindersStore()
            let server = MCPServer(store: store)
            await server.run()
        } else {
            // No subcommand and no --mcp flag: print help.
            throw CleanExit.helpRequest(self)
        }
    }
```

- [ ] **Step 2: Add the lazy access check to `handleToolsCall`**

In `Sources/RemindersCLI/MCPServer.swift`, in `handleToolsCall`, insert between `logStderr("Calling tool: \(toolName)")` and `let toolResult = await registry.call(...)`:

```swift
        // Reminders access is requested lazily so the protocol stream stays alive even
        // when access is denied; the failure surfaces as an actionable tool error.
        do {
            try await store.requestAccess()
        } catch {
            let denied = MCPToolResult.error(
                "Reminders access is not available: \(error.localizedDescription) "
                + "Grant access in System Settings > Privacy & Security > Reminders "
                + "for the app that launched this MCP server, then call the tool again."
            )
            let line = encodeEnvelope(
                JSONRPCResponse(id: request.id, result: denied),
                id: request.id
            )
            writeLine(line)
            return
        }
```

- [ ] **Step 3: Build and run the suite**

Run: `make check`
Expected: zero warnings, all tests pass.

- [ ] **Step 4: Wire smoke test (no TCC needed)**

`initialize` and `tools/list` now never touch EventKit, so this works even in an unauthorized shell:

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | .build/debug/reminders --mcp 2>/dev/null
```

Expected: exactly two lines of JSON. Line 1 contains `"protocolVersion":"2024-11-05"`; line 2 contains `"show_lists"` and `"type":["string","integer"]`.

Honest limitation: the denied-access branch itself can't be unit- or smoke-tested without revoking this machine's TCC grant or an injectable store (phase-2 seam). The code path is 10 lines and mirrors the tested envelope encoding.

- [ ] **Step 5: Commit**

```bash
git add Sources/RemindersCLI/Main.swift Sources/RemindersCLI/MCPServer.swift
git commit -m "fix: keep MCP protocol alive on Reminders access denial via lazy auth"
```

---

### Task 8: Observe EKEventStoreChanged for data freshness

A long-running MCP server holds one `EKEventStore` for its lifetime. When reminders change externally (Reminders.app, iCloud sync), EventKit posts `.EKEventStoreChanged` and expects the holder to call `refreshSourcesIfNecessary()`; without it, fetches can serve stale snapshots. The CLI path is per-invocation (always a fresh store) and deliberately does not observe.

**Files:**
- Modify: `Sources/RemindersCore/RemindersStore.swift` (new stored property + method)
- Modify: `Sources/RemindersCLI/Main.swift` (call it in MCP mode)
- Create: `scripts/mcp-freshness-smoke.sh`

**Interfaces:**
- Consumes: `UncheckedTransfer` (existing private wrapper in the same file).
- Produces: `public func startObservingExternalChanges()` on `RemindersStore` (idempotent).

- [ ] **Step 1: Create the freshness smoke script**

Create `scripts/mcp-freshness-smoke.sh` (make it executable: `chmod +x scripts/mcp-freshness-smoke.sh`):

```bash
#!/usr/bin/env bash
# ABOUTME: End-to-end smoke test proving a long-running MCP server sees reminders
# ABOUTME: added by another process (EKEventStoreChanged freshness). Needs TCC grant.
#
# Usage: bash scripts/mcp-freshness-smoke.sh
# Exit 0 with "PASS" when the server's second fetch contains the probe reminder.

set -euo pipefail
cd "$(dirname "$0")/.."

BIN=.build/debug/reminders
LIST="MCP Smoke Test"

swift build >/dev/null

# Ensure the target list exists (idempotent; ignore "already exists" style failures).
$BIN new-list "$LIST" >/dev/null 2>&1 || true

FIFO=$(mktemp -u /tmp/mcp-fifo.XXXXXX)
OUT=$(mktemp /tmp/mcp-out.XXXXXX)
mkfifo "$FIFO"

$BIN --mcp < "$FIFO" > "$OUT" 2>/dev/null &
SERVER=$!
exec 3> "$FIFO"

echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"MCP Smoke Test"}}}' >&3
sleep 2

PROBE="Freshness probe $$"
$BIN add "$LIST" $PROBE >/dev/null
sleep 2

echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_reminders","arguments":{"list":"MCP Smoke Test"}}}' >&3
sleep 2

exec 3>&-
wait "$SERVER" 2>/dev/null || true

if grep -q "Freshness probe $$" "$OUT"; then
    echo "PASS: running MCP server saw the externally added reminder"
    STATUS=0
else
    echo "FAIL: probe reminder not visible to the running server; server output:"
    cat "$OUT"
    STATUS=1
fi

rm -f "$FIFO" "$OUT"
exit $STATUS
```

- [ ] **Step 2: Run the smoke script BEFORE implementing (red)**

Run: `bash scripts/mcp-freshness-smoke.sh`
Expected: FAIL (stale second fetch). Caveat, stated honestly: EventKit staleness is timing-dependent — if this unexpectedly PASSES, note that in the task report and proceed anyway; observing `EKEventStoreChanged` + `refreshSourcesIfNecessary()` is Apple's documented requirement for long-running stores regardless. If the script cannot run because the shell lacks a TCC grant (add/show commands error with access denied), record "SKIPPED: no TCC grant in this environment" and continue — Task 12 lists it for Harper's own shell.

- [ ] **Step 3: Add observation to RemindersStore**

In `Sources/RemindersCore/RemindersStore.swift`:

Add to the `// MARK: - Properties` section, after `private let calendar: Calendar`:

```swift
    private var changeObserver: (any NSObjectProtocol)?
```

Insert a new section between `requestAccess()` and `// MARK: - Lists`:

```swift
    // MARK: - Change Observation

    /// Begins refreshing EventKit sources whenever the Calendar database changes.
    ///
    /// Long-running processes (the MCP server) otherwise risk serving stale data:
    /// once `.EKEventStoreChanged` fires, previously fetched objects are invalid and
    /// `refreshSourcesIfNecessary()` must run before new fetches see current state.
    /// Safe to call more than once; only the first call registers. The CLI path is
    /// process-per-invocation and does not need this.
    public func startObservingExternalChanges() {
        guard changeObserver == nil else { return }
        let store = UncheckedTransfer(value: eventStore)
        // `object: nil` avoids sending the non-Sendable EKEventStore across the
        // closure boundary; this process only ever has one event store anyway.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: nil
        ) { _ in
            // EKEventStore is thread-safe; refresh directly on the posting thread.
            store.value.refreshSourcesIfNecessary()
        }
    }
```

- [ ] **Step 4: Wire it up in MCP mode**

In `Sources/RemindersCLI/Main.swift`, inside the `if mcp` branch, add the observation call so the branch reads:

```swift
            let store = RemindersStore()
            await store.startObservingExternalChanges()
            let server = MCPServer(store: store)
            await server.run()
```

(Keep the existing comment about lazy access from Task 7 above these lines.)

- [ ] **Step 5: Build, test, and re-run the smoke (green)**

Run: `make check && bash scripts/mcp-freshness-smoke.sh`
Expected: zero warnings, tests pass, smoke prints `PASS: running MCP server saw the externally added reminder`. Same TCC caveat as Step 2 — record SKIPPED honestly if the environment can't grant access.

Cleanup note: the script leaves a "MCP Smoke Test" list containing probe reminders. Delete the probe via `.build/debug/reminders delete "MCP Smoke Test" 0` if desired; the list itself can only be removed in Reminders.app (no delete-list command exists — that's fine, Task 12 mentions it in the wrap-up report).

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersCore/RemindersStore.swift Sources/RemindersCLI/Main.swift scripts/mcp-freshness-smoke.sh
git commit -m "fix: refresh EventKit sources on external changes in MCP server mode"
```

---

### Task 9: Validate --due-date on show/show-all and unify the format list

`show --due-date tomorow` (typo) silently returns the whole unfiltered list — `filterByDueDate` swallows unparseable dates. Add the same `validate()` guard `add` already has to `show` and `show-all`, and make all date-error messages read from one shared constant (the current `add` message omits `yyyy-MM-dd HH:mm`, which `parseDate` accepts).

**Files:**
- Modify: `Sources/RemindersCLI/DateParsing.swift` (add constant)
- Modify: `Sources/RemindersCLI/Commands/AddCommand.swift` (`validate()`)
- Modify: `Sources/RemindersCLI/Commands/ShowCommand.swift` (`validate()`)
- Modify: `Sources/RemindersCLI/Commands/ShowAllCommand.swift` (`validate()`)
- Modify: `Sources/RemindersCLI/MCPServer.swift` (`handleAddReminder` due_date error)
- Create: `Tests/RemindersCLITests/CommandValidationTests.swift`

**Interfaces:**
- Consumes: `parseDate(_:)` (existing).
- Produces: `let supportedDateFormats: String` (module-internal constant in DateParsing.swift).

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersCLITests/CommandValidationTests.swift`. Note the argument ordering in the `add` test: options must come BEFORE the title words, because `@Argument(parsing: .remaining)` captures everything after the first unrecognized input.

```swift
// ABOUTME: Tests for CLI argument validation of --due-date across show, show-all, and add.
// ABOUTME: Proves unparseable dates are rejected at parse time with the full format list.

import ArgumentParser
import Foundation
import Testing

@testable import reminders

@Suite("Command date validation")
struct CommandValidationTests {

    @Test("show rejects an unparseable --due-date")
    func showRejectsBadDate() {
        #expect(throws: (any Error).self) {
            _ = try ShowCommand.parse(["MyList", "--due-date", "definitely-not-a-date"])
        }
    }

    @Test("show accepts a valid --due-date")
    func showAcceptsGoodDate() throws {
        _ = try ShowCommand.parse(["MyList", "--due-date", "tomorrow"])
    }

    @Test("show-all rejects an unparseable --due-date")
    func showAllRejectsBadDate() {
        #expect(throws: (any Error).self) {
            _ = try ShowAllCommand.parse(["--due-date", "definitely-not-a-date"])
        }
    }

    @Test("show-all accepts a valid --due-date")
    func showAllAcceptsGoodDate() throws {
        _ = try ShowAllCommand.parse(["--due-date", "2026-12-31"])
    }

    @Test("add's rejection message lists every supported format")
    func addErrorListsAllFormats() {
        do {
            _ = try AddCommand.parse(
                ["MyList", "--due-date", "definitely-not-a-date", "Buy", "milk"]
            )
            Issue.record("expected a validation error")
        } catch {
            let message = AddCommand.message(for: error)
            #expect(message.contains("next week"))
            #expect(message.contains("yyyy-MM-dd HH:mm"))
        }
    }

    @Test("show's rejection message lists every supported format")
    func showErrorListsAllFormats() {
        do {
            _ = try ShowCommand.parse(["MyList", "--due-date", "definitely-not-a-date"])
            Issue.record("expected a validation error")
        } catch {
            let message = ShowCommand.message(for: error)
            #expect(message.contains("yyyy-MM-dd HH:mm"))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CommandValidationTests`
Expected: FAIL — `showRejectsBadDate`, `showAllRejectsBadDate`, and `showErrorListsAllFormats` fail (no validation exists on show/show-all yet); `addErrorListsAllFormats` fails on the missing `yyyy-MM-dd HH:mm` substring.

- [ ] **Step 3: Add the shared format constant**

In `Sources/RemindersCLI/DateParsing.swift`, insert after the imports (before the `parseDate` doc comment):

```swift
/// Single source of truth for the date formats accepted by `parseDate`, in the order tried.
/// Every error message that rejects a date string must reference this list.
let supportedDateFormats = "today, tomorrow, next week, yyyy-MM-dd, yyyy-MM-dd HH:mm, MM/dd/yyyy, MM/dd"
```

- [ ] **Step 4: Use it in AddCommand**

In `Sources/RemindersCLI/Commands/AddCommand.swift`, replace the `if let dueDate` block inside `validate()` with:

```swift
        if let dueDate {
            guard parseDate(dueDate) != nil else {
                throw ValidationError(
                    "Could not parse date \"\(dueDate)\". Supported formats: \(supportedDateFormats)."
                )
            }
        }
```

- [ ] **Step 5: Add validation to ShowCommand and ShowAllCommand**

In BOTH `Sources/RemindersCLI/Commands/ShowCommand.swift` and `Sources/RemindersCLI/Commands/ShowAllCommand.swift`, replace the whole `validate()` method with:

```swift
    func validate() throws {
        if onlyCompleted && includeCompleted {
            throw ValidationError(
                "Cannot use --only-completed and --include-completed together."
            )
        }

        if let dueDate {
            guard parseDate(dueDate) != nil else {
                throw ValidationError(
                    "Could not parse date \"\(dueDate)\". Supported formats: \(supportedDateFormats)."
                )
            }
        }
    }
```

- [ ] **Step 6: Use the constant in the MCP add handler**

In `Sources/RemindersCLI/MCPServer.swift`, in `handleAddReminder`, replace the `guard let date = parseDate(dueDateString) else { ... }` error return with:

```swift
            guard let date = parseDate(dueDateString) else {
                return .error(
                    "Invalid due_date \"\(dueDateString)\". Supported formats: \(supportedDateFormats)."
                )
            }
            parsedDueDate = date
```

(Keep the surrounding `if let dueDateString` structure unchanged.)

- [ ] **Step 7: Run the full test suite**

Run: `swift test`
Expected: PASS, including all six `CommandValidationTests`.

- [ ] **Step 8: Commit**

```bash
git add Sources/RemindersCLI/DateParsing.swift Sources/RemindersCLI/Commands/AddCommand.swift Sources/RemindersCLI/Commands/ShowCommand.swift Sources/RemindersCLI/Commands/ShowAllCommand.swift Sources/RemindersCLI/MCPServer.swift Tests/RemindersCLITests/CommandValidationTests.swift
git commit -m "fix: reject unparseable --due-date on show/show-all and unify format lists"
```

---

### Task 10: CLI help text — advertise id addressing and uncomplete's index space

`resolveReminder` has always accepted a stable external identifier as well as an index, but no help text says so. And `uncomplete`'s index counts the *completed-only* view while `show`'s default output numbers the incomplete view — an undocumented trap that deletes the wrong expectation, not the wrong reminder, but still burns users.

**Files:**
- Modify: `Sources/RemindersCLI/Commands/CompleteCommand.swift` (index `@Argument` help)
- Modify: `Sources/RemindersCLI/Commands/UncompleteCommand.swift` (index `@Argument` help + second ABOUTME line)
- Modify: `Sources/RemindersCLI/Commands/DeleteCommand.swift` (index `@Argument` help)
- Modify: `Sources/RemindersCLI/Commands/EditCommand.swift` (index `@Argument` help)
- Create: `Tests/RemindersCLITests/IndexHelpTextTests.swift`

**Interfaces:**
- Consumes: nothing new. Produces: nothing code-visible; help strings only. Argument names and parsing are unchanged.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersCLITests/IndexHelpTextTests.swift`:

```swift
// ABOUTME: Locks CLI help text for index arguments to advertise stable-id addressing.
// ABOUTME: Ensures uncomplete documents its completed-only index space.

import ArgumentParser
import Foundation
import Testing

@testable import reminders

@Suite("Index argument help text")
struct IndexHelpTextTests {

    @Test("complete help advertises id addressing")
    func completeHelp() {
        #expect(CompleteCommand.helpMessage(columns: 500).contains("stable id"))
    }

    @Test("uncomplete help explains the completed-only index space")
    func uncompleteHelp() {
        let help = UncompleteCommand.helpMessage(columns: 500)
        #expect(help.contains("stable id"))
        #expect(help.contains("--only-completed"))
    }

    @Test("delete help advertises id addressing")
    func deleteHelp() {
        #expect(DeleteCommand.helpMessage(columns: 500).contains("stable id"))
    }

    @Test("edit help advertises id addressing")
    func editHelp() {
        #expect(EditCommand.helpMessage(columns: 500).contains("stable id"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IndexHelpTextTests`
Expected: FAIL — all four assertions (current help says only "The index of the reminder to …").

- [ ] **Step 3: Update the four help strings**

In `CompleteCommand.swift`, replace the index argument declaration with:

```swift
    @Argument(help: "The reminder to complete: a zero-based index from `show`, "
        + "or a stable id from `show --format json`.")
    var index: String
```

In `UncompleteCommand.swift`, replace the second ABOUTME line so the header reads:

```swift
// ABOUTME: CLI subcommand that marks a reminder as incomplete.
// ABOUTME: Resolves the index against completed reminders only, or accepts a stable id.
```

and replace the index argument declaration with:

```swift
    @Argument(help: "The reminder to reopen: a zero-based index into the COMPLETED "
        + "reminders (see `show <list> --only-completed`), or a stable id from "
        + "`show --format json`.")
    var index: String
```

In `DeleteCommand.swift`, replace the index argument declaration with:

```swift
    @Argument(help: "The reminder to delete: a zero-based index from `show`, "
        + "or a stable id from `show --format json`.")
    var index: String
```

In `EditCommand.swift`, replace the index argument declaration with:

```swift
    @Argument(help: "The reminder to edit: a zero-based index from `show`, "
        + "or a stable id from `show --format json`.")
    var index: String
```

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: PASS, including all four `IndexHelpTextTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/RemindersCLI/Commands/CompleteCommand.swift Sources/RemindersCLI/Commands/UncompleteCommand.swift Sources/RemindersCLI/Commands/DeleteCommand.swift Sources/RemindersCLI/Commands/EditCommand.swift Tests/RemindersCLITests/IndexHelpTextTests.swift
git commit -m "docs: advertise stable-id addressing and uncomplete's completed-only index space in CLI help"
```

---

### Task 11: README and CLAUDE.md refresh

There is no README at all — the Homebrew tap, the TCC dance, MCP setup, and the index/id addressing model are undocumented. CLAUDE.md's MCP snippet also predates `claude mcp add`.

**Files:**
- Create: `README.md`
- Modify: `CLAUDE.md` (MCP setup section, Test section)

**Interfaces:**
- Consumes: everything this plan built (README documents final behavior: id addressing, JSON delete result, freshness, lazy auth).
- Produces: nothing code-visible.

- [ ] **Step 1: Create README.md**

Full content:

````markdown
# reminders-mcp

CLI for macOS Reminders plus an MCP server, in one binary. A drop-in replacement for
[keith/reminders-cli](https://github.com/keith/reminders-cli) built on EventKit with
Swift 6 async/await (actor-isolated, no semaphores) that also speaks the
Model Context Protocol so LLM clients — Claude Code, Claude Desktop, anything
MCP-capable — can manage your reminders.

## Install

### Homebrew

```sh
brew install harperreed/tap/applereminders
```

The binary installs as `reminders`. Heads up: keith/reminders-cli also installs a
binary named `reminders` — don't install both.

If macOS Gatekeeper blocks the downloaded binary:

```sh
xattr -d com.apple.quarantine "$(which reminders)"
```

### From source

```sh
git clone https://github.com/harperreed/applereminders.git
cd applereminders
make install   # release build into /usr/local/bin (override with PREFIX=...)
```

## Reminders access (TCC)

The first command that touches your reminders triggers the macOS permission prompt.
The grant is recorded against the app that launched the process — your terminal
(Terminal.app, iTerm2, Ghostty, …) for CLI use, or the MCP host app for server use.

- Manage grants: System Settings → Privacy & Security → Reminders
- Reset if stuck: `tccutil reset Reminders` (every app re-prompts on next use)

If access is denied, CLI commands exit with an error on stderr; MCP tool calls
return an error result telling the model how to fix it — the server itself stays up.

## CLI usage

```sh
reminders show-lists                        # list names, one per line
reminders show Groceries                    # incomplete reminders, numbered from 0
reminders show Groceries --only-completed
reminders show Groceries --include-completed
reminders show Groceries --due-date today
reminders show-all                          # every list at once
reminders add Groceries Oat milk            # title = the remaining words
reminders add Groceries -d tomorrow -p high Call the dentist
reminders complete Groceries 0
reminders uncomplete Groceries 0            # index counts COMPLETED reminders only
reminders delete Groceries 2
reminders edit Groceries 1 New title text
reminders edit Groceries 1 -n "new note"
reminders new-list Projects
reminders new-list Projects --source iCloud
```

Put options (`-d`, `-p`, `-n`) **before** the title words in `add` and `edit` —
everything after the first non-option word becomes part of the title.

### Targeting a reminder: index vs id

`complete`, `uncomplete`, `delete`, and `edit` accept either form in the index slot:

- **Zero-based index** from `show` — fragile: positions shift as reminders change.
  `complete`/`delete`/`edit` count the *incomplete* view; `uncomplete` counts the
  *completed* view (`show <list> --only-completed`).
- **Stable id** — the `id` field in `show <list> --format json`. Survives
  reordering; preferred for scripts.

### Dates

`--due-date` / `-d` accepts: `today`, `tomorrow`, `next week`, `yyyy-MM-dd`,
`yyyy-MM-dd HH:mm`, `MM/dd/yyyy`, `MM/dd`. A time component also sets an alarm
at that time. Unparseable dates are rejected up front.

### JSON output

`show`, `show-all`, `show-lists`, and `add` take `--format json`
(pretty-printed, sorted keys, ISO 8601 dates).

## MCP server

Run `reminders --mcp` for JSON-RPC 2.0 over stdio, one message per line.

Claude Code:

```sh
claude mcp add reminders -- "$(which reminders)" --mcp
```

Any other MCP client:

```json
{
  "mcpServers": {
    "reminders": {
      "command": "/opt/homebrew/bin/reminders",
      "args": ["--mcp"]
    }
  }
}
```

### Tools

| Tool | What it does |
|---|---|
| `show_lists` | All reminder lists (id + title) |
| `show_reminders` | Reminders in one list; `include_completed` / `only_completed` flags |
| `show_all_reminders` | Reminders across every list |
| `add_reminder` | Create with title, notes, due date, priority |
| `complete_reminder` | Mark complete (by stable id or index) |
| `uncomplete_reminder` | Reopen (by stable id, or index into the completed view) |
| `delete_reminder` | Delete permanently; returns the deleted reminder as JSON |
| `edit_reminder` | Change title and/or notes |
| `create_list` | Create a new reminder list |

Every reminder object carries a stable `id` — models should pass it back to the
mutating tools instead of positional indexes. The server observes EventKit change
notifications, so edits made in the Reminders app show up without a restart.

## Compatibility with keith/reminders-cli

Core command names and positional index semantics match upstream. Deliberate
additions: `--mcp` mode, stable-id addressing, `edit`, `--include-completed` /
`--only-completed`, `--due-date` filtering. Confirmation strings differ slightly —
check first if you script against exact output.

## Development

```sh
make check    # canonical: swift build + swift test
make build    # debug build
make test     # test suite only
bash scripts/mcp-freshness-smoke.sh   # e2e freshness check (needs TCC grant)
```

Architecture: `RemindersCore` (actor wrapping `EKEventStore`) + a `reminders`
executable (swift-argument-parser CLI and MCP server in one). Agent-facing notes
live in [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
````

- [ ] **Step 2: Verify README claims against the real binary**

Run: `swift build && .build/debug/reminders --help`, then `--help` for each subcommand named in the README (`show-lists`, `show`, `show-all`, `add`, `complete`, `uncomplete`, `delete`, `edit`, `new-list`).
Expected: every flag and argument the README documents appears in the corresponding help output (`-d/--due-date`, `-p/--priority`, `-n/--notes`, `-f/--format`, `--only-completed`, `--include-completed`, `--include-overdue`, `--source`). Fix the README (not the code) if anything mismatches. Live-data commands (e.g. `show-lists`) are best-effort: run them if the shell has a TCC grant; skip with a note if not.

- [ ] **Step 3: Update CLAUDE.md**

Replace this block in `CLAUDE.md`:

````markdown
Add to Claude Code settings:
```json
{
  "mcpServers": {
    "reminders": {
      "command": "/path/to/reminders",
      "args": ["--mcp"]
    }
  }
}
```
````

with:

````markdown
Add to Claude Code:
```bash
claude mcp add reminders -- /path/to/reminders --mcp
```

Other MCP clients use the equivalent JSON config:
```json
{
  "mcpServers": {
    "reminders": {
      "command": "/path/to/reminders",
      "args": ["--mcp"]
    }
  }
}
```
````

And replace the Test section:

````markdown
## Test

```bash
swift test
```
````

with:

````markdown
## Test

```bash
make check   # canonical: build + full test suite
swift test
```
````

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: add README covering install, TCC, CLI reference, and MCP setup"
```

---

### Task 12: Final verification sweep

**Files:** none created; verification only.

- [ ] **Step 1: Full canonical check**

Run: `make check`
Expected: zero warnings, every suite green (JSONRPCEnvelope, PropertySchemaUnion, ToolDefinitionContent, CommandValidation, IndexHelpText, plus pre-existing DateParsing/MCPTypes/Errors/Models).

- [ ] **Step 2: MCP wire smoke (full session)**

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}' \
  | .build/debug/reminders --mcp 2>/dev/null
```

Expected: three JSON lines. Line 2's `show_reminders` description mentions `id, title, notes` and not a phantom index field; the `index` schemas show `"type":["string","integer"]`. Line 3 either lists real reminder lists (TCC granted) or is an `isError` tool result containing "Grant access in System Settings" (TCC denied) — **both are correct outcomes**; the failure mode being a well-formed tool error instead of EOF is exactly what Task 7 built.

- [ ] **Step 3: Freshness smoke**

Run: `bash scripts/mcp-freshness-smoke.sh`
Expected: `PASS`. If the environment has no TCC grant, record SKIPPED and flag it in the final report so Harper can run it from his own shell.

- [ ] **Step 4: Git hygiene**

Run: `git status` (expect clean) and `git log --oneline main..HEAD` (expect ~11 commits matching the tasks above).

- [ ] **Step 5: Report**

Summarize for Harper: what merged-ready looks like, the manual checks that ran vs. were skipped (TCC-dependent ones), the optional `tccutil reset Reminders` re-verification he can run himself (it revokes existing grants — his call), and the leftover "MCP Smoke Test" list if the freshness script ran. Then hand off to the superpowers:finishing-a-development-branch flow (push + PR so CI from Task 1 runs).

---

## Phase 2 Backlog (out of scope for this plan)

Ranked findings from the 2026-07-17 expert-panel audit that this fix pack deliberately defers. Each future plan should pull from the top.

**Important:**
1. **Testability seams** — wrap `EKEventStore` behind a protocol; inject MCPServer's I/O (line source / sink). Unlocks protocol-level e2e tests, the auth-denied test Task 7 couldn't write, unit tests for `delete`-returns-item, and a regression test for the index-mismatch fix in 6bd33e3. (Testing expert; was Critical #7 — partially paid down by this pack's new suites.)
2. **Edit surface** — `ReminderUpdate` (due date set/clear via double-optional, priority, move between lists) exists in Models.swift but nothing calls it. Wire into CLI `edit` and `edit_reminder`, including `include_completed` targeting so completed reminders can be edited/deleted. (API + CLI UX experts.)
3. **MCP due-date filters** — `due_before`/`due_after` (or `due_date` + `include_overdue`) on `show_reminders`/`show_all_reminders`; then remove `filterByDueDate`'s silent unparseable-date fallback (assert instead — validation now guards all entrances). (MCP expert.)
4. **Fetch performance** — use `predicateForIncompleteReminders(withDueDateStarting:ending:)` / `predicateForCompletedReminders` instead of fetching everything and filtering in memory. (EventKit + performance experts.)
5. **Supply chain** — SHA-pin actions in `release.yml`; pass `HOMEBREW_TAP_TOKEN` via header/credential helper instead of embedding in the clone URL; remove `Package.resolved` from `.gitignore` and commit it; ad-hoc codesign (or notarize) release binaries. (Security expert.)
6. **Protocol negotiation** — echo/validate the client's `protocolVersion` in `initialize` instead of hardcoding `2024-11-05`; audit capabilities object. (MCP expert.)
7. **Upstream output compatibility** — decide whether CLI confirmation strings should byte-match keith/reminders-cli (`"Completed 'X'"` vs `"Completed: X"` etc.). Product call for Harper. (CLI UX expert.)
8. **Duplicate list names** — accept a list id anywhere a list name is accepted; document first-match behavior meanwhile. (API expert.)

**Minor:**
9. Tool annotations (`readOnlyHint`, `destructiveHint`), `additionalProperties: false`, optional compact JSON output, pagination for large lists. (MCP expert.)
10. Differentiated exit codes (usage vs. permission vs. not-found). (CLI UX expert.)
11. `make lint` currently just truncates build output — adopt swift-format or SwiftLint. (Tooling.)
12. Date-parsing test determinism: pin timezone/clock, cover DST edges. (Testing expert.)
13. stderr logging redaction — `recv:` logs full request lines including user data; gate behind a debug flag. (Security expert.)
14. CHANGELOG.md + CONTRIBUTING.md; CI build caching (`actions/cache` on `.build`) if CI time hurts. (Docs/tooling.)
