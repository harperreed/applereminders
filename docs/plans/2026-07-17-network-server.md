# Network Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `reminders serve` runs an HTTP server on the tailscale interface exposing MCP over Streamable HTTP at POST /mcp and a REST API under /api/, protected by a bearer token, with launchd agent management.

**Architecture:** A new `RemindersServer` library target holds the moved MCP server plus the Hummingbird 2 HTTP layer (middleware, routes, tailscale discovery, token file, launchd plist). The CLI gains thin `serve` and `agent` subcommands. Both HTTP surfaces and the stdio MCP mode share the same `RemindersStore` actor; REST addressing works by reminder id via new by-id store operations.

**Tech Stack:** Swift 6, Hummingbird 2 (+HummingbirdTesting), swift-argument-parser, EventKit, swift-testing.

**Spec:** `docs/specs/2026-07-17-network-server-design.md` (approved 2026-07-17). Branch: `network-server`.

## Global Constraints

- Swift 6 language mode. Build and tests finish with zero warnings; new warnings are task failures.
- Tests use swift-testing (`@Suite`, `@Test`, `#expect`), never XCTest.
- `make check` is the canonical gate. Run it in every task's final verification step.
- The test suite never triggers TCC. All store tests go through `FakeEventStoreBackend` (Tests/RemindersTestSupport). Never construct `RemindersStore()` with no arguments in tests.
- Every new source file starts with a 2-line `ABOUTME:` comment describing the file.
- No em dashes or en dashes in any file this plan touches. Gate: `grep -rnE '—|–'` on touched files must return nothing.
- Conventional commits, imperative present tense, exact messages given per task.
- Default port 7364 ("REMI" on a phone keypad; verified free and unregistered on this machine 2026-07-17).
- Token file `~/.config/reminders-mcp/token`, mode 600. 401 responses carry an empty body. REST errors 400/404/500 carry `{"error": "message"}`.
- MCP over HTTP is stateless: no `Mcp-Session-Id`, no SSE. GET /mcp and DELETE /mcp return 405. JSON-RPC notifications return 202 with an empty body. Protocol errors (-32700, -32601) are JSON-RPC error envelopes with HTTP 200.
- The HTTP path never logs request bodies, response bodies, or the token. Request logging is one line: method, path, status, duration.
- Hummingbird dependency `from: "2.0.0"` (resolves 2.25.x). Building it needs a Swift 6.1+ toolchain; this machine has 6.2.3. `Package.resolved` gets committed (removed from .gitignore).
- LaunchAgent label `com.harperreed.reminders-mcp`, plist in `~/Library/LaunchAgents/`, logs in `~/Library/Logs/reminders-mcp/`.

## Deviations from the approved spec (flag these at review; Harper approves at plan review)

1. **Module moves the spec implies but does not spell out.** Swift library targets cannot depend on executable targets, so the spec's `RemindersServer` library forces moves: `MCPServer.swift` and `MCPTypes.swift` move from the executable target to `RemindersServer`; `DateParsing.swift` moves to `RemindersCore` (CLI, MCP, and REST all need it). Their tests move to matching test targets.
2. **By-id lookup without a new backend member.** The spec says `EventStoreBackend` gains one id-lookup member. This plan instead fetches via the existing predicate members and matches identifiers in the store. Reasons: production ids are external identifiers, so a faithful EventKit point lookup needs two APIs (`calendarItems(withExternalIdentifier:)` and `calendarItem(withIdentifier:)`) plus branching inside the deliberately logic-free backend seam; the fetch-and-match path keeps one source of truth for id matching (the same matcher the index paths use) and runs identically under the fake and EventKit. Cost: by-id operations fetch all reminders per call, fine at personal-database scale.
3. **By-id never falls back to index.** `resolveReminder` treats an integer string as an index. REST ids must not: `PATCH /api/reminders/3` has to 404, not mutate whatever sits at position 3. The by-id path matches identifiers only.

## File map

| File | Task | Change |
| --- | --- | --- |
| Sources/RemindersCore/DateParsing.swift | 1 | moved from CLI, made public |
| Tests/RemindersCoreTests/DateParsingTests.swift | 1 | moved, import swap |
| Package.swift | 2, 5 | new targets, then Hummingbird |
| Sources/RemindersServer/MCPServer.swift | 2, 3 | moved, public surface; per-message entry point |
| Sources/RemindersServer/MCPTypes.swift | 2 | moved verbatim |
| Sources/RemindersCLI/Main.swift | 2, 11, 12 | import, new subcommands |
| Tests/RemindersServerTests/ (7 moved files) | 2 | moved, import swap |
| Tests/RemindersServerTests/MCPMessageEntryPointTests.swift | 3 | new |
| Sources/RemindersCore/RemindersStore.swift | 4 | by-id operations, shared helpers |
| Tests/RemindersCoreTests/ReminderByIDStoreTests.swift | 4 | new |
| .gitignore, Package.resolved | 5 | resolved file committed |
| Sources/RemindersServer/ServerMiddleware.swift | 5 | new (4 middlewares + RESTError) |
| Sources/RemindersServer/HTTPJSON.swift | 5 | new (JSON response helpers) |
| Tests/RemindersServerTests/MiddlewareTests.swift | 5 | new |
| Sources/RemindersServer/TokenFile.swift | 6 | new |
| Tests/RemindersServerTests/TokenFileTests.swift | 6 | new |
| Sources/RemindersServer/TailscaleInterface.swift | 7 | new |
| Tests/RemindersServerTests/TailscaleInterfaceTests.swift | 7 | new |
| Sources/RemindersServer/RemindersServerApp.swift | 8, 9, 10 | new; routes accrete |
| Tests/RemindersServerTests/ServerTestSupport.swift | 8 | new |
| Tests/RemindersServerTests/RESTReadEndpointTests.swift | 8 | new |
| Tests/RemindersServerTests/RESTWriteEndpointTests.swift | 9 | new |
| Tests/RemindersServerTests/MCPOverHTTPTests.swift | 10 | new |
| Sources/RemindersCLI/Commands/ServeCommand.swift | 11 | new |
| Tests/RemindersCLITests/ServeCommandValidationTests.swift | 11 | new |
| Sources/RemindersServer/LaunchAgentPlist.swift | 12 | new |
| Tests/RemindersServerTests/LaunchAgentPlistTests.swift | 12 | new |
| Sources/RemindersCLI/Commands/AgentCommand.swift | 12 | new |
| scripts/serve-smoke.sh | 13 | new |
| README.md, CLAUDE.md | 13 | new sections |

Verified Hummingbird 2 facts used throughout (from source at tag 2.25.1): `Response(status:headers:body:)` with defaults; `ResponseBody init()` and `init(byteBuffer:)`; `ByteBuffer(string:)`; `RouterMiddleware` protocol with `handle(_:context:next:)`; `router.group("api")` returns a `RouterGroup` whose `add(middleware:)` scopes middleware to that group's routes and whose `.get("reminders", use:)` registers `GET /api/reminders`; path parameters use `:id` and read via `context.parameters.get("id")`; query parameters via `request.uri.queryParameters.get("key")` (values are Substring-like, convert with `String($0)`); body via `request.body.collect(upTo: context.maxUploadSize)`; test client via `app.test(.router) { client in client.execute(uri:method:headers:body:) { response in ... } }`; `Application(router:configuration:)` with `ApplicationConfiguration(address: .hostname(_:port:))`; `try await app.runService()`.

---

### Task 1: Move date parsing into RemindersCore

The CLI, the MCP server (moving to a library in Task 2), and the REST layer all need `parseDate` and the due filters. Library targets cannot import the executable, so this code moves down into `RemindersCore`.

**Files:**
- Move: `Sources/RemindersCLI/DateParsing.swift` -> `Sources/RemindersCore/DateParsing.swift`
- Move: `Tests/RemindersCLITests/DateParsingTests.swift` -> `Tests/RemindersCoreTests/DateParsingTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (public API in RemindersCore, used by CLI commands, MCPServer, and Tasks 8-9): `public let supportedDateFormats: String`, `public func parseDate(_ string: String) -> Date?`, `public func filterByDueWindow(_ reminders: [ReminderItem], dueBefore: Date?, dueAfter: Date?, calendar: Calendar = .current) -> [ReminderItem]`, `public func filterByDueDate(_ reminders: [ReminderItem], dueDate: Date?, includeOverdue: Bool) -> [ReminderItem]`.

- [ ] **Step 1: Move the files with git mv**

```bash
cd /Users/harper/Public/src/personal/applereminders
git mv Sources/RemindersCLI/DateParsing.swift Sources/RemindersCore/DateParsing.swift
git mv Tests/RemindersCLITests/DateParsingTests.swift Tests/RemindersCoreTests/DateParsingTests.swift
```

- [ ] **Step 2: Edit Sources/RemindersCore/DateParsing.swift**

Three changes, nothing else:

1. Replace the two ABOUTME lines (the file no longer belongs to the CLI layer):

```swift
// ABOUTME: Date parsing and due-date filtering helpers shared by the CLI, MCP, and REST surfaces.
// ABOUTME: Supports multiple human-friendly date formats and due-window filtering.
```

2. Delete the line `import RemindersCore` (the file now lives inside that module; keep `import Foundation`).

3. Add `public` to all four top-level declarations:

```swift
public let supportedDateFormats = "today, tomorrow, next week, yyyy-MM-dd, yyyy-MM-dd HH:mm, MM/dd/yyyy, MM/dd"
```

```swift
public func parseDate(_ string: String) -> Date? {
```

```swift
public func filterByDueWindow(
    _ reminders: [ReminderItem],
    dueBefore: Date?,
    dueAfter: Date?,
    calendar: Calendar = .current
) -> [ReminderItem] {
```

```swift
public func filterByDueDate(
    _ reminders: [ReminderItem],
    dueDate: Date?,
    includeOverdue: Bool
) -> [ReminderItem] {
```

All function bodies, doc comments, and the rest of the file stay byte-identical.

- [ ] **Step 3: Edit Tests/RemindersCoreTests/DateParsingTests.swift**

Replace the line `@testable import reminders` with `@testable import RemindersCore`. Keep every other import and all test bodies unchanged.

- [ ] **Step 4: Build and run the full suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build succeeds with zero warnings; all tests pass. The CLI commands (`AddCommand`, `ShowCommand`, `ShowAllCommand`, `EditCommand`) and `MCPServer.swift` already `import RemindersCore`, so the now-public functions resolve without edits to those files.

If the compiler reports `parseDate` (or a filter) not found in some CLI file, that file is missing `import RemindersCore`; add that import line. Do not re-add the functions anywhere.

- [ ] **Step 5: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings.

- [ ] **Step 6: Commit**

```bash
git add -A Sources/RemindersCLI Sources/RemindersCore Tests/RemindersCLITests Tests/RemindersCoreTests
git commit -m "refactor: move date parsing into RemindersCore"
```

---

### Task 2: Extract the MCP server into a RemindersServer library target

Creates the library target the spec's server needs, moves the MCP server and its wire types there, and moves the MCP-coupled tests to a new test target. Pure restructuring: no behavior change.

**Files:**
- Modify: `Package.swift`
- Move: `Sources/RemindersCLI/MCPServer.swift` -> `Sources/RemindersServer/MCPServer.swift`
- Move: `Sources/RemindersCLI/MCPTypes.swift` -> `Sources/RemindersServer/MCPTypes.swift`
- Modify: `Sources/RemindersCLI/Main.swift`
- Move (7 files): `Tests/RemindersCLITests/{MCPServerHarness,MCPServerE2ETests,MCPTypesTests,MCPDueFilterTests,MCPEditToolTests,JSONRPCEnvelopeTests,ToolDefinitionContentTests}.swift` -> `Tests/RemindersServerTests/`

**Interfaces:**
- Consumes: `RemindersStore` (public, RemindersCore).
- Produces (used by Task 3, 10, 11): `public actor MCPServer` with `public typealias OutputWriter = @Sendable (String) -> Void`, `public init(store: RemindersStore, input: AsyncThrowingStream<String, Error>? = nil, output: OutputWriter? = nil)`, `public func run() async`. Everything else in the two moved files stays internal.

- [ ] **Step 1: Move the source files**

```bash
mkdir -p Sources/RemindersServer
git mv Sources/RemindersCLI/MCPServer.swift Sources/RemindersServer/MCPServer.swift
git mv Sources/RemindersCLI/MCPTypes.swift Sources/RemindersServer/MCPTypes.swift
```

- [ ] **Step 2: Move the test files**

```bash
mkdir -p Tests/RemindersServerTests
git mv Tests/RemindersCLITests/MCPServerHarness.swift Tests/RemindersServerTests/
git mv Tests/RemindersCLITests/MCPServerE2ETests.swift Tests/RemindersServerTests/
git mv Tests/RemindersCLITests/MCPTypesTests.swift Tests/RemindersServerTests/
git mv Tests/RemindersCLITests/MCPDueFilterTests.swift Tests/RemindersServerTests/
git mv Tests/RemindersCLITests/MCPEditToolTests.swift Tests/RemindersServerTests/
git mv Tests/RemindersCLITests/JSONRPCEnvelopeTests.swift Tests/RemindersServerTests/
git mv Tests/RemindersCLITests/ToolDefinitionContentTests.swift Tests/RemindersServerTests/
```

- [ ] **Step 3: Replace Package.swift targets and products sections**

Replace the whole file with:

```swift
// swift-tools-version: 6.0
// ABOUTME: Swift package manifest for reminders-mcp.
// ABOUTME: Defines a CLI tool wrapping EventKit with MCP server support.
import PackageDescription

let package = Package(
    name: "reminders-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reminders", targets: ["reminders"]),
        .library(name: "RemindersCore", targets: ["RemindersCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "RemindersCore",
            linkerSettings: [
                .linkedFramework("EventKit"),
            ]
        ),
        .target(
            name: "RemindersServer",
            dependencies: [
                "RemindersCore",
            ]
        ),
        .executableTarget(
            name: "reminders",
            dependencies: [
                "RemindersCore",
                "RemindersServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/RemindersCLI",
            exclude: [
                "Resources/Info.plist",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/RemindersCLI/Resources/Info.plist",
                ]),
            ]
        ),
        .target(
            name: "RemindersTestSupport",
            dependencies: ["RemindersCore"],
            path: "Tests/RemindersTestSupport"
        ),
        .testTarget(
            name: "RemindersCoreTests",
            dependencies: ["RemindersCore", "RemindersTestSupport"]
        ),
        .testTarget(
            name: "RemindersServerTests",
            dependencies: ["RemindersServer", "RemindersTestSupport"]
        ),
        .testTarget(
            name: "RemindersCLITests",
            dependencies: ["reminders", "RemindersTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 4: Widen the MCPServer public surface**

In `Sources/RemindersServer/MCPServer.swift`, make exactly these four declarations public (bodies unchanged):

- `actor MCPServer {` becomes `public actor MCPServer {`
- `typealias OutputWriter = @Sendable (String) -> Void` becomes `public typealias OutputWriter = @Sendable (String) -> Void`
- `init(` (the three-parameter initializer) becomes `public init(`
- `func run() async {` becomes `public func run() async {`

`ToolRegistry`, everything in `MCPTypes.swift`, and all private members stay as they are. The `writeLine` method keeps its `private nonisolated` modifiers exactly (a previous review restored `nonisolated` there; do not drop it).

- [ ] **Step 5: Import RemindersServer in Main.swift**

In `Sources/RemindersCLI/Main.swift`, add `import RemindersServer` after `import RemindersCore`:

```swift
import ArgumentParser
import Foundation
import RemindersCore
import RemindersServer
```

- [ ] **Step 6: Swap the test imports**

In each of the 7 files now in `Tests/RemindersServerTests/`, replace the line `@testable import reminders` with `@testable import RemindersServer`. Touch nothing else. If a build error then shows a moved test file using a RemindersCore type without importing it, add `import RemindersCore` to that file (transitive imports are not re-exported).

- [ ] **Step 7: Verify nothing MCP-shaped is left in the CLI target**

Run: `grep -rn "MCPServer\|JSONValue\|MCPTool" Sources/RemindersCLI/`
Expected: matches only in `Main.swift` (the `import RemindersServer` line and the `MCPServer(store: store)` construction). Any other match means a CLI file depends on moved internals; stop and report it rather than widening more access levels.

- [ ] **Step 8: Build and test**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: zero warnings, all suites pass, and the test list now shows `RemindersServerTests` executing the moved MCP suites.

- [ ] **Step 9: Run the canonical gate**

Run: `make check`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add -A Package.swift Sources Tests
git commit -m "refactor: extract MCP server into RemindersServer library"
```

---

### Task 3: Per-message entry point on MCPServer

The HTTP transport needs to hand one JSON-RPC message in and get one response line (or nothing, for notifications) back, without touching stdio. Today dispatch writes lines as a side effect. This task makes every handler return its response line and adds the entry point; the stdio loop becomes a thin consumer of it.

**Files:**
- Modify: `Sources/RemindersServer/MCPServer.swift`
- Create: `Tests/RemindersServerTests/MCPMessageEntryPointTests.swift`

**Interfaces:**
- Consumes: Task 2's public `MCPServer` init.
- Produces (used by Task 10's HTTP glue, internal to the module): `func response(forMessageData data: Data) async -> String?` on `MCPServer`. Returns `nil` exactly when the message needs no response (notifications, including unknown-method messages without an id). Parse errors return a `-32700` envelope string; unknown methods with an id return `-32601`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersServerTests/MCPMessageEntryPointTests.swift`:

```swift
// ABOUTME: Tests for MCPServer's per-message entry point used by HTTP transports.
// ABOUTME: Covers request/notification/parse-error/unknown-method outcomes without stdio.

import Foundation
import RemindersCore
import RemindersTestSupport
import Testing
@testable import RemindersServer

@Suite("MCP per-message entry point")
struct MCPMessageEntryPointTests {

    /// Builds a server whose stdio seams are inert: the entry point is called
    /// directly, so the input stream is pre-finished and output is discarded.
    private func makeServer() -> MCPServer {
        let backend = FakeEventStoreBackend()
        let store = RemindersStore(backend: backend)
        let input = AsyncThrowingStream<String, Error> { continuation in
            continuation.finish()
        }
        return MCPServer(store: store, input: input, output: { _ in })
    }

    @Test func initializeRequestReturnsResponseLine() async throws {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        let line = try #require(response)
        #expect(line.contains("protocolVersion"))
        #expect(line.contains("\"id\":1"))
    }

    @Test func notificationReturnsNil() async {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        #expect(response == nil)
    }

    @Test func parseErrorReturnsMinus32700() async throws {
        let server = makeServer()
        let response = await server.response(forMessageData: Data("this is not json".utf8))
        let line = try #require(response)
        #expect(line.contains("-32700"))
    }

    @Test func unknownMethodWithIdReturnsMinus32601() async throws {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","id":7,"method":"no/such/method"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        let line = try #require(response)
        #expect(line.contains("-32601"))
        #expect(line.contains("\"id\":7"))
    }

    @Test func unknownMethodWithoutIdReturnsNil() async {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","method":"no/such/method"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        #expect(response == nil)
    }

    @Test func toolsListReturnsDefinitions() async throws {
        let server = makeServer()
        let message = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let response = await server.response(forMessageData: Data(message.utf8))
        let line = try #require(response)
        #expect(line.contains("show_lists"))
    }
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `swift test --filter MCPMessageEntryPointTests 2>&1 | tail -5`
Expected: FAIL to compile, error like `value of type 'MCPServer' has no member 'response'`.

- [ ] **Step 3: Refactor MCPServer dispatch to return response lines**

In `Sources/RemindersServer/MCPServer.swift`:

1. Replace the two ABOUTME lines at the top with:

```swift
// ABOUTME: MCP server actor that handles JSON-RPC 2.0 messages one at a time.
// ABOUTME: Runs a stdio loop for --mcp mode; HTTP transports call the per-message entry point.
```

2. Replace the whole `run()` method body (the `// MARK: - Main Loop` section) with:

```swift
    /// Runs the server, reading lines from the injected line stream (stdin by default) until EOF.
    ///
    /// Uses an async line stream to avoid blocking the cooperative thread pool
    /// (unlike `readLine()` which is synchronous).
    public func run() async {
        logStderr("reminders-mcp server starting")

        do {
            for try await line in input {
                guard !line.isEmpty else { continue }

                logStderr("recv: \(line)")

                if let response = await response(forMessageData: Data(line.utf8)) {
                    writeLine(response)
                }
            }
        } catch {
            logStderr("stdin read error: \(error.localizedDescription)")
        }

        logStderr("reminders-mcp server shutting down (stdin closed)")
    }

    // MARK: - Per-Message Entry Point

    /// Handles one raw JSON-RPC message and returns the response line, or `nil`
    /// when the message requires no response (notifications). HTTP transports
    /// call this directly; the stdio loop feeds it line by line. Never logs the
    /// message body: transports own their logging policy.
    func response(forMessageData data: Data) async -> String? {
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: data)
        } catch {
            logStderr("JSON parse error: \(error)")
            return makeErrorResponse(
                id: nil,
                code: -32700,
                message: "Parse error: \(error.localizedDescription)"
            )
        }
        return await response(to: request)
    }
```

3. Replace the whole `// MARK: - Request Dispatch` section (`handleRequest`) with:

```swift
    // MARK: - Request Dispatch

    /// Routes a JSON-RPC request to its handler and returns the response line,
    /// or `nil` for notifications.
    private func response(to request: JSONRPCRequest) async -> String? {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "notifications/initialized":
            // Notification: no response required.
            logStderr("Client initialized notification received")
            return nil
        case "ping":
            return handlePing(request)
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return await handleToolsCall(request)
        case "resources/list":
            return handleResourcesList(request)
        case "prompts/list":
            return handlePromptsList(request)
        default:
            logStderr("Unknown method: \(request.method)")
            guard request.id != nil else { return nil }
            return makeErrorResponse(
                id: request.id,
                code: -32601,
                message: "Method not found: \(request.method)"
            )
        }
    }
```

4. Convert each handler from writing to returning. Exact replacements:

`handleInitialize` (return type added, `writeLine` dropped):

```swift
    /// Responds to the `initialize` method with server capabilities.
    private func handleInitialize(_ request: JSONRPCRequest) -> String {
        let result: [String: JSONValue] = [
            "protocolVersion": .string("2024-11-05"),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string("reminders-mcp"),
                "version": .string("1.0.0"),
            ]),
        ]
        logStderr("Initialized with protocol version 2024-11-05")
        return makeSuccessResponse(id: request.id, result: .object(result))
    }
```

`handlePing`:

```swift
    /// Responds to the `ping` method with an empty result.
    private func handlePing(_ request: JSONRPCRequest) -> String {
        logStderr("Responded to ping")
        return makeSuccessResponse(id: request.id, result: .object([:]))
    }
```

`handleToolsList`:

```swift
    /// Responds to `tools/list` with the full array of tool definitions.
    private func handleToolsList(_ request: JSONRPCRequest) -> String {
        let tools = registry.allDefinitions()
        logStderr("Returned \(tools.count) tool definitions")
        return encodeEnvelope(
            JSONRPCResponse(id: request.id, result: ToolsListResult(tools: tools)),
            id: request.id
        )
    }
```

`handleToolsCall` (each `writeLine(x); return` pair becomes `return x`; the final write becomes the return value):

```swift
    /// Handles `tools/call` by extracting the tool name and arguments, then dispatching
    /// to the registry.
    private func handleToolsCall(_ request: JSONRPCRequest) async -> String {
        guard let params = request.params?.objectValue() else {
            return makeErrorResponse(
                id: request.id,
                code: -32602,
                message: "Invalid params: expected an object with 'name' and optional 'arguments'"
            )
        }

        guard let toolName = params["name"]?.stringValue() else {
            return makeErrorResponse(
                id: request.id,
                code: -32602,
                message: "Invalid params: missing required 'name' field"
            )
        }

        let arguments = params["arguments"]?.objectValue() ?? [:]

        logStderr("Calling tool: \(toolName)")

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
            return encodeEnvelope(
                JSONRPCResponse(id: request.id, result: denied),
                id: request.id
            )
        }

        let toolResult = await registry.call(tool: toolName, params: arguments)

        logStderr("Tool \(toolName) completed (isError: \(toolResult.isError ?? false))")
        return encodeEnvelope(
            JSONRPCResponse(id: request.id, result: toolResult),
            id: request.id
        )
    }
```

`handleResourcesList` and `handlePromptsList`:

```swift
    /// Responds to `resources/list` with an empty array (future-proofing).
    private func handleResourcesList(_ request: JSONRPCRequest) -> String {
        let result: [String: JSONValue] = ["resources": .array([])]
        logStderr("Returned empty resources list")
        return makeSuccessResponse(id: request.id, result: .object(result))
    }

    /// Responds to `prompts/list` with an empty array (future-proofing).
    private func handlePromptsList(_ request: JSONRPCRequest) -> String {
        let result: [String: JSONValue] = ["prompts": .array([])]
        logStderr("Returned empty prompts list")
        return makeSuccessResponse(id: request.id, result: .object(result))
    }
```

Nothing else changes: `encodeEnvelope`, `makeSuccessResponse`, `makeErrorResponse`, `writeLine` (still `private nonisolated`), `logStderr`, the registry builders, and all tool handlers stay untouched. Note the log lines moved above the return in each handler but their text is identical.

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter MCPMessageEntryPointTests 2>&1 | tail -5`
Expected: 6 tests PASS.

- [ ] **Step 5: Run the whole suite (stdio behavior must be unchanged)**

Run: `make check`
Expected: PASS, zero warnings. The existing `MCPServerE2ETests` and `JSONRPCEnvelopeTests` exercise the stdio loop through the harness; them passing proves wire behavior survived the refactor.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersServer/MCPServer.swift Tests/RemindersServerTests/MCPMessageEntryPointTests.swift
git commit -m "feat: add per-message entry point to MCPServer"
```

### Task 4: By-id reminder operations on RemindersStore

REST addresses reminders by the stable id in `ReminderItem.id`, across all lists, with no index fallback. The mutation logic already exists in the index-based methods; this task extracts it into shared private helpers so both paths stay one source of truth, then adds four public by-id methods. Deviations 2 and 3 from the plan header apply here.

**Files:**
- Modify: `Sources/RemindersCore/RemindersStore.swift`
- Create: `Tests/RemindersCoreTests/ReminderByIDStoreTests.swift`

**Interfaces:**
- Consumes: existing private members `fetchFilteredEKReminders(on:includeCompleted:onlyCompleted:)`, `mapReminder(_:)`, `resolveReminder(from:at:)`, `backend.saveReminder/removeReminder`.
- Produces (used by Task 9's REST handlers): `public func reminder(byID id: String) async throws -> ReminderItem`, `public func update(byID id: String, with update: ReminderUpdate) async throws -> ReminderItem`, `public func setCompleted(byID id: String, completed: Bool) async throws -> ReminderItem`, `public func delete(byID id: String) async throws -> ReminderItem`. Unknown ids throw `RemindersError.reminderNotFound(id)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersCoreTests/ReminderByIDStoreTests.swift`. Note the id round-trip: the fake's reminders are unsaved `EKReminder` objects, so `mapReminder` falls back to `calendarItemIdentifier`; tests obtain ids by fetching through the store first.

```swift
// ABOUTME: Tests for RemindersStore's by-id operations used by the REST surface.
// ABOUTME: Verifies cross-list lookup, no index fallback, and mutation parity with index paths.

import EventKit
import Foundation
import RemindersTestSupport
import Testing
@testable import RemindersCore

@Suite("By-id store operations")
struct ReminderByIDStoreTests {

    private func makeSeededStore() -> (backend: FakeEventStoreBackend, store: RemindersStore) {
        let backend = FakeEventStoreBackend()
        let chores = backend.addCalendar(named: "Chores")
        let errands = backend.addCalendar(named: "Errands")
        backend.addReminder(title: "Sweep", in: chores)
        backend.addReminder(title: "Mail letter", in: errands)
        backend.addReminder(title: "Old task", in: errands, isCompleted: true)
        return (backend, RemindersStore(backend: backend))
    }

    /// Fetches the store-visible id for the reminder with the given title.
    private func id(of title: String, in store: RemindersStore) async throws -> String {
        let all = try await store.reminders(includeCompleted: true)
        let item = try #require(all.first { $0.title == title })
        return item.id
    }

    @Test func reminderByIDFindsAcrossLists() async throws {
        let (_, store) = makeSeededStore()
        let mailID = try await id(of: "Mail letter", in: store)
        let item = try await store.reminder(byID: mailID)
        #expect(item.title == "Mail letter")
        #expect(item.listName == "Errands")
    }

    @Test func reminderByIDIncludesCompleted() async throws {
        let (_, store) = makeSeededStore()
        let oldID = try await id(of: "Old task", in: store)
        let item = try await store.reminder(byID: oldID)
        #expect(item.isCompleted)
    }

    @Test func unknownIDThrowsReminderNotFound() async throws {
        let (_, store) = makeSeededStore()
        await #expect(throws: RemindersError.reminderNotFound("no-such-id")) {
            try await store.reminder(byID: "no-such-id")
        }
    }

    @Test func numericStringIsNeverAnIndex() async throws {
        // resolveReminder treats "0" as position 0; the by-id path must not.
        let (backend, store) = makeSeededStore()
        await #expect(throws: RemindersError.reminderNotFound("0")) {
            try await store.update(byID: "0", with: ReminderUpdate(title: "Hijacked"))
        }
        #expect(backend.savedReminders.isEmpty)
    }

    @Test func updateByIDChangesTitleAndSaves() async throws {
        let (backend, store) = makeSeededStore()
        let sweepID = try await id(of: "Sweep", in: store)
        let updated = try await store.update(byID: sweepID, with: ReminderUpdate(title: "Sweep porch"))
        #expect(updated.title == "Sweep porch")
        #expect(backend.savedReminders.count == 1)
    }

    @Test func updateByIDClearsDueDate() async throws {
        let (backend, store) = makeSeededStore()
        let due = DateComponents(year: 2030, month: 1, day: 15)
        let calendar = try #require(backend.currentReminders.first?.calendar)
        backend.addReminder(title: "Dated", in: calendar, dueDateComponents: due)
        let datedID = try await id(of: "Dated", in: store)
        let updated = try await store.update(byID: datedID, with: ReminderUpdate(dueDate: .some(nil)))
        #expect(updated.dueDate == nil)
    }

    @Test func setCompletedByIDRoundTrips() async throws {
        let (_, store) = makeSeededStore()
        let sweepID = try await id(of: "Sweep", in: store)
        let done = try await store.setCompleted(byID: sweepID, completed: true)
        #expect(done.isCompleted)
        #expect(done.completionDate != nil)
        let undone = try await store.setCompleted(byID: sweepID, completed: false)
        #expect(!undone.isCompleted)
        #expect(undone.completionDate == nil)
    }

    @Test func deleteByIDReturnsSnapshotAndRemoves() async throws {
        let (backend, store) = makeSeededStore()
        let mailID = try await id(of: "Mail letter", in: store)
        let deleted = try await store.delete(byID: mailID)
        #expect(deleted.title == "Mail letter")
        #expect(backend.removedReminders.count == 1)
        let remaining = try await store.reminders(includeCompleted: true)
        #expect(!remaining.contains { $0.id == mailID })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ReminderByIDStoreTests 2>&1 | tail -5`
Expected: FAIL to compile, `value of type 'RemindersStore' has no member 'reminder'` (and siblings).

- [ ] **Step 3: Extract shared helpers and add the by-id methods**

All edits in `Sources/RemindersCore/RemindersStore.swift`.

1. In `resolveReminder(from:at:)`, replace the identifier-matching block (the comment starting `// Accept either identifier:` through its `return`) with:

```swift
        guard let matchIndex = reminders.firstIndex(where: {
            reminderMatches($0, identifier: indexOrID)
        }) else {
            throw RemindersError.reminderNotFound(indexOrID)
        }
        return (reminders[matchIndex], matchIndex)
```

2. Directly below `resolveReminder`, add the shared matcher and the by-id fetch:

```swift
    /// Whether `identifier` names this reminder. Accepts either identifier:
    /// mapReminder emits the external identifier when EventKit has assigned
    /// one and the item identifier otherwise, so both must round-trip back
    /// to the same reminder.
    private func reminderMatches(_ reminder: EKReminder, identifier: String) -> Bool {
        reminder.calendarItemExternalIdentifier == identifier
            || reminder.calendarItemIdentifier == identifier
    }

    /// Fetches a reminder by identifier across all lists, completed included.
    ///
    /// Identifiers only: unlike index resolution, a purely numeric string here
    /// is an identifier that matches nothing, never a position. REST ids must
    /// not alias list indexes.
    private func fetchEKReminder(byID id: String) async throws -> EKReminder {
        let all = try await fetchFilteredEKReminders(
            on: nil,
            includeCompleted: true,
            onlyCompleted: false
        )
        guard let match = all.first(where: { reminderMatches($0, identifier: id) }) else {
            throw RemindersError.reminderNotFound(id)
        }
        return match
    }
```

3. Replace the body of `setComplete(_:itemAtIndex:onList:includeCompleted:onlyCompleted:)` after the `resolveReminder` line (mutation, save, return) so the method reads:

```swift
    public func setComplete(
        _ complete: Bool,
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
        return try applyCompletion(complete, to: ekReminder)
    }
```

4. Same shape for `update(itemAtIndex:onList:with:includeCompleted:onlyCompleted:)` (doc comment unchanged):

```swift
    public func update(
        itemAtIndex: String,
        onList listName: String,
        with update: ReminderUpdate,
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
        return try applyAndSave(update, to: ekReminder)
    }
```

5. Same shape for `delete(itemAtIndex:onList:includeCompleted:onlyCompleted:)`:

```swift
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
        return try removeAndSnapshot(ekReminder)
    }
```

6. After `delete`, add a new section with the extracted mutation helpers. Their bodies are the code lifted verbatim from the three methods above, error wording included:

```swift
    // MARK: - Shared Mutation Helpers

    /// Sets the completion flag (and matching completion date), saves, and maps.
    private func applyCompletion(_ complete: Bool, to ekReminder: EKReminder) throws -> ReminderItem {
        ekReminder.isCompleted = complete
        if complete {
            ekReminder.completionDate = Date()
        } else {
            ekReminder.completionDate = nil
        }

        do {
            try backend.saveReminder(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to update completion status: \(error.localizedDescription)"
            )
        }

        return mapReminder(ekReminder)
    }

    /// Applies the fields present in `update` to `ekReminder`, saves, and maps.
    private func applyAndSave(_ update: ReminderUpdate, to ekReminder: EKReminder) throws -> ReminderItem {
        if let title = update.title {
            ekReminder.title = title
        }
        if let notes = update.notes {
            ekReminder.notes = notes
        }
        if let priority = update.priority {
            ekReminder.priority = priority.eventKitValue
        }
        if let newListName = update.listName {
            ekReminder.calendar = try resolveCalendar(named: newListName)
        }
        if let isCompleted = update.isCompleted {
            ekReminder.isCompleted = isCompleted
            ekReminder.completionDate = isCompleted ? Date() : nil
        }
        if let dueDateChange = update.dueDate {
            // Alarms track the due date; clear stale ones on any due-date change.
            for alarm in ekReminder.alarms ?? [] {
                ekReminder.removeAlarm(alarm)
            }
            if let newDate = dueDateChange {
                ekReminder.dueDateComponents = calendarComponents(from: newDate)
                let hour = calendar.component(.hour, from: newDate)
                let minute = calendar.component(.minute, from: newDate)
                if hour != 0 || minute != 0 {
                    ekReminder.addAlarm(EKAlarm(absoluteDate: newDate))
                }
            } else {
                ekReminder.dueDateComponents = nil
            }
        }

        do {
            try backend.saveReminder(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to update reminder: \(error.localizedDescription)"
            )
        }

        return mapReminder(ekReminder)
    }

    /// Snapshots the reminder, removes it, and returns the snapshot.
    private func removeAndSnapshot(_ ekReminder: EKReminder) throws -> ReminderItem {
        // Snapshot before removal: EventKit invalidates the object once it is deleted.
        let deleted = mapReminder(ekReminder)

        do {
            try backend.removeReminder(ekReminder, commit: true)
        } catch {
            throw RemindersError.operationFailed(
                "Failed to delete reminder \"\(deleted.title)\": \(error.localizedDescription)"
            )
        }

        return deleted
    }
```

If the exact bodies in the current file differ from the lifted code above (for example a changed error string), copy the file's current text into the helper instead; the file is the source of truth and the full suite pins the wording.

7. After the shared helpers, add the public by-id surface:

```swift
    // MARK: - By-ID Operations (REST surface)

    /// Fetches a single reminder by identifier, searching every list.
    public func reminder(byID id: String) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return mapReminder(ekReminder)
    }

    /// Applies a partial update to the reminder with the given identifier.
    public func update(byID id: String, with update: ReminderUpdate) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return try applyAndSave(update, to: ekReminder)
    }

    /// Marks the reminder with the given identifier complete or incomplete.
    public func setCompleted(byID id: String, completed: Bool) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return try applyCompletion(completed, to: ekReminder)
    }

    /// Deletes the reminder with the given identifier and returns its snapshot.
    public func delete(byID id: String) async throws -> ReminderItem {
        let ekReminder = try await fetchEKReminder(byID: id)
        return try removeAndSnapshot(ekReminder)
    }
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter ReminderByIDStoreTests 2>&1 | tail -5`
Expected: 8 tests PASS.

- [ ] **Step 5: Run the full gate (extraction must not shift index-path behavior)**

Run: `make check`
Expected: PASS, zero warnings. The existing `RemindersStoreTests` and MCP edit-tool tests run the index paths through the extracted helpers and pin the error wording.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersCore/RemindersStore.swift Tests/RemindersCoreTests/ReminderByIDStoreTests.swift
git commit -m "feat: add by-id reminder operations to RemindersStore"
```

---

### Task 5: Hummingbird dependency and HTTP middleware

Adds the Hummingbird 2 dependency (committing `Package.resolved` to pin the tree, per spec decision 4) and the middleware pieces plus JSON response helpers. Middleware is testable against throwaway routers before any real routes exist.

**Files:**
- Modify: `Package.swift`, `.gitignore`
- Commit: `Package.resolved` (newly tracked)
- Create: `Sources/RemindersServer/HTTPJSON.swift`
- Create: `Sources/RemindersServer/ServerMiddleware.swift`
- Create: `Tests/RemindersServerTests/MiddlewareTests.swift`

**Interfaces:**
- Consumes: `RemindersError` cases (RemindersCore), `RemindersStore.requestAccess()`.
- Produces (used by Tasks 8-10, all internal to RemindersServer): `struct RESTError: Error { let status: HTTPResponse.Status; let message: String }`; `BearerTokenMiddleware<Context>(token: String)`; `RequestLogMiddleware<Context>(log: @Sendable (String) -> Void)`; `RESTErrorMiddleware<Context>()`; `RemindersAccessMiddleware<Context>(store: RemindersStore)`; `func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response`; `func errorResponse(status: HTTPResponse.Status, message: String) throws -> Response`.

- [ ] **Step 1: Add the dependency**

In `Package.swift` add to the `dependencies` array:

```swift
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
```

In the `RemindersServer` target, change `dependencies` to:

```swift
            dependencies: [
                "RemindersCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
```

In the `RemindersServerTests` test target, change `dependencies` to:

```swift
            dependencies: [
                "RemindersServer",
                "RemindersTestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
```

- [ ] **Step 2: Track Package.resolved**

Delete the line `Package.resolved` from `.gitignore`, then:

```bash
swift package resolve
git add .gitignore Package.swift Package.resolved
```

Expected: resolve fetches hummingbird 2.25.x plus its swift-nio tree with no errors.

- [ ] **Step 3: Write the failing middleware tests**

Create `Tests/RemindersServerTests/MiddlewareTests.swift`:

```swift
// ABOUTME: Unit tests for the HTTP middleware stack.
// ABOUTME: Exercises bearer auth, request logging, and REST error mapping on a throwaway router.

import Foundation
import Hummingbird
import HummingbirdTesting
import RemindersCore
import Testing
@testable import RemindersServer

@Suite("HTTP middleware")
struct MiddlewareTests {

    /// Thread-safe capture target for RequestLogMiddleware output.
    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.withLock { _lines } }
        func append(_ line: String) { lock.withLock { _lines.append(line) } }
    }

    /// A minimal app with the production middleware order: log wraps auth
    /// (401s get logged too); the /api group carries error mapping.
    private func makeApp(log: @escaping @Sendable (String) -> Void = { _ in }) -> some ApplicationProtocol {
        let router = Router()
        router.middlewares.add(RequestLogMiddleware(log: log))
        router.middlewares.add(BearerTokenMiddleware(token: "secret"))
        router.get("ping") { _, _ in "pong" }
        let api = router.group("api")
        api.add(middleware: RESTErrorMiddleware())
        api.get("missing-list") { _, _ -> Response in
            throw RemindersError.listNotFound("Nope")
        }
        api.get("store-failure") { _, _ -> Response in
            throw RemindersError.operationFailed("Failed to update reminder: disk full")
        }
        api.get("bad-request") { _, _ -> Response in
            throw RESTError(
                status: .badRequest,
                message: "Invalid completed \"maybe\". Must be one of: false, all, only."
            )
        }
        return Application(router: router)
    }

    private let goodHeaders: HTTPFields = [.authorization: "Bearer secret"]

    @Test func missingTokenGets401WithEmptyBody() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    @Test func wrongTokenGets401() async throws {
        let app = makeApp()
        let headers: HTTPFields = [.authorization: "Bearer nope"]
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get, headers: headers) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func correctTokenPassesThrough() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body) == "pong")
            }
        }
    }

    @Test func notFoundStoreErrorMapsTo404JSON() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/missing-list", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .notFound)
                let body = String(buffer: response.body)
                #expect(body.contains("\"error\""))
                #expect(body.contains("List not found"))
            }
        }
    }

    @Test func storeFailureMapsTo500JSON() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/store-failure", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .internalServerError)
                #expect(String(buffer: response.body).contains("Failed to update reminder"))
            }
        }
    }

    @Test func restErrorCarriesItsStatusAndMessage() async throws {
        let app = makeApp()
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/bad-request", method: .get, headers: goodHeaders) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("Must be one of: false, all, only"))
            }
        }
    }

    @Test func logLineCarriesMethodPathStatusAndNoBody() async throws {
        let box = LogBox()
        let app = makeApp(log: { box.append($0) })
        try await app.test(.router) { client in
            try await client.execute(uri: "/ping", method: .get, headers: goodHeaders) { _ in }
        }
        let line = try #require(box.lines.first)
        #expect(line.contains("GET"))
        #expect(line.contains("/ping"))
        #expect(line.contains("200"))
        #expect(!line.contains("pong"))
        #expect(!line.contains("secret"))
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --filter MiddlewareTests 2>&1 | tail -5`
Expected: FAIL to compile, `cannot find 'RequestLogMiddleware' in scope` (and siblings). The first run also builds hummingbird from source; that one-time build takes several minutes.

- [ ] **Step 5: Implement the JSON helpers**

Create `Sources/RemindersServer/HTTPJSON.swift`:

```swift
// ABOUTME: JSON response helpers for the HTTP surface.
// ABOUTME: Encodes payloads and {"error": message} bodies with ISO-8601 dates.

import Foundation
import Hummingbird
import NIOCore

/// The error body shape for REST 400/404/500 responses (spec error mapping).
struct ErrorBody: Encodable {
    let error: String
}

/// Encodes `value` as JSON (ISO-8601 dates, sorted keys, matching the MCP
/// payload conventions) and wraps it in an HTTP response.
func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw RESTError(status: .internalServerError, message: "Failed to encode response")
    }
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string: json))
    )
}

/// Builds the {"error": message} response for a failed REST request.
func errorResponse(status: HTTPResponse.Status, message: String) throws -> Response {
    try jsonResponse(ErrorBody(error: message), status: status)
}
```

- [ ] **Step 6: Implement the middleware**

Create `Sources/RemindersServer/ServerMiddleware.swift`:

```swift
// ABOUTME: HTTP middleware for the network server: bearer auth, request logging,
// ABOUTME: REST error mapping, and lazy Reminders access requests.

import Foundation
import Hummingbird
import RemindersCore

/// A REST-surface failure carrying its HTTP status and message.
struct RESTError: Error {
    let status: HTTPResponse.Status
    let message: String
}

/// Rejects any request whose Authorization header does not carry the expected
/// bearer token. 401 responses have an empty body by design (spec R4); both
/// the MCP and REST surfaces sit behind this one middleware.
struct BearerTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard request.headers[.authorization] == "Bearer \(token)" else {
            return Response(status: .unauthorized)
        }
        return try await next(request, context)
    }
}

/// Logs one line per request: method, path, status, duration. Never logs
/// bodies or the Authorization header (spec R9).
struct RequestLogMiddleware<Context: RequestContext>: RouterMiddleware {
    let log: @Sendable (String) -> Void

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await next(request, context)
        let elapsed = start.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        log("\(request.method) \(request.uri.path) \(response.status.code) \(String(format: "%.1f", milliseconds))ms")
        return response
    }
}

/// Maps errors thrown by REST handlers onto the spec's JSON error bodies:
/// not-found store errors to 404, other store errors to 500, RESTError to its
/// own status, anything unexpected to 500.
struct RESTErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as RESTError {
            return try errorResponse(status: error.status, message: error.message)
        } catch let error as RemindersError {
            switch error {
            case .listNotFound, .reminderNotFound:
                return try errorResponse(status: .notFound, message: error.localizedDescription)
            case .accessDenied, .writeOnlyAccess, .operationFailed:
                return try errorResponse(status: .internalServerError, message: error.localizedDescription)
            }
        } catch {
            return try errorResponse(status: .internalServerError, message: error.localizedDescription)
        }
    }
}

/// Requests Reminders access lazily per request, so the server starts without
/// TCC interaction and denial surfaces as a JSON 500 (via RESTErrorMiddleware)
/// instead of killing the process.
struct RemindersAccessMiddleware<Context: RequestContext>: RouterMiddleware {
    let store: RemindersStore

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        try await store.requestAccess()
        return try await next(request, context)
    }
}
```

Check the `RemindersError` case list against `Sources/RemindersCore/RemindersError.swift` before compiling; the switch must stay exhaustive without a `default`.

- [ ] **Step 7: Run the middleware tests**

Run: `swift test --filter MiddlewareTests 2>&1 | tail -5`
Expected: 7 tests PASS. If the compiler cannot find `ByteBuffer` despite the `NIOCore` import, or the `HTTPFields` literals fail to infer, stop and report the exact error; do not switch to unverified constructors.

- [ ] **Step 8: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings (including none from dependency resolution).

- [ ] **Step 9: Commit**

```bash
git add .gitignore Package.swift Package.resolved Sources/RemindersServer/HTTPJSON.swift Sources/RemindersServer/ServerMiddleware.swift Tests/RemindersServerTests/MiddlewareTests.swift
git commit -m "feat: add Hummingbird dependency and HTTP middleware"
```

---

### Task 6: Bearer token file management

Implements spec R5: token at `~/.config/reminders-mcp/token`, mode 600, generated once, never silently overwritten.

**Files:**
- Create: `Sources/RemindersServer/TokenFile.swift`
- Create: `Tests/RemindersServerTests/TokenFileTests.swift`

**Interfaces:**
- Consumes: Foundation only.
- Produces (used by Task 11's ServeCommand): `public enum TokenFile` with `static var defaultPath: String`, `static func load(from path: String) throws -> String`, `static func generate(at path: String) throws -> String`; `public enum TokenFileError: LocalizedError, Equatable` with cases `missing(String)`, `empty(String)`, `alreadyExists(String)`, `writeFailed(String)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersServerTests/TokenFileTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TokenFileTests 2>&1 | tail -5`
Expected: FAIL to compile, `cannot find 'TokenFile' in scope`.

- [ ] **Step 3: Implement TokenFile**

Create `Sources/RemindersServer/TokenFile.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TokenFileTests 2>&1 | tail -5`
Expected: 7 tests PASS.

- [ ] **Step 5: Run the canonical gate**

Run: `make check`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersServer/TokenFile.swift Tests/RemindersServerTests/TokenFileTests.swift
git commit -m "feat: add bearer token file management"
```

---

### Task 7: Tailscale interface discovery

Implements spec R3's discovery half: find the machine's tailscale IPv4 address (CGNAT range 100.64.0.0/10) from the system interface list. The decision logic is pure and unit-tested; only the `getifaddrs` enumeration touches the live system.

**Files:**
- Create: `Sources/RemindersServer/TailscaleInterface.swift`
- Create: `Tests/RemindersServerTests/TailscaleInterfaceTests.swift`

**Interfaces:**
- Consumes: Darwin (`getifaddrs`, `getnameinfo`).
- Produces (used by Task 11's ServeCommand): `public struct NetworkInterface: Sendable, Equatable { let name: String; let address: String }`, `public func systemInterfaces() -> [NetworkInterface]`, `public func firstTailscaleAddress(in: [NetworkInterface]) -> String?`, `public func resolveBindHost(override: String?, interfaces: [NetworkInterface]) throws -> String`, `public enum BindResolutionError: LocalizedError, Equatable { case noTailscaleInterface }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersServerTests/TailscaleInterfaceTests.swift`:

```swift
// ABOUTME: Tests for tailscale interface discovery and bind host resolution.
// ABOUTME: Pure functions get injected interface lists; no live network dependency.

import Foundation
import Testing
@testable import RemindersServer

@Suite("Tailscale interface discovery")
struct TailscaleInterfaceTests {

    @Test func findsFirstCGNATAddress() {
        let interfaces = [
            NetworkInterface(name: "lo0", address: "127.0.0.1"),
            NetworkInterface(name: "en0", address: "192.168.1.20"),
            NetworkInterface(name: "utun4", address: "100.101.102.103"),
            NetworkInterface(name: "utun5", address: "100.99.1.2"),
        ]
        #expect(firstTailscaleAddress(in: interfaces) == "100.101.102.103")
    }

    @Test func matchesByAddressRangeNotInterfaceName() {
        // A utun interface outside the CGNAT range (another VPN) must not match.
        let interfaces = [
            NetworkInterface(name: "utun0", address: "10.8.0.2"),
            NetworkInterface(name: "weird0", address: "100.64.0.1"),
        ]
        #expect(firstTailscaleAddress(in: interfaces) == "100.64.0.1")
    }

    @Test func cgnatRangeEdges() {
        #expect(isTailscaleAddress("100.64.0.1"))
        #expect(isTailscaleAddress("100.127.255.254"))
        #expect(!isTailscaleAddress("100.63.255.255"))
        #expect(!isTailscaleAddress("100.128.0.1"))
        #expect(!isTailscaleAddress("10.0.0.1"))
        #expect(!isTailscaleAddress("not-an-ip"))
        #expect(!isTailscaleAddress("100.64.0"))
        #expect(!isTailscaleAddress("100.300.0.1"))
    }

    @Test func noTailscaleInterfaceReturnsNil() {
        let interfaces = [
            NetworkInterface(name: "lo0", address: "127.0.0.1"),
            NetworkInterface(name: "en0", address: "192.168.1.20"),
        ]
        #expect(firstTailscaleAddress(in: interfaces) == nil)
    }

    @Test func bindOverrideWins() throws {
        #expect(try resolveBindHost(override: "127.0.0.1", interfaces: []) == "127.0.0.1")
    }

    @Test func missingTailscaleThrowsActionableError() {
        let interfaces = [NetworkInterface(name: "en0", address: "192.168.0.5")]
        #expect(throws: BindResolutionError.noTailscaleInterface) {
            try resolveBindHost(override: nil, interfaces: interfaces)
        }
        #expect(
            BindResolutionError.noTailscaleInterface.localizedDescription.contains("--bind")
        )
    }

    @Test func systemInterfacesIncludesLoopback() {
        // getifaddrs smoke test: every macOS machine has lo0 at 127.0.0.1.
        let interfaces = systemInterfaces()
        #expect(interfaces.contains { $0.name == "lo0" && $0.address == "127.0.0.1" })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TailscaleInterfaceTests 2>&1 | tail -5`
Expected: FAIL to compile, `cannot find 'NetworkInterface' in scope`.

- [ ] **Step 3: Implement discovery**

Create `Sources/RemindersServer/TailscaleInterface.swift`:

```swift
// ABOUTME: Tailscale interface discovery: finds the machine's CGNAT-range IPv4 address.
// ABOUTME: The server binds to this address by default so only the tailnet reaches it (spec R3).

import Darwin
import Foundation

/// One IPv4 interface address from the system interface list.
public struct NetworkInterface: Sendable, Equatable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }
}

/// True when `address` sits in tailscale's CGNAT range, 100.64.0.0/10 (first
/// octet 100, second octet 64 through 127). Matching by address range rather
/// than interface name survives utun renumbering and other VPNs.
func isTailscaleAddress(_ address: String) -> Bool {
    let octets = address.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4 else { return false }
    return octets[0] == 100 && (64...127).contains(octets[1])
}

/// Returns the first tailscale address in `interfaces`, or nil when the
/// machine has none.
public func firstTailscaleAddress(in interfaces: [NetworkInterface]) -> String? {
    interfaces.first { isTailscaleAddress($0.address) }?.address
}

/// The failure when no tailscale interface exists and no override was given.
public enum BindResolutionError: LocalizedError, Equatable {
    case noTailscaleInterface

    public var errorDescription: String? {
        "No tailscale interface found (no IPv4 address in 100.64.0.0/10). "
            + "Start tailscale, or pass --bind to listen on another interface."
    }
}

/// Resolves the bind host: an explicit override wins; otherwise the first
/// tailscale address; otherwise a descriptive error (spec R3).
public func resolveBindHost(override: String?, interfaces: [NetworkInterface]) throws -> String {
    if let override {
        return override
    }
    guard let tailscale = firstTailscaleAddress(in: interfaces) else {
        throw BindResolutionError.noTailscaleInterface
    }
    return tailscale
}

/// Enumerates the system's IPv4 interface addresses via getifaddrs.
public func systemInterfaces() -> [NetworkInterface] {
    var addresses: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addresses) == 0 else { return [] }
    defer { freeifaddrs(addresses) }

    var result: [NetworkInterface] = []
    var cursor = addresses
    while let entry = cursor?.pointee {
        defer { cursor = entry.ifa_next }
        guard let socketAddress = entry.ifa_addr,
              socketAddress.pointee.sa_family == sa_family_t(AF_INET) else {
            continue
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            socketAddress,
            socklen_t(socketAddress.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard status == 0 else { continue }
        result.append(
            NetworkInterface(
                name: String(cString: entry.ifa_name),
                address: String(cString: host)
            )
        )
    }
    return result
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter TailscaleInterfaceTests 2>&1 | tail -5`
Expected: 7 tests PASS.

- [ ] **Step 5: Run the canonical gate**

Run: `make check`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersServer/TailscaleInterface.swift Tests/RemindersServerTests/TailscaleInterfaceTests.swift
git commit -m "feat: add tailscale interface discovery"
```

---

### Task 8: Application builder and REST read endpoints

Creates the router/application builder with the middleware wired in production order, plus the two read endpoints: `GET /api/lists` and `GET /api/reminders` with `list`, `completed`, `due_before`, `due_after` query parameters. Write endpoints and /mcp arrive in Tasks 9-10 by extending `buildRouter`.

**Files:**
- Create: `Sources/RemindersServer/RemindersServerApp.swift`
- Create: `Tests/RemindersServerTests/ServerTestSupport.swift`
- Create: `Tests/RemindersServerTests/RESTReadEndpointTests.swift`

**Interfaces:**
- Consumes: Task 5 middleware plus `jsonResponse`/`RESTError`; Task 1's `parseDate`, `filterByDueWindow`, `supportedDateFormats`; `store.lists()` (non-throwing) and `store.reminders(inList:includeCompleted:onlyCompleted:)`. Note: the store's `includeCompleted` defaults to `true`, but REST defaults to incomplete-only, so handlers always pass both flags explicitly.
- Produces: `public struct ServerConfiguration { host: String; port: Int; token: String }`; `public func buildApplication(store: RemindersStore, configuration: ServerConfiguration) -> some ApplicationProtocol` (Task 11); internal `func buildRouter(store: RemindersStore, token: String, log: @escaping @Sendable (String) -> Void = defaultHTTPLog) -> Router<BasicRequestContext>` (Tasks 9-10 extend it; tests build apps from it); internal `struct RESTQuery` with `value(_ key: String) -> String?` and `dateValue(_ key: String) throws -> Date?`; `public let defaultHTTPLog: @Sendable (String) -> Void`. Test target gains `makeTestStore()`, `makeTestApp(store:)`, `testToken`, `authHeaders`, `decodeBody(_:from:)`.

- [ ] **Step 1: Write the shared test support**

Create `Tests/RemindersServerTests/ServerTestSupport.swift`:

```swift
// ABOUTME: Shared helpers for HTTP endpoint tests in RemindersServerTests.
// ABOUTME: Builds an in-memory app over FakeEventStoreBackend; no TCC involved.

import Foundation
import Hummingbird
import HummingbirdTesting
import RemindersCore
import RemindersTestSupport
@testable import RemindersServer

/// Bearer token used by every endpoint test.
let testToken = "test-token"

/// Headers carrying the valid bearer token.
let authHeaders: HTTPFields = [.authorization: "Bearer test-token"]

/// A fake backend plus a store reading from it.
func makeTestStore() -> (backend: FakeEventStoreBackend, store: RemindersStore) {
    let backend = FakeEventStoreBackend()
    return (backend, RemindersStore(backend: backend))
}

/// Builds the app under test with request logging silenced.
func makeTestApp(store: RemindersStore) -> some ApplicationProtocol {
    Application(router: buildRouter(store: store, token: testToken, log: { _ in }))
}

/// Decodes a JSON response body using the server's date convention.
func decodeBody<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(String(buffer: response.body).utf8))
}
```

- [ ] **Step 2: Write the failing endpoint tests**

Create `Tests/RemindersServerTests/RESTReadEndpointTests.swift`:

```swift
// ABOUTME: End-to-end tests for GET /api/lists and GET /api/reminders.
// ABOUTME: In-memory Hummingbird test client over the fake backend; covers filters and errors.

import Foundation
import Hummingbird
import HummingbirdTesting
import RemindersCore
import RemindersTestSupport
import Testing
@testable import RemindersServer

@Suite("REST read endpoints")
struct RESTReadEndpointTests {

    @Test func listsReturnsAllLists() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        backend.addCalendar(named: "Groceries")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/lists", method: .get, headers: authHeaders) { response in
                #expect(response.status == .ok)
                let lists = try decodeBody([ReminderList].self, from: response)
                #expect(lists.map(\.title) == ["Chores", "Groceries"])
            }
        }
    }

    @Test func listsWithoutTokenGets401() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/lists", method: .get) { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    @Test func remindersDefaultToIncompleteAcrossAllLists() async throws {
        let (backend, store) = makeTestStore()
        let chores = backend.addCalendar(named: "Chores")
        let errands = backend.addCalendar(named: "Errands")
        backend.addReminder(title: "Sweep", in: chores)
        backend.addReminder(title: "Mail letter", in: errands)
        backend.addReminder(title: "Done already", in: errands, isCompleted: true)
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/reminders", method: .get, headers: authHeaders) { response in
                #expect(response.status == .ok)
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title).sorted() == ["Mail letter", "Sweep"])
            }
        }
        #expect(backend.lastFetchKind == .incomplete)
    }

    @Test func remindersFilterByList() async throws {
        let (backend, store) = makeTestStore()
        let chores = backend.addCalendar(named: "Chores")
        let errands = backend.addCalendar(named: "Errands")
        backend.addReminder(title: "Sweep", in: chores)
        backend.addReminder(title: "Mail letter", in: errands)
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/reminders?list=Chores", method: .get, headers: authHeaders) { response in
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title) == ["Sweep"])
            }
        }
    }

    @Test func listNameWithSpaceWorks() async throws {
        let (backend, store) = makeTestStore()
        let spaced = backend.addCalendar(named: "My Errands")
        backend.addReminder(title: "Mail letter", in: spaced)
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/reminders?list=My%20Errands", method: .get, headers: authHeaders) { response in
                #expect(response.status == .ok)
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title) == ["Mail letter"])
            }
        }
    }

    @Test func completedAllAndOnlyControlTheFetch() async throws {
        let (backend, store) = makeTestStore()
        let chores = backend.addCalendar(named: "Chores")
        backend.addReminder(title: "Open", in: chores)
        backend.addReminder(title: "Closed", in: chores, isCompleted: true)
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/reminders?completed=all", method: .get, headers: authHeaders) { response in
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title).sorted() == ["Closed", "Open"])
            }
            try await client.execute(uri: "/api/reminders?completed=only", method: .get, headers: authHeaders) { response in
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title) == ["Closed"])
            }
        }
    }

    @Test func invalidCompletedValueIs400() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/reminders?completed=maybe", method: .get, headers: authHeaders) { response in
                #expect(response.status == .badRequest)
                let body = String(buffer: response.body)
                #expect(body.contains("Must be one of: false, all, only"))
            }
        }
    }

    @Test func unknownListIs404() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/api/reminders?list=Nope", method: .get, headers: authHeaders) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body).contains("List not found"))
            }
        }
    }

    @Test func dueWindowFiltersAndRejectsGarbage() async throws {
        let (backend, store) = makeTestStore()
        let chores = backend.addCalendar(named: "Chores")
        backend.addReminder(
            title: "Soon",
            in: chores,
            dueDateComponents: DateComponents(year: 2030, month: 1, day: 15)
        )
        backend.addReminder(
            title: "Later",
            in: chores,
            dueDateComponents: DateComponents(year: 2030, month: 6, day: 15)
        )
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders?due_before=2030-03-01",
                method: .get,
                headers: authHeaders
            ) { response in
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title) == ["Soon"])
            }
            try await client.execute(
                uri: "/api/reminders?due_before=banana",
                method: .get,
                headers: authHeaders
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("Supported formats"))
            }
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter RESTReadEndpointTests 2>&1 | tail -5`
Expected: FAIL to compile, `cannot find 'buildRouter' in scope` (via ServerTestSupport).

- [ ] **Step 4: Implement the app builder and read routes**

Create `Sources/RemindersServer/RemindersServerApp.swift`:

```swift
// ABOUTME: Hummingbird application builder for the network server.
// ABOUTME: Wires middleware and routes for the MCP and REST surfaces (spec R1-R4).

import Foundation
import Hummingbird
import RemindersCore

/// Everything the HTTP server needs to start.
public struct ServerConfiguration: Sendable {
    public let host: String
    public let port: Int
    public let token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }
}

/// Writes HTTP request log lines to stderr, keeping stdout clean for CLI use.
public let defaultHTTPLog: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data("[HTTP] \(line)\n".utf8))
}

/// Query string access with percent decoding and CLI-format date parsing.
struct RESTQuery {
    let request: Request

    /// Returns the decoded query value. Decoding twice only mangles list names
    /// containing a literal percent-escape sequence, which is acceptable; not
    /// decoding at all would break every list name containing a space.
    func value(_ key: String) -> String? {
        guard let raw = request.uri.queryParameters.get(key) else { return nil }
        let string = String(raw)
        return string.removingPercentEncoding ?? string
    }

    /// Parses a date query parameter in the CLI formats; garbage is a 400.
    func dateValue(_ key: String) throws -> Date? {
        guard let string = value(key) else { return nil }
        guard let date = parseDate(string) else {
            throw RESTError(
                status: .badRequest,
                message: "Invalid \(key) \"\(string)\". Supported formats: \(supportedDateFormats)."
            )
        }
        return date
    }
}

/// Builds the router with both surfaces behind bearer auth.
func buildRouter(
    store: RemindersStore,
    token: String,
    log: @escaping @Sendable (String) -> Void = defaultHTTPLog
) -> Router<BasicRequestContext> {
    let router = Router()
    // Global middleware: logging wraps auth so 401s get logged too.
    router.middlewares.add(RequestLogMiddleware(log: log))
    router.middlewares.add(BearerTokenMiddleware(token: token))

    let api = router.group("api")
    // Error mapping wraps the access request so a TCC denial becomes a JSON 500.
    api.add(middleware: RESTErrorMiddleware())
    api.add(middleware: RemindersAccessMiddleware(store: store))

    api.get("lists") { _, _ -> Response in
        let lists = await store.lists()
        return try jsonResponse(lists)
    }

    api.get("reminders") { request, _ -> Response in
        let query = RESTQuery(request: request)
        let completed = query.value("completed") ?? "false"
        let (includeCompleted, onlyCompleted): (Bool, Bool)
        switch completed {
        case "false":
            (includeCompleted, onlyCompleted) = (false, false)
        case "all":
            (includeCompleted, onlyCompleted) = (true, false)
        case "only":
            (includeCompleted, onlyCompleted) = (true, true)
        default:
            throw RESTError(
                status: .badRequest,
                message: "Invalid completed \"\(completed)\". Must be one of: false, all, only."
            )
        }
        let dueBefore = try query.dateValue("due_before")
        let dueAfter = try query.dateValue("due_after")
        let items = try await store.reminders(
            inList: query.value("list"),
            includeCompleted: includeCompleted,
            onlyCompleted: onlyCompleted
        )
        return try jsonResponse(filterByDueWindow(items, dueBefore: dueBefore, dueAfter: dueAfter))
    }

    return router
}

/// Builds the servable application (spec R1).
public func buildApplication(
    store: RemindersStore,
    configuration: ServerConfiguration
) -> some ApplicationProtocol {
    Application(
        router: buildRouter(store: store, token: configuration.token),
        configuration: ApplicationConfiguration(
            address: .hostname(configuration.host, port: configuration.port)
        )
    )
}
```

Check `RemindersStore.reminders(inList:...)`'s actual parameter labels in `Sources/RemindersCore/RemindersStore.swift` before compiling; pass the list name via the label the store declares.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter RESTReadEndpointTests 2>&1 | tail -5`
Expected: 9 tests PASS. If `listNameWithSpaceWorks` fails with a 404 whose message shows the still-encoded name (`My%20Errands`), Hummingbird did not decode the query value and `removingPercentEncoding` did not run; fix `RESTQuery.value`, do not change the test.

- [ ] **Step 6: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/RemindersServer/RemindersServerApp.swift Tests/RemindersServerTests/ServerTestSupport.swift Tests/RemindersServerTests/RESTReadEndpointTests.swift
git commit -m "feat: add REST read endpoints"
```

### Task 9: REST write endpoints

Adds the five write endpoints: create, patch, complete, uncomplete, delete. PATCH carries the null-vs-absent due_date distinction through a dedicated DTO (the store's `ReminderUpdate` Codable decodes `Date` directly, but REST bodies carry CLI-format date strings and use the field name `list`, so REST gets its own decode layer that maps onto `ReminderUpdate`).

**Files:**
- Create: `Sources/RemindersServer/RESTBodies.swift`
- Modify: `Sources/RemindersServer/HTTPJSON.swift` (add `decodeJSONBody`)
- Modify: `Sources/RemindersServer/RemindersServerApp.swift` (add routes in `buildRouter`)
- Create: `Tests/RemindersServerTests/RESTWriteEndpointTests.swift`

**Interfaces:**
- Consumes: Task 4's `store.addReminder(_:toList:)`, `store.update(byID:with:)`, `store.setCompleted(byID:completed:)`, `store.delete(byID:)`; Task 5's `RESTError`/`jsonResponse`; Task 1's `parseDate`/`supportedDateFormats`; `ReminderUpdate` and `ReminderDraft` (RemindersCore).
- Produces (internal to RemindersServer): `struct CreateReminderRequest`, `struct PatchReminderBody` (with `dueDate: String??`), `func parsePriority(_ string: String?) throws -> ReminderPriority?`, `func parseDueDate(_ string: String) throws -> Date`, `func decodeJSONBody<T: Decodable>(_ type: T.Type, from request: Request, context: some RequestContext) async throws -> T`, `func requiredID(from context: some RequestContext) throws -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersServerTests/RESTWriteEndpointTests.swift`. These use `client.execute`'s generic return value to carry the created id out of the response callback; HummingbirdTesting's `execute` returns whatever the trailing closure returns. If the installed version's callback turns out to return `Void` only, capture ids through a small `@unchecked Sendable` box like MiddlewareTests' LogBox instead; do not weaken the assertions.

```swift
// ABOUTME: End-to-end tests for the REST write endpoints (create, patch, complete, delete).
// ABOUTME: Covers happy paths, validation 400s, unknown-id 404s, and the due_date null-vs-absent split.

import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import RemindersCore
import RemindersTestSupport
import Testing
@testable import RemindersServer

@Suite("REST write endpoints")
struct RESTWriteEndpointTests {

    @Test func createReturns201AndPersists() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            let body = #"{"list": "Chores", "title": "Buy milk", "notes": "2 liters", "due_date": "2030-01-15", "priority": "high"}"#
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .created)
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.title == "Buy milk")
                #expect(item.notes == "2 liters")
                #expect(item.priority == .high)
                #expect(item.dueDate != nil)
                #expect(item.listName == "Chores")
            }
        }
        #expect(backend.savedReminders.count == 1)
    }

    @Test func createMissingTitleIs400() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores"}"#)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("title"))
            }
        }
        #expect(backend.savedReminders.isEmpty)
    }

    @Test func createEmptyTitleIs400() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": ""}"#)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("must not be empty"))
            }
        }
    }

    @Test func createUnknownListIs404() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Nope", "title": "x"}"#)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func createInvalidDueDateIs400() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": "x", "due_date": "banana"}"#)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("Supported formats"))
            }
        }
    }

    @Test func createInvalidPriorityIs400() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": "x", "priority": "urgent"}"#)
            ) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("none, low, medium, high"))
            }
        }
    }

    @Test func malformedJSONIs400() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: "this is not json")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func patchEditsTitleNotesPriorityAndList() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        backend.addCalendar(named: "Errands")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            let id = try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": "Original"}"#)
            ) { response in
                try decodeBody(ReminderItem.self, from: response).id
            }
            let patch = #"{"title": "Renamed", "notes": "now with notes", "priority": "low", "list": "Errands"}"#
            try await client.execute(
                uri: "/api/reminders/\(id)",
                method: .patch,
                headers: authHeaders,
                body: ByteBuffer(string: patch)
            ) { response in
                #expect(response.status == .ok)
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.title == "Renamed")
                #expect(item.notes == "now with notes")
                #expect(item.priority == .low)
                #expect(item.listName == "Errands")
            }
        }
    }

    @Test func patchDueDateNullClearsIt() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            let id = try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": "Dated", "due_date": "2030-01-15"}"#)
            ) { response -> String in
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.dueDate != nil)
                return item.id
            }
            try await client.execute(
                uri: "/api/reminders/\(id)",
                method: .patch,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"due_date": null}"#)
            ) { response in
                #expect(response.status == .ok)
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.dueDate == nil)
            }
        }
    }

    @Test func patchWithoutDueDateKeyLeavesDueDateUntouched() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            let id = try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": "Dated", "due_date": "2030-01-15"}"#)
            ) { response in
                try decodeBody(ReminderItem.self, from: response).id
            }
            try await client.execute(
                uri: "/api/reminders/\(id)",
                method: .patch,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"title": "Still dated"}"#)
            ) { response in
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.title == "Still dated")
                #expect(item.dueDate != nil)
            }
        }
    }

    @Test func patchUnknownIDIs404() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders/no-such-id",
                method: .patch,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"title": "x"}"#)
            ) { response in
                #expect(response.status == .notFound)
                #expect(String(buffer: response.body).contains("\"error\""))
            }
        }
    }

    @Test func completeAndDeleteUnknownIDsAre404() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders/no-such-id/complete",
                method: .post,
                headers: authHeaders
            ) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(
                uri: "/api/reminders/no-such-id",
                method: .delete,
                headers: authHeaders
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func completeUncompleteAndDeleteCycle() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            let id = try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": "Cycle me"}"#)
            ) { response in
                try decodeBody(ReminderItem.self, from: response).id
            }
            try await client.execute(
                uri: "/api/reminders/\(id)/complete",
                method: .post,
                headers: authHeaders
            ) { response in
                #expect(response.status == .ok)
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.isCompleted)
                #expect(item.completionDate != nil)
            }
            try await client.execute(
                uri: "/api/reminders/\(id)/uncomplete",
                method: .post,
                headers: authHeaders
            ) { response in
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(!item.isCompleted)
            }
            try await client.execute(
                uri: "/api/reminders/\(id)",
                method: .delete,
                headers: authHeaders
            ) { response in
                #expect(response.status == .ok)
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.title == "Cycle me")
            }
        }
        #expect(backend.removedReminders.count == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RESTWriteEndpointTests 2>&1 | tail -5`
Expected: FAIL. Either a 404 on POST /api/reminders (route not registered) or a compile error on the DTO names, depending on build order.

- [ ] **Step 3: Add the body-decoding helper**

Append to `Sources/RemindersServer/HTTPJSON.swift`:

```swift
/// Decodes a JSON request body, mapping decode failures onto REST 400s.
/// Collects the body and decodes with plain Foundation so validation errors
/// thrown by DTO initializers (as RESTError) pass through intact.
func decodeJSONBody<T: Decodable>(
    _ type: T.Type,
    from request: Request,
    context: some RequestContext
) async throws -> T {
    let buffer = try await request.body.collect(upTo: context.maxUploadSize)
    do {
        return try JSONDecoder().decode(T.self, from: Data(buffer.readableBytesView))
    } catch let error as RESTError {
        throw error
    } catch DecodingError.keyNotFound(let key, _) {
        throw RESTError(status: .badRequest, message: "Missing required field \"\(key.stringValue)\"")
    } catch {
        throw RESTError(status: .badRequest, message: "Request body is not valid JSON for this endpoint")
    }
}
```

- [ ] **Step 4: Create the DTOs**

Create `Sources/RemindersServer/RESTBodies.swift`:

```swift
// ABOUTME: Request body DTOs for the REST write endpoints.
// ABOUTME: due_date stays a CLI-format string until parsed; PATCH keeps null-vs-absent distinct.

import Foundation
import RemindersCore

/// Body of POST /api/reminders.
struct CreateReminderRequest: Decodable {
    let list: String
    let title: String
    let notes: String?
    let dueDate: String?
    let priority: String?

    private enum CodingKeys: String, CodingKey {
        case list, title, notes, priority
        case dueDate = "due_date"
    }
}

/// Body of PATCH /api/reminders/{id}. `dueDate` is double-optional:
/// key absent = leave untouched, JSON null = clear, string = parse and set.
struct PatchReminderBody: Decodable {
    let title: String?
    let notes: String?
    let priority: String?
    let list: String?
    let dueDate: String??

    private enum CodingKeys: String, CodingKey {
        case title, notes, priority, list
        case dueDate = "due_date"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.priority = try container.decodeIfPresent(String.self, forKey: .priority)
        self.list = try container.decodeIfPresent(String.self, forKey: .list)
        if container.contains(.dueDate) {
            if try container.decodeNil(forKey: .dueDate) {
                self.dueDate = .some(nil)
            } else {
                self.dueDate = .some(try container.decode(String.self, forKey: .dueDate))
            }
        } else {
            self.dueDate = nil
        }
    }
}

/// Maps a REST priority string to the domain type; unknown values are a 400.
func parsePriority(_ string: String?) throws -> ReminderPriority? {
    guard let string else { return nil }
    guard let priority = ReminderPriority(rawValue: string) else {
        throw RESTError(
            status: .badRequest,
            message: "Invalid priority \"\(string)\". Must be one of: none, low, medium, high."
        )
    }
    return priority
}

/// Parses a REST due_date string in the CLI formats; garbage is a 400.
func parseDueDate(_ string: String) throws -> Date {
    guard let date = parseDate(string) else {
        throw RESTError(
            status: .badRequest,
            message: "Invalid due_date \"\(string)\". Supported formats: \(supportedDateFormats)."
        )
    }
    return date
}
```

- [ ] **Step 5: Register the write routes**

In `Sources/RemindersServer/RemindersServerApp.swift`:

1. Add a helper above `buildRouter`:

```swift
/// Reads the :id path parameter. Its absence is a routing bug, not client error.
func requiredID(from context: some RequestContext) throws -> String {
    guard let raw = context.parameters.get("id") else {
        throw RESTError(status: .internalServerError, message: "Route is missing its id parameter")
    }
    let id = String(raw)
    return id.removingPercentEncoding ?? id
}
```

2. Inside `buildRouter`, directly after the `api.get("reminders")` handler's closing brace, add:

```swift
    api.post("reminders") { request, context -> Response in
        let body = try await decodeJSONBody(CreateReminderRequest.self, from: request, context: context)
        guard !body.title.isEmpty else {
            throw RESTError(status: .badRequest, message: "Field \"title\" must not be empty")
        }
        let draft = ReminderDraft(
            title: body.title,
            notes: body.notes,
            dueDate: try body.dueDate.map(parseDueDate),
            priority: try parsePriority(body.priority) ?? .none
        )
        let item = try await store.addReminder(draft, toList: body.list)
        return try jsonResponse(item, status: .created)
    }

    api.patch("reminders/:id") { request, context -> Response in
        let id = try requiredID(from: context)
        let body = try await decodeJSONBody(PatchReminderBody.self, from: request, context: context)
        var dueDateChange: Date?? = nil
        if let change = body.dueDate {
            dueDateChange = .some(try change.map(parseDueDate))
        }
        let update = ReminderUpdate(
            title: body.title,
            notes: body.notes,
            dueDate: dueDateChange,
            priority: try parsePriority(body.priority),
            listName: body.list
        )
        let item = try await store.update(byID: id, with: update)
        return try jsonResponse(item)
    }

    api.post("reminders/:id/complete") { _, context -> Response in
        let id = try requiredID(from: context)
        return try jsonResponse(try await store.setCompleted(byID: id, completed: true))
    }

    api.post("reminders/:id/uncomplete") { _, context -> Response in
        let id = try requiredID(from: context)
        return try jsonResponse(try await store.setCompleted(byID: id, completed: false))
    }

    api.delete("reminders/:id") { _, context -> Response in
        let id = try requiredID(from: context)
        return try jsonResponse(try await store.delete(byID: id))
    }
```

PATCH deliberately never touches `isCompleted`; the complete/uncomplete endpoints own that transition. `notes` is set-only: a JSON `null` for notes decodes to absent and leaves notes untouched (spec's v1 capability match).

- [ ] **Step 6: Run the tests**

Run: `swift test --filter RESTWriteEndpointTests 2>&1 | tail -5`
Expected: 13 tests PASS.

- [ ] **Step 7: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings.

- [ ] **Step 8: Commit**

```bash
git add Sources/RemindersServer/RESTBodies.swift Sources/RemindersServer/HTTPJSON.swift Sources/RemindersServer/RemindersServerApp.swift Tests/RemindersServerTests/RESTWriteEndpointTests.swift
git commit -m "feat: add REST write endpoints"
```

---

### Task 10: MCP over HTTP

Wires `POST /mcp` to Task 3's per-message entry point. Stateless per the spec: one JSON-RPC message per POST, `application/json` back, 202 for notifications, 405 for GET and DELETE, no session header ever. The MCP routes sit behind the global auth and logging middleware but NOT behind the /api group's REST error mapping: MCP failures are JSON-RPC envelopes with HTTP 200, and tools/call requests Reminders access itself.

**Files:**
- Modify: `Sources/RemindersServer/RemindersServerApp.swift`
- Create: `Tests/RemindersServerTests/MCPOverHTTPTests.swift`

**Interfaces:**
- Consumes: Task 3's `MCPServer.response(forMessageData:) -> String?` (internal, same module), Task 2's `public init(store:input:output:)`.
- Produces: `POST /mcp`, `GET /mcp` (405), `DELETE /mcp` (405) on the router built by `buildRouter`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RemindersServerTests/MCPOverHTTPTests.swift`:

```swift
// ABOUTME: End-to-end tests for the stateless MCP-over-HTTP transport at POST /mcp.
// ABOUTME: Covers initialize, tools, notifications (202), protocol errors (HTTP 200), 405s, auth.

import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import RemindersCore
import RemindersTestSupport
import Testing
@testable import RemindersServer

@Suite("MCP over HTTP")
struct MCPOverHTTPTests {

    @Test func initializeReturnsJSONAndNoSessionHeader() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let body = String(buffer: response.body)
                #expect(body.contains("protocolVersion"))
                #expect(body.contains("\"id\":1"))
                if let sessionHeader = HTTPField.Name("Mcp-Session-Id") {
                    #expect(response.headers[sessionHeader] == nil)
                }
            }
        }
    }

    @Test func notificationGets202WithEmptyBody() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            ) { response in
                #expect(response.status == .accepted)
                #expect(response.body.readableBytes == 0)
            }
        }
    }

    @Test func parseErrorIsJSONRPCEnvelopeWithHTTP200() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: "this is not json")
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("-32700"))
            }
        }
    }

    @Test func unknownMethodIsJSONRPCEnvelopeWithHTTP200() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":9,"method":"no/such"}"#)
            ) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("-32601"))
                #expect(body.contains("\"id\":9"))
            }
        }
    }

    @Test func toolsListAndCallWorkOverHTTP() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
            ) { response in
                #expect(String(buffer: response.body).contains("show_lists"))
            }
            let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"show_lists","arguments":{}}}"#
            try await client.execute(
                uri: "/mcp",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: call)
            ) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Chores"))
            }
        }
    }

    @Test func getAndDeleteAre405() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/mcp", method: .get, headers: authHeaders) { response in
                #expect(response.status == .methodNotAllowed)
            }
            try await client.execute(uri: "/mcp", method: .delete, headers: authHeaders) { response in
                #expect(response.status == .methodNotAllowed)
            }
        }
    }

    @Test func mcpWithoutTokenIs401() async throws {
        let (_, store) = makeTestStore()
        let app = makeTestApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/mcp",
                method: .post,
                body: ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            ) { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.readableBytes == 0)
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MCPOverHTTPTests 2>&1 | tail -5`
Expected: FAIL. POST /mcp returns 404 (route not registered).

- [ ] **Step 3: Register the MCP routes**

In `Sources/RemindersServer/RemindersServerApp.swift`, inside `buildRouter`, immediately before `return router`, add:

```swift
    // MCP over HTTP (spec "MCP over HTTP"): stateless, one message per POST.
    // Constructed with inert stdio seams; the default init would spawn a
    // stdin-reading task, which a network server must never do.
    let mcpServer = MCPServer(
        store: store,
        input: AsyncThrowingStream<String, Error> { continuation in
            continuation.finish()
        },
        output: { _ in }
    )

    router.post("mcp") { request, context -> Response in
        let buffer = try await request.body.collect(upTo: context.maxUploadSize)
        guard let line = await mcpServer.response(forMessageData: Data(buffer.readableBytesView)) else {
            // Notifications need no body; the transport answers 202 Accepted.
            return Response(status: .accepted)
        }
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: line))
        )
    }

    router.get("mcp") { _, _ -> Response in
        Response(status: .methodNotAllowed)
    }

    router.delete("mcp") { _, _ -> Response in
        Response(status: .methodNotAllowed)
    }
```

Add `import NIOCore` to the file's imports if `ByteBuffer` or `readableBytesView` fails to resolve.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter MCPOverHTTPTests 2>&1 | tail -5`
Expected: 7 tests PASS.

- [ ] **Step 5: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings. The stdio MCP suites must still pass untouched.

- [ ] **Step 6: Commit**

```bash
git add Sources/RemindersServer/RemindersServerApp.swift Tests/RemindersServerTests/MCPOverHTTPTests.swift
git commit -m "feat: serve MCP over HTTP"
```

---

### Task 11: The serve subcommand

`reminders serve` wires everything together: token file (generate or load), bind host resolution, store, application, run until signalled. Hummingbird's `runService()` handles SIGINT/SIGTERM graceful shutdown, which is the foreground mode and what launchd drives in Task 12.

**Files:**
- Create: `Sources/RemindersCLI/Commands/ServeCommand.swift`
- Modify: `Sources/RemindersCLI/Main.swift`
- Create: `Tests/RemindersCLITests/ServeCommandValidationTests.swift`

**Interfaces:**
- Consumes: `TokenFile` (Task 6), `resolveBindHost`/`systemInterfaces` (Task 7), `ServerConfiguration`/`buildApplication` (Task 8), `RemindersStore()` (production init).
- Produces: `struct ServeCommand: AsyncParsableCommand` with `bind: String?`, `port: Int` (default 7364), `tokenFile: String` (default `TokenFile.defaultPath`), `generateToken: Bool`. Task 12's plist runs `<binary> serve`.

- [ ] **Step 1: Write the failing parse tests**

Create `Tests/RemindersCLITests/ServeCommandValidationTests.swift`:

```swift
// ABOUTME: Parse-level tests for the serve subcommand's flags and defaults.
// ABOUTME: No server starts here; these cover option wiring and port validation only.

import Foundation
import Testing
@testable import reminders

@Suite("serve command parsing")
struct ServeCommandValidationTests {

    @Test func defaultsMatchTheSpec() throws {
        let command = try ServeCommand.parse([])
        #expect(command.port == 7364)
        #expect(command.bind == nil)
        #expect(command.generateToken == false)
        #expect(command.tokenFile.hasSuffix(".config/reminders-mcp/token"))
    }

    @Test func flagsOverrideDefaults() throws {
        let command = try ServeCommand.parse([
            "--bind", "127.0.0.1",
            "--port", "8080",
            "--token-file", "/tmp/tok",
            "--generate-token",
        ])
        #expect(command.bind == "127.0.0.1")
        #expect(command.port == 8080)
        #expect(command.tokenFile == "/tmp/tok")
        #expect(command.generateToken == true)
    }

    @Test func portZeroFailsValidation() {
        #expect(throws: (any Error).self) {
            _ = try ServeCommand.parse(["--port", "0"])
        }
    }

    @Test func portAbove65535FailsValidation() {
        #expect(throws: (any Error).self) {
            _ = try ServeCommand.parse(["--port", "70000"])
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ServeCommandValidationTests 2>&1 | tail -5`
Expected: FAIL to compile, `cannot find 'ServeCommand' in scope`.

- [ ] **Step 3: Implement ServeCommand**

Create `Sources/RemindersCLI/Commands/ServeCommand.swift`:

```swift
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
```

- [ ] **Step 4: Register the subcommand**

In `Sources/RemindersCLI/Main.swift`, add `ServeCommand.self,` to the `subcommands:` array in the root command's `CommandConfiguration` (keep the existing entries and their order; append at the end of the array). No other change in this file.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter ServeCommandValidationTests 2>&1 | tail -5`
Expected: 4 tests PASS.

- [ ] **Step 6: Live foreground check (no TCC needed for the 401 path)**

```bash
swift build 2>&1 | tail -3
.build/debug/reminders serve --token-file /tmp/serve-check-token --generate-token
lsof -nP -iTCP:7999 -sTCP:LISTEN || true
.build/debug/reminders serve --token-file /tmp/serve-check-token --bind 127.0.0.1 --port 7999 &
sleep 1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7999/api/lists
curl -s -o /dev/null -w '%{http_code}\n' -X GET http://127.0.0.1:7999/mcp -H "Authorization: Bearer $(cat /tmp/serve-check-token)"
kill %1
rm /tmp/serve-check-token
```

Expected: the generate run prints the token block and exits; the `lsof` shows nothing listening on 7999 beforehand; the first curl prints `401`; the second prints `405`. Neither touches the store, so no TCC prompt fires. Then confirm the missing-token failure mode: `.build/debug/reminders serve --token-file /tmp/definitely-missing` must exit nonzero with the `--generate-token` hint.

- [ ] **Step 7: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings.

- [ ] **Step 8: Commit**

```bash
git add Sources/RemindersCLI/Commands/ServeCommand.swift Sources/RemindersCLI/Main.swift Tests/RemindersCLITests/ServeCommandValidationTests.swift
git commit -m "feat: add serve command"
```

---

### Task 12: launchd agent management

`reminders agent install|uninstall|status` manages the LaunchAgent (spec R7). Plist generation is a pure function with parse-based tests; the launchctl driving is thin glue. Install prints the TCC warning the spec demands.

**Files:**
- Create: `Sources/RemindersServer/LaunchAgentPlist.swift`
- Create: `Tests/RemindersServerTests/LaunchAgentPlistTests.swift`
- Create: `Sources/RemindersCLI/Commands/AgentCommand.swift`
- Modify: `Sources/RemindersCLI/Main.swift`

**Interfaces:**
- Consumes: Foundation, `Process` (launchctl), Task 11's serve subcommand (as the plist's program).
- Produces: `public enum LaunchAgent` with `static let label = "com.harperreed.reminders-mcp"`, `static var plistPath: String`, `static var logDirectory: String`, `static func plist(executablePath: String) -> String`; `struct AgentCommand: ParsableCommand` with `Install`/`Uninstall`/`Status` subcommands.

- [ ] **Step 1: Write the failing plist tests**

Create `Tests/RemindersServerTests/LaunchAgentPlistTests.swift`:

```swift
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

    @Test func pathsLandInTheUserDomain() {
        #expect(LaunchAgent.plistPath.hasSuffix("Library/LaunchAgents/com.harperreed.reminders-mcp.plist"))
        #expect(LaunchAgent.logDirectory.hasSuffix("Library/Logs/reminders-mcp"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LaunchAgentPlistTests 2>&1 | tail -5`
Expected: FAIL to compile, `cannot find 'LaunchAgent' in scope`.

- [ ] **Step 3: Implement plist generation**

Create `Sources/RemindersServer/LaunchAgentPlist.swift`:

```swift
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

    /// Builds the plist XML: run `<executable> serve` at load, restart on
    /// crashes but not on clean exits, logs under `logDirectory`.
    public static func plist(executablePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
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
            <string>\(logDirectory)/stdout.log</string>
            <key>StandardErrorPath</key>
            <string>\(logDirectory)/stderr.log</string>
        </dict>
        </plist>
        """
    }
}
```

- [ ] **Step 4: Run the plist tests**

Run: `swift test --filter LaunchAgentPlistTests 2>&1 | tail -5`
Expected: 2 tests PASS.

- [ ] **Step 5: Implement the agent command**

Create `Sources/RemindersCLI/Commands/AgentCommand.swift`:

```swift
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
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// The launchd service target for the current user's GUI domain.
    static var serviceTarget: String {
        "gui/\(getuid())/\(LaunchAgent.label)"
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install and start the LaunchAgent (runs at login, restarts on crashes)."
        )

        func run() throws {
            let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
            try FileManager.default.createDirectory(
                atPath: LaunchAgent.logDirectory,
                withIntermediateDirectories: true
            )
            try LaunchAgent.plist(executablePath: executable)
                .write(toFile: LaunchAgent.plistPath, atomically: true, encoding: .utf8)

            // Unload any previous version first so reinstalls are idempotent.
            _ = try? AgentCommand.launchctl(["bootout", AgentCommand.serviceTarget])
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
            _ = try? AgentCommand.launchctl(["bootout", AgentCommand.serviceTarget])
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
```

- [ ] **Step 6: Register the subcommand**

In `Sources/RemindersCLI/Main.swift`, add `AgentCommand.self,` to the same `subcommands:` array, after `ServeCommand.self,`.

- [ ] **Step 7: Build and check the CLI surface without installing**

```bash
swift build 2>&1 | tail -3
.build/debug/reminders agent --help
.build/debug/reminders agent status
```

Expected: help lists install, uninstall, status; `status` prints the not-loaded hint (safe, read-only). Do NOT run `agent install` during implementation: it would bootstrap a launchd agent pointing at a debug binary on Harper's machine. The live install is a post-merge manual step (spec success criterion 5).

- [ ] **Step 8: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings.

- [ ] **Step 9: Commit**

```bash
git add Sources/RemindersServer/LaunchAgentPlist.swift Tests/RemindersServerTests/LaunchAgentPlistTests.swift Sources/RemindersCLI/Commands/AgentCommand.swift Sources/RemindersCLI/Main.swift
git commit -m "feat: add launchd agent management"
```

---

### Task 13: Smoke script and documentation

The live smoke script (TCC-dependent, best effort, per the spec's testing requirements) plus the README and CLAUDE.md updates, including the R8 security rationales.

**Files:**
- Create: `scripts/serve-smoke.sh`
- Modify: `README.md`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: the full serve surface from Tasks 8-11; `jq` (installed on this machine).
- Produces: documentation and the ongoing smoke gate.

- [ ] **Step 1: Write the smoke script**

Create `scripts/serve-smoke.sh` (then `chmod +x scripts/serve-smoke.sh`). Before writing, skim `scripts/mcp-freshness-smoke.sh` and match its header/output conventions where they differ from this listing:

```bash
#!/usr/bin/env bash
# ABOUTME: Live smoke test for the network server REST and MCP surfaces over tailscale.
# ABOUTME: TCC-dependent, best effort: runs a create/edit/complete/delete cycle via curl.

set -euo pipefail

usage() {
    echo "usage: $0 [base-url]" >&2
    echo "  base-url          target a running server; omit to start .build/debug/reminders serve" >&2
    echo "  REMINDERS_TOKEN   overrides the token read from ~/.config/reminders-mcp/token" >&2
    exit 2
}

case "${1:-}" in
    -h|--help) usage ;;
esac

TOKEN="${REMINDERS_TOKEN:-$(cat "$HOME/.config/reminders-mcp/token")}"
AUTH=(-H "Authorization: Bearer $TOKEN")
SERVER_PID=""

cleanup() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ -n "${1:-}" ]]; then
    BASE_URL="$1"
else
    swift build
    .build/debug/reminders serve &
    SERVER_PID=$!
    TAILSCALE_IP=$(ifconfig | awk '/inet 100\./ {print $2; exit}')
    if [[ -z "$TAILSCALE_IP" ]]; then
        echo "serve-smoke: no tailscale interface found" >&2
        exit 1
    fi
    BASE_URL="http://$TAILSCALE_IP:7364"
    for _ in $(seq 1 20); do
        if curl -fsS "${AUTH[@]}" "$BASE_URL/api/lists" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
fi

echo "== lists"
curl -fsS "${AUTH[@]}" "$BASE_URL/api/lists"
echo

LIST=$(curl -fsS "${AUTH[@]}" "$BASE_URL/api/lists" | jq -r '.[0].title')
echo "== using list: $LIST"

echo "== create"
ITEM=$(curl -fsS "${AUTH[@]}" -X POST "$BASE_URL/api/reminders" \
    -H 'Content-Type: application/json' \
    -d "{\"list\": \"$LIST\", \"title\": \"serve-smoke $(date +%s)\", \"due_date\": \"tomorrow\"}")
echo "$ITEM"
ID=$(echo "$ITEM" | jq -r '.id')

echo "== patch (rename, clear due date)"
curl -fsS "${AUTH[@]}" -X PATCH "$BASE_URL/api/reminders/$ID" \
    -H 'Content-Type: application/json' \
    -d '{"title": "serve-smoke edited", "due_date": null}'
echo

echo "== complete"
curl -fsS "${AUTH[@]}" -X POST "$BASE_URL/api/reminders/$ID/complete"
echo

echo "== uncomplete"
curl -fsS "${AUTH[@]}" -X POST "$BASE_URL/api/reminders/$ID/uncomplete"
echo

echo "== delete"
curl -fsS "${AUTH[@]}" -X DELETE "$BASE_URL/api/reminders/$ID"
echo

echo "== auth check (expect 401)"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/lists")
if [[ "$STATUS" != "401" ]]; then
    echo "serve-smoke: expected 401 without token, got $STATUS" >&2
    exit 1
fi

echo "== MCP initialize"
curl -fsS "${AUTH[@]}" -X POST "$BASE_URL/mcp" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
echo

echo "serve-smoke: PASS"
```

- [ ] **Step 2: Add the README section**

Append to `README.md` (at the end of the file):

````markdown
## Network server

`reminders serve` runs an HTTP server that exposes the same reminder tools over the network. Two surfaces share one listener and one bearer token:

- `POST /mcp`: MCP over Streamable HTTP (stateless: no sessions, no SSE)
- `/api/*`: a JSON REST API

### Setup

```bash
# one time: create the bearer token (printed once, stored with mode 600)
reminders serve --generate-token

# run in the foreground
reminders serve

# or keep it running via launchd (runs at login, restarts on crashes)
reminders agent install
reminders agent status
reminders agent uninstall
```

The server binds the Mac's tailscale interface by default and refuses to start without one. `--bind` overrides the interface, `--port` overrides the default 7364, `--token-file` overrides the token path (`~/.config/reminders-mcp/token`).

### Connect an MCP client

```bash
claude mcp add --transport http reminders \
  "http://<tailscale-ip>:7364/mcp" \
  --header "Authorization: Bearer <token>"
```

### REST API

Every request needs `Authorization: Bearer <token>`. Errors: 401 with an empty body; 400, 404, and 500 with `{"error": "message"}`.

| Method and path | Body / query | Returns |
| --- | --- | --- |
| GET /api/lists | | all lists |
| GET /api/reminders | query: `list`, `completed` (false, all, only), `due_before`, `due_after` | reminders (default: incomplete, all lists) |
| POST /api/reminders | `{list, title, notes?, due_date?, priority?}` | 201 + the new reminder |
| PATCH /api/reminders/{id} | any of `{title, notes, due_date, priority, list}`; `"due_date": null` clears it | the updated reminder |
| POST /api/reminders/{id}/complete | | the completed reminder |
| POST /api/reminders/{id}/uncomplete | | the reopened reminder |
| DELETE /api/reminders/{id} | | the deleted reminder |

Dates accept the CLI formats (`today`, `tomorrow`, `next week`, `2030-01-15`, `2030-01-15 09:30`, `01/15/2030`, `01/15`). Priorities: `none`, `low`, `medium`, `high`. Reminder ids come from the API's own responses.

### Security model

- No TLS: tailscale (WireGuard) already encrypts the transport, and the listener only binds the tailscale interface. Anything that can reach the port is already on your tailnet.
- No Origin checking: DNS rebinding lets a hostile page reach the listener, but browsers cannot attach the bearer token, so rebound requests get the same empty 401 as any other unauthenticated request.
- Request logs are one line each (method, path, status, duration); bodies and tokens are never logged.
- launchd caveat: macOS ties Reminders access to the binary's path and signature. Rebuilding or moving the binary can silently re-trigger the permission prompt, which nobody sees under launchd; the server then fails until you run the binary by hand and re-grant access. `reminders agent status` shows the last exit state.

### Smoke test

```bash
scripts/serve-smoke.sh                       # starts .build/debug/reminders serve itself
scripts/serve-smoke.sh http://100.x.y.z:7364 # or target a running server
```
````

- [ ] **Step 3: Update CLAUDE.md**

Two edits in `CLAUDE.md`:

1. Replace the Architecture bullets:

```markdown
- `RemindersCore` - Actor-based EventKit wrapper, no semaphores
- `RemindersServer` - MCP server (stdio and HTTP transports), Hummingbird REST layer, token file, tailscale discovery, launchd plist
- `RemindersCLI` - swift-argument-parser CLI; subcommands include `serve` and `agent`
- `RemindersTestSupport` - shared in-memory fake of the EventKit seam; tests run without TCC
- Single binary: `reminders`
```

2. After the "## Run as MCP server" section, add:

````markdown
## Run network server

```bash
.build/debug/reminders serve --generate-token   # first time: create the bearer token
.build/debug/reminders serve                    # MCP at /mcp, REST under /api, tailscale interface, port 7364
.build/debug/reminders agent install            # keep it running via launchd
```

Live smoke: `scripts/serve-smoke.sh` (TCC-dependent, best effort).
````

- [ ] **Step 4: Run the smoke script live (best effort)**

Run: `scripts/serve-smoke.sh`
Expected: the full cycle prints and ends with `serve-smoke: PASS`. This needs three machine facts: a token file exists (generate one first if needed), tailscale is up, and `.build/debug/reminders` has Reminders TCC access. If TCC denies (500s with a permission message) or tailscale is down, report the exact failure and continue; the script is best effort by design. Cross-machine checks (spec success criteria 1 and 2) stay manual for Harper after merge.

- [ ] **Step 5: Gate the docs for em dashes**

Run: `grep -nE '—|–' README.md CLAUDE.md scripts/serve-smoke.sh || echo clean`
Expected: `clean`.

- [ ] **Step 6: Run the canonical gate**

Run: `make check`
Expected: PASS, zero warnings.

- [ ] **Step 7: Commit**

```bash
git add scripts/serve-smoke.sh README.md CLAUDE.md
git commit -m "docs: add network server docs and smoke test"
```
