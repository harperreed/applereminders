// ABOUTME: Tests for RemindersError error descriptions and conformances.
// ABOUTME: Verifies that every error case produces a human-readable, actionable message.

import Foundation
import Testing

@testable import RemindersCore

@Suite("RemindersError")
struct RemindersErrorTests {

    @Test("accessDenied has an actionable error description")
    func accessDenied() {
        let error = RemindersError.accessDenied
        let description = error.errorDescription ?? ""
        #expect(description.contains("denied"))
        #expect(description.contains("System Settings"))
    }

    @Test("writeOnlyAccess mentions full access and System Settings")
    func writeOnlyAccess() {
        let error = RemindersError.writeOnlyAccess
        let description = error.errorDescription ?? ""
        #expect(description.contains("write access"))
        #expect(description.contains("full access"))
        #expect(description.contains("System Settings"))
    }

    @Test("listNotFound includes the list name")
    func listNotFound() {
        let error = RemindersError.listNotFound("Shopping")
        let description = error.errorDescription ?? ""
        #expect(description.contains("Shopping"))
        #expect(description.contains("list"))
    }

    @Test("reminderNotFound includes the identifier")
    func reminderNotFound() {
        let error = RemindersError.reminderNotFound("abc-123")
        let description = error.errorDescription ?? ""
        #expect(description.contains("abc-123"))
        #expect(description.contains("reminder"))
    }

    @Test("operationFailed includes the reason")
    func operationFailed() {
        let error = RemindersError.operationFailed("disk full")
        let description = error.errorDescription ?? ""
        #expect(description.contains("disk full"))
    }

    @Test("all error cases produce non-nil, non-empty descriptions")
    func allCasesHaveDescriptions() {
        let errors: [RemindersError] = [
            .accessDenied,
            .writeOnlyAccess,
            .listNotFound("test"),
            .reminderNotFound("test"),
            .operationFailed("test"),
        ]

        for error in errors {
            #expect(error.errorDescription != nil, "Missing description for \(error)")
            #expect(!error.errorDescription!.isEmpty, "Empty description for \(error)")
        }
    }

    @Test("Equatable works for all cases")
    func equatable() {
        #expect(RemindersError.accessDenied == RemindersError.accessDenied)
        #expect(RemindersError.accessDenied != RemindersError.writeOnlyAccess)
        #expect(RemindersError.listNotFound("A") == RemindersError.listNotFound("A"))
        #expect(RemindersError.listNotFound("A") != RemindersError.listNotFound("B"))
        #expect(RemindersError.reminderNotFound("x") == RemindersError.reminderNotFound("x"))
        #expect(RemindersError.reminderNotFound("x") != RemindersError.reminderNotFound("y"))
        #expect(RemindersError.operationFailed("x") == RemindersError.operationFailed("x"))
        #expect(RemindersError.operationFailed("x") != RemindersError.operationFailed("y"))
    }
}
