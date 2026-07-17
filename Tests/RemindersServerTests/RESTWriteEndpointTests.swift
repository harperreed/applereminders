// ABOUTME: End-to-end tests for the REST write endpoints (create, patch, complete, delete).
// ABOUTME: Covers happy paths, validation 400s, unknown-id 404s, and due_date patch semantics.

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

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []

        var lines: [String] { lock.withLock { _lines } }

        func append(_ line: String) {
            lock.withLock { _lines.append(line) }
        }
    }

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

    @Test func oversizedCreateBodyIs413AndLogs413() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let logBox = LogBox()
        let app = Application(
            router: buildRouter(store: store, token: testToken, log: { logBox.append($0) })
        )
        let body = #"{"list":"Chores","title":""#
            + String(repeating: "x", count: 2 * 1024 * 1024)
            + #""}"#

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: body)
            ) { response in
                #expect(response.status == .contentTooLarge)
            }
        }

        let line = try #require(logBox.lines.first)
        #expect(line.contains("POST /api/reminders 413"))
        #expect(backend.savedReminders.isEmpty)
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

    @Test func patchDueDateSetsIt() async throws {
        let (backend, store) = makeTestStore()
        backend.addCalendar(named: "Chores")
        let expectedDate = try #require(parseDate("2031-02-03"))
        let app = makeTestApp(store: store)

        try await app.test(.router) { client in
            let id = try await client.execute(
                uri: "/api/reminders",
                method: .post,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"list": "Chores", "title": "Undated"}"#)
            ) { response -> String in
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.dueDate == nil)
                return item.id
            }

            try await client.execute(
                uri: "/api/reminders/\(id)",
                method: .patch,
                headers: authHeaders,
                body: ByteBuffer(string: #"{"due_date": "2031-02-03"}"#)
            ) { response in
                #expect(response.status == .ok)
                let item = try decodeBody(ReminderItem.self, from: response)
                #expect(item.dueDate == expectedDate)
            }
        }

        let persisted = try #require(backend.currentReminders.first)
        #expect(persisted.dueDateComponents?.year == 2031)
        #expect(persisted.dueDateComponents?.month == 2)
        #expect(persisted.dueDateComponents?.day == 3)
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

    @Test func completionAndDeleteUnknownIDsAre404() async throws {
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
                uri: "/api/reminders/no-such-id/uncomplete",
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
                #expect(response.status == .ok)
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
