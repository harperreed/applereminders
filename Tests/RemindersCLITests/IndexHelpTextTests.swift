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
