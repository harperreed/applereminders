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
                #expect(response.status == .ok)
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
                #expect(response.status == .ok)
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title).sorted() == ["Closed", "Open"])
            }
            try await client.execute(uri: "/api/reminders?completed=only", method: .get, headers: authHeaders) { response in
                #expect(response.status == .ok)
                let items = try decodeBody([ReminderItem].self, from: response)
                #expect(items.map(\.title) == ["Closed"])
            }
        }
        #expect(backend.lastFetchKind == .completed)
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
                #expect(String(buffer: response.body).contains("No reminder list found"))
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
