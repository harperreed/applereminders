# Reminders MCP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Swift CLI that is a drop-in replacement for `reminders-cli`, using clean async/await EventKit, with an `--mcp` flag that turns it into an MCP server over stdio.

**Architecture:** Three-layer design — `RemindersCore` (actor-based EventKit wrapper), `RemindersCLI` (swift-argument-parser commands + MCP server), and a thin entry point. Single binary called `reminders`. MCP protocol implemented directly as JSON-RPC over stdin/stdout (no external MCP library needed).

**Tech Stack:** Swift 6.0+, macOS 14+, EventKit framework, swift-argument-parser

---

### Task 1: Initialize Swift Package

**Files:**
- Create: `Package.swift`
- Create: `Sources/reminders/Main.swift`
- Create: `Sources/RemindersCore/.gitkeep`
- Create: `Sources/RemindersCLI/.gitkeep`
- Create: `Tests/RemindersCoreTests/.gitkeep`

**Step 1: Initialize git repo**

```bash
cd /Users/harper/Public/src/personal/reminders-mcp
git init
```

**Step 2: Create Package.swift**

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
        .executableTarget(
            name: "reminders",
            dependencies: [
                "RemindersCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/RemindersCLI"
        ),
        .testTarget(
            name: "RemindersCoreTests",
            dependencies: ["RemindersCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

**Step 3: Create minimal entry point**

Create `Sources/RemindersCLI/Main.swift`:
```swift
// ABOUTME: Entry point for the reminders CLI tool.
// ABOUTME: Dispatches to CLI subcommands or MCP server mode.
import ArgumentParser

@main
struct RemindersTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Interact with macOS Reminders from the command line"
    )
}
```

**Step 4: Verify it builds**

Run: `cd /Users/harper/Public/src/personal/reminders-mcp && swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 5: Create .gitignore and commit**

```gitignore
.build/
.swiftpm/
Package.resolved
*.xcodeproj
.DS_Store
```

```bash
git add -A
git commit -m "feat: initialize Swift package with argument-parser"
```

---

### Task 2: RemindersCore — Models

**Files:**
- Create: `Sources/RemindersCore/Models.swift`
- Create: `Tests/RemindersCoreTests/ModelsTests.swift`

**Step 1: Write failing tests for Priority mapping**

Create `Tests/RemindersCoreTests/ModelsTests.swift`:
```swift
// ABOUTME: Tests for RemindersCore model types.
// ABOUTME: Validates Priority mapping to/from EventKit values.
import Testing
@testable import RemindersCore

@Suite("Priority Tests")
struct PriorityTests {
    @Test("EventKit value round-trips for .none")
    func noneRoundTrip() {
        let priority = ReminderPriority(eventKitValue: 0)
        #expect(priority == .none)
        #expect(priority.eventKitValue == 0)
    }

    @Test("EventKit value round-trips for .high")
    func highRoundTrip() {
        let priority = ReminderPriority(eventKitValue: 1)
        #expect(priority == .high)
        #expect(priority.eventKitValue == 1)
    }

    @Test("EventKit value round-trips for .medium")
    func mediumRoundTrip() {
        let priority = ReminderPriority(eventKitValue: 5)
        #expect(priority == .medium)
        #expect(priority.eventKitValue == 5)
    }

    @Test("EventKit value round-trips for .low")
    func lowRoundTrip() {
        let priority = ReminderPriority(eventKitValue: 9)
        #expect(priority == .low)
        #expect(priority.eventKitValue == 9)
    }

    @Test("EventKit values 2-4 map to .high")
    func highRange() {
        for v in 2...4 {
            #expect(ReminderPriority(eventKitValue: v) == .high)
        }
    }

    @Test("EventKit values 6-9 map to .low")
    func lowRange() {
        for v in 6...9 {
            #expect(ReminderPriority(eventKitValue: v) == .low)
        }
    }
}

@Suite("ReminderItem Tests")
struct ReminderItemTests {
    @Test("ReminderItem is Codable")
    func codableRoundTrip() throws {
        let item = ReminderItem(
            id: "abc123",
            title: "Buy milk",
            notes: "From the store",
            isCompleted: false,
            completionDate: nil,
            priority: .medium,
            dueDate: Date(timeIntervalSince1970: 1700000000),
            listID: "list1",
            listName: "Groceries"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(item)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ReminderItem.self, from: data)
        #expect(decoded.id == item.id)
        #expect(decoded.title == item.title)
        #expect(decoded.notes == item.notes)
        #expect(decoded.priority == item.priority)
        #expect(decoded.listName == item.listName)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test 2>&1`
Expected: FAIL — types don't exist yet

**Step 3: Implement Models.swift**

Create `Sources/RemindersCore/Models.swift`:
```swift
// ABOUTME: Domain models for reminders data, decoupled from EventKit types.
// ABOUTME: Includes ReminderItem, ReminderList, Priority, and draft/update types.
import Foundation

public enum ReminderPriority: String, Codable, CaseIterable, Sendable {
    case none
    case low
    case medium
    case high

    public init(eventKitValue: Int) {
        switch eventKitValue {
        case 1...4: self = .high
        case 5: self = .medium
        case 6...9: self = .low
        default: self = .none
        }
    }

    public var eventKitValue: Int {
        switch self {
        case .none: return 0
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }
}

public struct ReminderList: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ReminderItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let completionDate: Date?
    public let priority: ReminderPriority
    public let dueDate: Date?
    public let listID: String
    public let listName: String

    public init(
        id: String,
        title: String,
        notes: String?,
        isCompleted: Bool,
        completionDate: Date?,
        priority: ReminderPriority,
        dueDate: Date?,
        listID: String,
        listName: String
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.priority = priority
        self.dueDate = dueDate
        self.listID = listID
        self.listName = listName
    }
}

public struct ReminderDraft: Sendable {
    public let title: String
    public let notes: String?
    public let dueDate: Date?
    public let priority: ReminderPriority

    public init(title: String, notes: String? = nil, dueDate: Date? = nil, priority: ReminderPriority = .none) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.priority = priority
    }
}

public struct ReminderUpdate: Sendable {
    public let title: String?
    public let notes: String?
    public let dueDate: Date??
    public let priority: ReminderPriority?
    public let listName: String?
    public let isCompleted: Bool?

    public init(
        title: String? = nil,
        notes: String? = nil,
        dueDate: Date?? = nil,
        priority: ReminderPriority? = nil,
        listName: String? = nil,
        isCompleted: Bool? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.priority = priority
        self.listName = listName
        self.isCompleted = isCompleted
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `swift test 2>&1`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add Sources/RemindersCore/Models.swift Tests/RemindersCoreTests/ModelsTests.swift
git commit -m "feat: add RemindersCore domain models with tests"
```

---

### Task 3: RemindersCore — Errors

**Files:**
- Create: `Sources/RemindersCore/Errors.swift`

**Step 1: Create Errors.swift**

```swift
// ABOUTME: Typed error enum for RemindersCore operations.
// ABOUTME: Covers access control, lookup failures, and operation errors.
import Foundation

public enum RemindersError: LocalizedError, Sendable {
    case accessDenied
    case writeOnlyAccess
    case listNotFound(String)
    case reminderNotFound(String)
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to Reminders denied. Grant access in System Settings > Privacy & Security > Reminders."
        case .writeOnlyAccess:
            return "Only write access granted. Full access required. Update in System Settings > Privacy & Security > Reminders."
        case .listNotFound(let name):
            return "No reminders list matching '\(name)'"
        case .reminderNotFound(let id):
            return "No reminder found with identifier '\(id)'"
        case .operationFailed(let message):
            return message
        }
    }
}
```

**Step 2: Verify build**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/RemindersCore/Errors.swift
git commit -m "feat: add typed error enum for RemindersCore"
```

---

### Task 4: RemindersCore — RemindersStore (actor)

**Files:**
- Create: `Sources/RemindersCore/RemindersStore.swift`

This is the core EventKit wrapper. It replaces all the semaphore-based code from reminders-cli with proper async/await.

**Step 1: Create RemindersStore.swift**

```swift
// ABOUTME: Actor wrapping EKEventStore with async/await for all reminder operations.
// ABOUTME: Replaces semaphore-based patterns with structured concurrency.
import EventKit
import Foundation

public actor RemindersStore {
    private let eventStore = EKEventStore()
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: - Authorization

    public func requestAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .notDetermined:
            let granted = try await eventStore.requestFullAccessToReminders()
            if !granted {
                throw RemindersError.accessDenied
            }
        case .denied, .restricted:
            throw RemindersError.accessDenied
        case .fullAccess:
            break
        case .writeOnly:
            throw RemindersError.writeOnlyAccess
        @unknown default:
            throw RemindersError.accessDenied
        }
    }

    // MARK: - Lists

    public func lists() -> [ReminderList] {
        eventStore.calendars(for: .reminder).map { cal in
            ReminderList(id: cal.calendarIdentifier, title: cal.title)
        }
    }

    public func defaultListName() -> String? {
        eventStore.defaultCalendarForNewReminders()?.title
    }

    public func createList(name: String, sourceName: String? = nil) throws -> ReminderList {
        let list = EKCalendar(for: .reminder, eventStore: eventStore)
        list.title = name

        let source: EKSource
        if let sourceName {
            guard let found = eventStore.sources.first(where: { $0.title == sourceName }) else {
                throw RemindersError.operationFailed("No source named '\(sourceName)'")
            }
            source = found
        } else {
            guard let defaultSource = eventStore.defaultCalendarForNewReminders()?.source else {
                throw RemindersError.operationFailed("Unable to determine default reminder source")
            }
            source = defaultSource
        }

        list.source = source
        try eventStore.saveCalendar(list, commit: true)
        return ReminderList(id: list.calendarIdentifier, title: list.title)
    }

    // MARK: - Fetching Reminders

    public func reminders(inList listName: String? = nil, includeCompleted: Bool = false, onlyCompleted: Bool = false) async throws -> [ReminderItem] {
        let calendars: [EKCalendar]
        if let listName {
            calendars = try [resolveCalendar(named: listName)]
        } else {
            calendars = eventStore.calendars(for: .reminder)
        }

        let predicate = eventStore.predicateForReminders(in: calendars)
        let ekReminders = try await eventStore.reminders(matching: predicate)

        return ekReminders
            .filter { reminder in
                if onlyCompleted { return reminder.isCompleted }
                if !includeCompleted { return !reminder.isCompleted }
                return true
            }
            .map { mapReminder($0) }
    }

    // MARK: - Creating Reminders

    public func addReminder(_ draft: ReminderDraft, toList listName: String) throws -> ReminderItem {
        let ekCalendar = try resolveCalendar(named: listName)
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = ekCalendar
        reminder.priority = draft.priority.eventKitValue

        if let dueDate = draft.dueDate {
            reminder.dueDateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate
            )
            let dueDateComps = calendar.dateComponents([.hour], from: dueDate)
            if dueDateComps.hour != nil && dueDateComps.hour != 0 {
                reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            }
        }

        try eventStore.save(reminder, commit: true)
        return mapReminder(reminder)
    }

    // MARK: - Completing Reminders

    public func setComplete(_ complete: Bool, itemAtIndex index: String, onList listName: String) async throws -> ReminderItem {
        let displayOptions: DisplayOptions = complete ? .incomplete : .complete
        let reminders = try await filteredReminders(on: listName, displayOptions: displayOptions)

        guard let reminder = resolveReminder(from: reminders, at: index) else {
            throw RemindersError.reminderNotFound(index)
        }

        reminder.isCompleted = complete
        try eventStore.save(reminder, commit: true)
        return mapReminder(reminder)
    }

    // MARK: - Editing Reminders

    public func edit(itemAtIndex index: String, onList listName: String, newText: String?, newNotes: String?) async throws -> ReminderItem {
        let reminders = try await filteredReminders(on: listName, displayOptions: .incomplete)

        guard let reminder = resolveReminder(from: reminders, at: index) else {
            throw RemindersError.reminderNotFound(index)
        }

        if let newText { reminder.title = newText }
        if let newNotes { reminder.notes = newNotes }
        try eventStore.save(reminder, commit: true)
        return mapReminder(reminder)
    }

    // MARK: - Deleting Reminders

    public func delete(itemAtIndex index: String, onList listName: String) async throws -> String {
        let reminders = try await filteredReminders(on: listName, displayOptions: .incomplete)

        guard let reminder = resolveReminder(from: reminders, at: index) else {
            throw RemindersError.reminderNotFound(index)
        }

        let title = reminder.title ?? "<unknown>"
        try eventStore.remove(reminder, commit: true)
        return title
    }

    // MARK: - Private Helpers

    private enum DisplayOptions {
        case all, incomplete, complete
    }

    private func filteredReminders(on listName: String, displayOptions: DisplayOptions) async throws -> [EKReminder] {
        let ekCalendar = try resolveCalendar(named: listName)
        let predicate = eventStore.predicateForReminders(in: [ekCalendar])
        let all = try await eventStore.reminders(matching: predicate)
        return all.filter { reminder in
            switch displayOptions {
            case .all: return true
            case .incomplete: return !reminder.isCompleted
            case .complete: return reminder.isCompleted
            }
        }
    }

    private func resolveCalendar(named name: String) throws -> EKCalendar {
        guard let cal = eventStore.calendars(for: .reminder)
            .first(where: { $0.title.lowercased() == name.lowercased() }) else {
            throw RemindersError.listNotFound(name)
        }
        return cal
    }

    private func resolveReminder(from reminders: [EKReminder], at index: String) -> EKReminder? {
        if let intIndex = Int(index) {
            guard intIndex >= 0, intIndex < reminders.count else { return nil }
            return reminders[intIndex]
        }
        return reminders.first { $0.calendarItemExternalIdentifier == index }
    }

    private func mapReminder(_ reminder: EKReminder) -> ReminderItem {
        let dueDate: Date? = reminder.dueDateComponents.flatMap { calendar.date(from: $0) }
        return ReminderItem(
            id: reminder.calendarItemExternalIdentifier,
            title: reminder.title ?? "<unknown>",
            notes: reminder.notes,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            priority: ReminderPriority(eventKitValue: Int(reminder.priority)),
            dueDate: dueDate,
            listID: reminder.calendar.calendarIdentifier,
            listName: reminder.calendar.title
        )
    }
}
```

**Step 2: Verify it builds**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/RemindersCore/RemindersStore.swift
git commit -m "feat: add actor-based RemindersStore wrapping EventKit"
```

---

### Task 5: CLI — Output Formatting

**Files:**
- Create: `Sources/RemindersCLI/Formatting.swift`

**Step 1: Create Formatting.swift**

```swift
// ABOUTME: Output formatting for CLI commands (plain text and JSON).
// ABOUTME: Matches reminders-cli output format for drop-in compatibility.
import Foundation
import RemindersCore

enum OutputFormat: String, CaseIterable, Sendable {
    case plain
    case json
}

extension OutputFormat: ExpressibleByArgument {}

import ArgumentParser
extension OutputFormat: ArgumentParser.ExpressibleByArgument {}

enum Formatter {
    static func format(_ reminder: ReminderItem, at index: Int?, listName: String? = nil) -> String {
        let dateFormatter = RelativeDateTimeFormatter()
        let dateString = reminder.dueDate.map { " (\(dateFormatter.localizedString(for: $0, relativeTo: Date())))" } ?? ""
        let priorityString = reminder.priority != .none ? " (priority: \(reminder.priority.rawValue))" : ""
        let listString = listName.map { "\($0): " } ?? ""
        let notesString = reminder.notes.map { " (\($0))" } ?? ""
        let indexString = index.map { "\($0): " } ?? ""
        return "\(listString)\(indexString)\(reminder.title)\(notesString)\(dateString)\(priorityString)"
    }

    static func printReminders(_ reminders: [ReminderItem], outputFormat: OutputFormat, showListName: Bool = false) {
        switch outputFormat {
        case .json:
            printJSON(reminders)
        case .plain:
            for (i, reminder) in reminders.enumerated() {
                let listName = showListName ? reminder.listName : nil
                print(format(reminder, at: i, listName: listName))
            }
        }
    }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
```

**Step 2: Verify it builds**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add Sources/RemindersCLI/Formatting.swift
git commit -m "feat: add CLI output formatting (plain + JSON)"
```

---

### Task 6: CLI — All Subcommands

**Files:**
- Modify: `Sources/RemindersCLI/Main.swift`

This task implements all subcommands to match `reminders-cli` exactly:
- `show-lists` — print list names
- `show <list>` — print reminders in a list
- `show-all` — print all reminders across lists
- `add <list> <reminder>` — add a reminder
- `complete <list> <index>` — mark complete
- `uncomplete <list> <index>` — mark incomplete
- `delete <list> <index>` — delete a reminder
- `edit <list> <index> <text>` — edit reminder text
- `new-list <name>` — create a list

**Step 1: Rewrite Main.swift with all subcommands**

```swift
// ABOUTME: Entry point and CLI subcommand definitions for the reminders tool.
// ABOUTME: Drop-in replacement for reminders-cli using async/await EventKit.
import ArgumentParser
import Foundation
import RemindersCore

@main
struct RemindersTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Interact with macOS Reminders from the command line",
        subcommands: [
            ShowLists.self,
            Show.self,
            ShowAll.self,
            Add.self,
            Complete.self,
            Uncomplete.self,
            Delete.self,
            Edit.self,
            NewList.self,
        ]
    )
}

// MARK: - Shared

func makeStore() async throws -> RemindersStore {
    let store = RemindersStore()
    try await store.requestAccess()
    return store
}

// MARK: - show-lists

struct ShowLists: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the name of lists to pass to other commands"
    )

    @Option(name: .shortAndLong, help: "Output format: 'plain' or 'json'")
    var format: OutputFormat = .plain

    func run() async throws {
        let store = try await makeStore()
        let lists = await store.lists()
        switch format {
        case .json:
            Formatter.printJSON(lists.map(\.title))
        case .plain:
            for list in lists {
                print(list.title)
            }
        }
    }
}

// MARK: - show

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the items on the given list"
    )

    @Argument(help: "The list to print items from")
    var listName: String

    @Flag(help: "Show completed items only")
    var onlyCompleted = false

    @Flag(help: "Include completed items in output")
    var includeCompleted = false

    @Flag(help: "When using --due-date, also include items due before the due date")
    var includeOverdue = false

    @Option(name: .shortAndLong, help: "Show only reminders due on this date")
    var dueDate: String?

    @Option(name: .shortAndLong, help: "Output format: 'plain' or 'json'")
    var format: OutputFormat = .plain

    func validate() throws {
        if onlyCompleted && includeCompleted {
            throw ValidationError("Cannot specify both --include-completed and --only-completed")
        }
    }

    func run() async throws {
        let store = try await makeStore()
        let reminders = try await store.reminders(
            inList: listName,
            includeCompleted: includeCompleted || onlyCompleted,
            onlyCompleted: onlyCompleted
        )
        let filtered = filterByDueDate(reminders, dueDate: dueDate, includeOverdue: includeOverdue)
        Formatter.printReminders(filtered, outputFormat: format)
    }
}

// MARK: - show-all

struct ShowAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print all reminders"
    )

    @Flag(help: "Show completed items only")
    var onlyCompleted = false

    @Flag(help: "Include completed items in output")
    var includeCompleted = false

    @Flag(help: "When using --due-date, also include items due before the due date")
    var includeOverdue = false

    @Option(name: .shortAndLong, help: "Show only reminders due on this date")
    var dueDate: String?

    @Option(name: .shortAndLong, help: "Output format: 'plain' or 'json'")
    var format: OutputFormat = .plain

    func validate() throws {
        if onlyCompleted && includeCompleted {
            throw ValidationError("Cannot specify both --include-completed and --only-completed")
        }
    }

    func run() async throws {
        let store = try await makeStore()
        let reminders = try await store.reminders(
            includeCompleted: includeCompleted || onlyCompleted,
            onlyCompleted: onlyCompleted
        )
        let filtered = filterByDueDate(reminders, dueDate: dueDate, includeOverdue: includeOverdue)
        Formatter.printReminders(filtered, outputFormat: format, showListName: true)
    }
}

// MARK: - add

struct Add: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add a reminder to a list"
    )

    @Argument(help: "The list to add to")
    var listName: String

    @Argument(parsing: .remaining, help: "The reminder contents")
    var reminder: [String]

    @Option(name: .shortAndLong, help: "The date the reminder is due")
    var dueDate: String?

    @Option(name: .shortAndLong, help: "The priority: none, low, medium, high")
    var priority: String = "none"

    @Option(name: .shortAndLong, help: "Notes to add to the reminder")
    var notes: String?

    @Option(name: .shortAndLong, help: "Output format: 'plain' or 'json'")
    var format: OutputFormat = .plain

    func run() async throws {
        let store = try await makeStore()
        let parsedPriority = ReminderPriority(rawValue: priority) ?? .none
        let parsedDate = dueDate.flatMap { parseDate($0) }
        let draft = ReminderDraft(
            title: reminder.joined(separator: " "),
            notes: notes,
            dueDate: parsedDate,
            priority: parsedPriority
        )
        let item = try await store.addReminder(draft, toList: listName)
        switch format {
        case .json:
            Formatter.printJSON(item)
        case .plain:
            print("Added '\(item.title)' to '\(listName)'")
        }
    }
}

// MARK: - complete

struct Complete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Complete a reminder"
    )

    @Argument(help: "The list name")
    var listName: String

    @Argument(help: "The index or external ID of the reminder")
    var index: String

    func run() async throws {
        let store = try await makeStore()
        let item = try await store.setComplete(true, itemAtIndex: index, onList: listName)
        print("Completed '\(item.title)'")
    }
}

// MARK: - uncomplete

struct Uncomplete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Uncomplete a reminder"
    )

    @Argument(help: "The list name")
    var listName: String

    @Argument(help: "The index or external ID of the reminder")
    var index: String

    func run() async throws {
        let store = try await makeStore()
        let item = try await store.setComplete(false, itemAtIndex: index, onList: listName)
        print("Uncompleted '\(item.title)'")
    }
}

// MARK: - delete

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a reminder"
    )

    @Argument(help: "The list name")
    var listName: String

    @Argument(help: "The index or external ID of the reminder")
    var index: String

    func run() async throws {
        let store = try await makeStore()
        let title = try await store.delete(itemAtIndex: index, onList: listName)
        print("Deleted '\(title)'")
    }
}

// MARK: - edit

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit the text of a reminder"
    )

    @Argument(help: "The list name")
    var listName: String

    @Argument(help: "The index or external ID of the reminder")
    var index: String

    @Option(name: .shortAndLong, help: "New notes for the reminder")
    var notes: String?

    @Argument(parsing: .remaining, help: "The new reminder contents")
    var reminder: [String] = []

    func validate() throws {
        if reminder.isEmpty && notes == nil {
            throw ValidationError("Must specify either new reminder content or new notes")
        }
    }

    func run() async throws {
        let store = try await makeStore()
        let newText = reminder.joined(separator: " ")
        let item = try await store.edit(
            itemAtIndex: index,
            onList: listName,
            newText: newText.isEmpty ? nil : newText,
            newNotes: notes
        )
        print("Updated reminder '\(item.title)'")
    }
}

// MARK: - new-list

struct NewList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a new list"
    )

    @Argument(help: "The name of the new list")
    var listName: String

    @Option(name: .shortAndLong, help: "The source to create the list in")
    var source: String?

    func run() async throws {
        let store = try await makeStore()
        let list = try await store.createList(name: listName, sourceName: source)
        print("Created new list '\(list.title)'!")
    }
}

// MARK: - Date Helpers

func parseDate(_ string: String) -> Date? {
    let formatter = DateFormatter()
    // Try common formats
    for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd", "MM/dd/yyyy", "MM/dd"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: string) {
            return date
        }
    }
    // Try natural language "today", "tomorrow"
    let lowered = string.lowercased()
    let calendar = Calendar.current
    if lowered == "today" {
        return calendar.startOfDay(for: Date())
    } else if lowered == "tomorrow" {
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
    }
    return nil
}

func filterByDueDate(_ reminders: [ReminderItem], dueDate: String?, includeOverdue: Bool) -> [ReminderItem] {
    guard let dueDateString = dueDate, let targetDate = parseDate(dueDateString) else {
        return reminders
    }
    let calendar = Calendar.current
    return reminders.filter { reminder in
        guard let reminderDate = reminder.dueDate else { return false }
        let sameDay = calendar.isDate(reminderDate, inSameDayAs: targetDate)
        let earlier = reminderDate < targetDate
        return sameDay || (includeOverdue && earlier)
    }
}
```

**Step 2: Verify it builds**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 3: Smoke test the binary**

Run: `.build/debug/reminders --help 2>&1`
Expected: Help output showing all subcommands

**Step 4: Commit**

```bash
git add Sources/RemindersCLI/Main.swift
git commit -m "feat: implement all CLI subcommands matching reminders-cli"
```

---

### Task 7: CLI — MCP Server Mode

**Files:**
- Create: `Sources/RemindersCLI/MCPServer.swift`
- Create: `Sources/RemindersCLI/MCPTypes.swift`
- Modify: `Sources/RemindersCLI/Main.swift` (add --mcp flag)

The MCP server speaks JSON-RPC 2.0 over stdin/stdout. It exposes tools matching the CLI subcommands.

**Step 1: Create MCPTypes.swift**

```swift
// ABOUTME: JSON-RPC and MCP protocol types for the stdio MCP server.
// ABOUTME: Covers requests, responses, tool definitions, and error codes.
import Foundation

// MARK: - JSON-RPC

struct JSONRPCRequest: Decodable {
    let jsonrpc: String
    let id: RequestID?
    let method: String
    let params: JSONValue?
}

enum RequestID: Codable, Sendable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(RequestID.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        }
    }
}

enum JSONValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    func stringValue() -> String? {
        if case .string(let s) = self { return s }
        return nil
    }

    func objectValue() -> [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}

// MARK: - MCP Protocol

struct MCPToolDefinition: Codable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
}

struct JSONSchema: Codable {
    let type: String
    let properties: [String: PropertySchema]?
    let required: [String]?
}

struct PropertySchema: Codable {
    let type: String
    let description: String
    let `enum`: [String]?

    init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enum = enumValues
    }
}

struct MCPTextContent: Codable {
    let type: String = "text"
    let text: String

    init(_ text: String) {
        self.text = text
    }
}

struct MCPToolResult: Codable {
    let content: [MCPTextContent]
    let isError: Bool?

    init(text: String, isError: Bool = false) {
        self.content = [MCPTextContent(text)]
        self.isError = isError ? true : nil
    }
}
```

**Step 2: Create MCPServer.swift**

```swift
// ABOUTME: MCP server implementation over stdio using JSON-RPC 2.0.
// ABOUTME: Exposes reminder operations as MCP tools for agent integration.
import Foundation
import RemindersCore

actor MCPServer {
    private let store: RemindersStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(store: RemindersStore) {
        self.store = store
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
    }

    func run() async {
        // Read lines from stdin, process each as JSON-RPC
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8) else { continue }

            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: data)
                let response = await handleRequest(request)
                if let response {
                    let responseData = try encoder.encode(response)
                    if let responseString = String(data: responseData, encoding: .utf8) {
                        print(responseString)
                        fflush(stdout)
                    }
                }
            } catch {
                let errorResponse = makeErrorResponse(id: nil, code: -32700, message: "Parse error: \(error.localizedDescription)")
                if let data = try? encoder.encode(errorResponse), let str = String(data: data, encoding: .utf8) {
                    print(str)
                    fflush(stdout)
                }
            }
        }
    }

    private func handleRequest(_ request: JSONRPCRequest) async -> [String: JSONValue]? {
        switch request.method {
        case "initialize":
            return makeResponse(id: request.id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([
                    "tools": .object([:])
                ]),
                "serverInfo": .object([
                    "name": .string("reminders-mcp"),
                    "version": .string("1.0.0")
                ])
            ]))

        case "notifications/initialized":
            return nil  // No response for notifications

        case "tools/list":
            return makeResponse(id: request.id, result: .object([
                "tools": .array(toolDefinitions())
            ]))

        case "tools/call":
            guard let params = request.params?.objectValue(),
                  let name = params["name"]?.stringValue() else {
                return makeErrorResponse(id: request.id, code: -32602, message: "Missing tool name")
            }
            let args = params["arguments"]?.objectValue() ?? [:]
            let result = await callTool(name: name, arguments: args)
            return makeResponse(id: request.id, result: toolResultToJSON(result))

        case "ping":
            return makeResponse(id: request.id, result: .object([:]))

        default:
            return makeErrorResponse(id: request.id, code: -32601, message: "Method not found: \(request.method)")
        }
    }

    // MARK: - Tool Definitions

    private func toolDefinitions() -> [JSONValue] {
        let tools: [MCPToolDefinition] = [
            MCPToolDefinition(
                name: "show_lists",
                description: "List all reminder lists",
                inputSchema: JSONSchema(type: "object", properties: nil, required: nil)
            ),
            MCPToolDefinition(
                name: "show_reminders",
                description: "Show reminders in a specific list",
                inputSchema: JSONSchema(type: "object", properties: [
                    "list": PropertySchema(type: "string", description: "Name of the reminder list"),
                    "include_completed": PropertySchema(type: "boolean", description: "Include completed reminders"),
                    "only_completed": PropertySchema(type: "boolean", description: "Show only completed reminders"),
                ], required: ["list"])
            ),
            MCPToolDefinition(
                name: "show_all_reminders",
                description: "Show all reminders across all lists",
                inputSchema: JSONSchema(type: "object", properties: [
                    "include_completed": PropertySchema(type: "boolean", description: "Include completed reminders"),
                    "only_completed": PropertySchema(type: "boolean", description: "Show only completed reminders"),
                ], required: nil)
            ),
            MCPToolDefinition(
                name: "add_reminder",
                description: "Add a new reminder to a list",
                inputSchema: JSONSchema(type: "object", properties: [
                    "list": PropertySchema(type: "string", description: "Name of the reminder list"),
                    "title": PropertySchema(type: "string", description: "The reminder text"),
                    "notes": PropertySchema(type: "string", description: "Additional notes"),
                    "due_date": PropertySchema(type: "string", description: "Due date (YYYY-MM-DD or natural language like 'today', 'tomorrow')"),
                    "priority": PropertySchema(type: "string", description: "Priority level", enumValues: ["none", "low", "medium", "high"]),
                ], required: ["list", "title"])
            ),
            MCPToolDefinition(
                name: "complete_reminder",
                description: "Mark a reminder as complete",
                inputSchema: JSONSchema(type: "object", properties: [
                    "list": PropertySchema(type: "string", description: "Name of the reminder list"),
                    "index": PropertySchema(type: "string", description: "Index number or external ID of the reminder"),
                ], required: ["list", "index"])
            ),
            MCPToolDefinition(
                name: "uncomplete_reminder",
                description: "Mark a reminder as incomplete",
                inputSchema: JSONSchema(type: "object", properties: [
                    "list": PropertySchema(type: "string", description: "Name of the reminder list"),
                    "index": PropertySchema(type: "string", description: "Index number or external ID of the reminder"),
                ], required: ["list", "index"])
            ),
            MCPToolDefinition(
                name: "delete_reminder",
                description: "Delete a reminder",
                inputSchema: JSONSchema(type: "object", properties: [
                    "list": PropertySchema(type: "string", description: "Name of the reminder list"),
                    "index": PropertySchema(type: "string", description: "Index number or external ID of the reminder"),
                ], required: ["list", "index"])
            ),
            MCPToolDefinition(
                name: "edit_reminder",
                description: "Edit an existing reminder",
                inputSchema: JSONSchema(type: "object", properties: [
                    "list": PropertySchema(type: "string", description: "Name of the reminder list"),
                    "index": PropertySchema(type: "string", description: "Index number or external ID of the reminder"),
                    "title": PropertySchema(type: "string", description: "New title text"),
                    "notes": PropertySchema(type: "string", description: "New notes"),
                ], required: ["list", "index"])
            ),
            MCPToolDefinition(
                name: "create_list",
                description: "Create a new reminder list",
                inputSchema: JSONSchema(type: "object", properties: [
                    "name": PropertySchema(type: "string", description: "Name for the new list"),
                ], required: ["name"])
            ),
        ]

        return tools.compactMap { tool in
            guard let data = try? encoder.encode(tool),
                  let json = try? decoder.decode(JSONValue.self, from: data) else { return nil }
            return json
        }
    }

    // MARK: - Tool Dispatch

    private func callTool(name: String, arguments args: [String: JSONValue]) async -> MCPToolResult {
        do {
            switch name {
            case "show_lists":
                let lists = await store.lists()
                let text = lists.map(\.title).joined(separator: "\n")
                return MCPToolResult(text: text.isEmpty ? "No reminder lists found." : text)

            case "show_reminders":
                guard let listName = args["list"]?.stringValue() else {
                    return MCPToolResult(text: "Missing required parameter: list", isError: true)
                }
                let includeCompleted = args["include_completed"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? false
                let onlyCompleted = args["only_completed"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? false
                let reminders = try await store.reminders(inList: listName, includeCompleted: includeCompleted, onlyCompleted: onlyCompleted)
                let jsonData = try encoder.encode(reminders)
                return MCPToolResult(text: String(data: jsonData, encoding: .utf8) ?? "[]")

            case "show_all_reminders":
                let includeCompleted = args["include_completed"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? false
                let onlyCompleted = args["only_completed"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? false
                let reminders = try await store.reminders(includeCompleted: includeCompleted, onlyCompleted: onlyCompleted)
                let jsonData = try encoder.encode(reminders)
                return MCPToolResult(text: String(data: jsonData, encoding: .utf8) ?? "[]")

            case "add_reminder":
                guard let listName = args["list"]?.stringValue(),
                      let title = args["title"]?.stringValue() else {
                    return MCPToolResult(text: "Missing required parameters: list, title", isError: true)
                }
                let notes = args["notes"]?.stringValue()
                let dueDate = args["due_date"]?.stringValue().flatMap { parseDate($0) }
                let priority = args["priority"]?.stringValue().flatMap { ReminderPriority(rawValue: $0) } ?? .none
                let draft = ReminderDraft(title: title, notes: notes, dueDate: dueDate, priority: priority)
                let item = try await store.addReminder(draft, toList: listName)
                let jsonData = try encoder.encode(item)
                return MCPToolResult(text: String(data: jsonData, encoding: .utf8) ?? "{}")

            case "complete_reminder":
                guard let list = args["list"]?.stringValue(),
                      let index = args["index"]?.stringValue() else {
                    return MCPToolResult(text: "Missing required parameters: list, index", isError: true)
                }
                let item = try await store.setComplete(true, itemAtIndex: index, onList: list)
                return MCPToolResult(text: "Completed '\(item.title)'")

            case "uncomplete_reminder":
                guard let list = args["list"]?.stringValue(),
                      let index = args["index"]?.stringValue() else {
                    return MCPToolResult(text: "Missing required parameters: list, index", isError: true)
                }
                let item = try await store.setComplete(false, itemAtIndex: index, onList: list)
                return MCPToolResult(text: "Uncompleted '\(item.title)'")

            case "delete_reminder":
                guard let list = args["list"]?.stringValue(),
                      let index = args["index"]?.stringValue() else {
                    return MCPToolResult(text: "Missing required parameters: list, index", isError: true)
                }
                let title = try await store.delete(itemAtIndex: index, onList: list)
                return MCPToolResult(text: "Deleted '\(title)'")

            case "edit_reminder":
                guard let list = args["list"]?.stringValue(),
                      let index = args["index"]?.stringValue() else {
                    return MCPToolResult(text: "Missing required parameters: list, index", isError: true)
                }
                let newTitle = args["title"]?.stringValue()
                let newNotes = args["notes"]?.stringValue()
                if newTitle == nil && newNotes == nil {
                    return MCPToolResult(text: "Must specify at least title or notes to edit", isError: true)
                }
                let item = try await store.edit(itemAtIndex: index, onList: list, newText: newTitle, newNotes: newNotes)
                return MCPToolResult(text: "Updated '\(item.title)'")

            case "create_list":
                guard let name = args["name"]?.stringValue() else {
                    return MCPToolResult(text: "Missing required parameter: name", isError: true)
                }
                let list = try await store.createList(name: name)
                return MCPToolResult(text: "Created list '\(list.title)'")

            default:
                return MCPToolResult(text: "Unknown tool: \(name)", isError: true)
            }
        } catch {
            return MCPToolResult(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Response Helpers

    private func makeResponse(id: RequestID?, result: JSONValue) -> [String: JSONValue] {
        var response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "result": result,
        ]
        if let id {
            switch id {
            case .string(let s): response["id"] = .string(s)
            case .int(let i): response["id"] = .int(i)
            }
        }
        return response
    }

    private func makeErrorResponse(id: RequestID?, code: Int, message: String) -> [String: JSONValue] {
        var response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "error": .object([
                "code": .int(code),
                "message": .string(message),
            ]),
        ]
        if let id {
            switch id {
            case .string(let s): response["id"] = .string(s)
            case .int(let i): response["id"] = .int(i)
            }
        }
        return response
    }

    private func toolResultToJSON(_ result: MCPToolResult) -> JSONValue {
        let content: [JSONValue] = result.content.map { c in
            .object([
                "type": .string(c.type),
                "text": .string(c.text),
            ])
        }
        var obj: [String: JSONValue] = ["content": .array(content)]
        if let isError = result.isError, isError {
            obj["isError"] = .bool(true)
        }
        return .object(obj)
    }
}
```

**Step 3: Add --mcp flag to Main.swift**

Add to `RemindersTool`:
```swift
@Flag(help: "Run as MCP server over stdio")
var mcp = false

func run() async throws {
    if mcp {
        let store = RemindersStore()
        try await store.requestAccess()
        let server = MCPServer(store: store)
        await server.run()
    }
}
```

**Step 4: Verify it builds**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add Sources/RemindersCLI/MCPServer.swift Sources/RemindersCLI/MCPTypes.swift Sources/RemindersCLI/Main.swift
git commit -m "feat: add MCP server mode over stdio"
```

---

### Task 8: Info.plist for Reminder Permissions

**Files:**
- Create: `Sources/RemindersCLI/Resources/Info.plist`

The binary needs an embedded Info.plist with `NSRemindersUsageDescription` to trigger the macOS permissions dialog.

**Step 1: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSRemindersUsageDescription</key>
    <string>This app needs access to your reminders to manage them from the command line.</string>
</dict>
</plist>
```

**Step 2: Update Package.swift to embed the plist**

Add to the executable target's linkerSettings:
```swift
linkerSettings: [
    .unsafeFlags([
        "-Xlinker", "-sectcreate",
        "-Xlinker", "__TEXT",
        "-Xlinker", "__info_plist",
        "-Xlinker", "Sources/RemindersCLI/Resources/Info.plist",
    ]),
]
```

**Step 3: Verify it builds**

Run: `swift build 2>&1`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add Sources/RemindersCLI/Resources/Info.plist Package.swift
git commit -m "feat: embed Info.plist for Reminders permission dialog"
```

---

### Task 9: CLAUDE.md and README

**Files:**
- Create: `CLAUDE.md`

**Step 1: Create CLAUDE.md**

```markdown
# reminders-mcp

Drop-in replacement for `reminders-cli` using EventKit with async/await. Also serves as an MCP server.

## Build

```bash
swift build
```

## Run CLI

```bash
.build/debug/reminders show-lists
.build/debug/reminders show MyList
.build/debug/reminders add MyList Buy groceries
```

## Run as MCP server

```bash
.build/debug/reminders --mcp
```

## Test

```bash
swift test
```

## Architecture

- `RemindersCore` — Actor-based EventKit wrapper, no semaphores
- `RemindersCLI` — swift-argument-parser CLI + MCP server in one binary
- Single binary: `reminders`
```

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md with build and usage instructions"
```

---

### Task 10: End-to-End Smoke Test

**Manual verification steps (requires Reminders access):**

1. `swift build`
2. `.build/debug/reminders show-lists` — should print your reminder lists
3. `.build/debug/reminders add <list> "Test from CLI"` — should add a reminder
4. `.build/debug/reminders show <list>` — should show the new reminder
5. `.build/debug/reminders complete <list> 0` — should complete it
6. `.build/debug/reminders delete <list> 0` — should delete it
7. `echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | .build/debug/reminders --mcp` — should return MCP init response

**Step 1: Build and run smoke tests**

Run each command above, verify output matches expectations.

**Step 2: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address smoke test findings"
```
