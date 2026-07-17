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
