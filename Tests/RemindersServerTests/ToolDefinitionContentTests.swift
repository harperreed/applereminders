// ABOUTME: Guards the truthfulness of MCP tool definitions against actual handler behavior.
// ABOUTME: Locks in stable-id addressing guidance and honest index semantics for LLM clients.

import Foundation
import Testing

@testable import RemindersServer

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

    @Test("edit_reminder schema advertises the phase 2 parameters")
    func editReminderSchemaParams() throws {
        let definitions = MCPServer.buildToolDefinitions()
        let edit = try #require(definitions.first(where: { $0.name == "edit_reminder" }))
        let properties = try #require(edit.inputSchema.properties)
        #expect(properties["due_date"] != nil)
        #expect(properties["clear_due_date"] != nil)
        #expect(properties["priority"]?.enum == ["none", "low", "medium", "high"])
        #expect(properties["move_to_list"] != nil)
        #expect(properties["include_completed"] != nil)
        #expect(edit.description.contains("include_completed"))
        #expect(!edit.description.contains("Only incomplete reminders can be targeted"))
    }

    @Test("delete_reminder schema advertises include_completed")
    func deleteReminderSchemaParams() throws {
        let definitions = MCPServer.buildToolDefinitions()
        let delete = try #require(definitions.first(where: { $0.name == "delete_reminder" }))
        let properties = try #require(delete.inputSchema.properties)
        #expect(properties["include_completed"] != nil)
        #expect(!delete.description.contains("Only incomplete reminders can be targeted"))
    }

    @Test("show tools advertise due_before and due_after")
    func showToolsDueWindowParams() throws {
        let definitions = MCPServer.buildToolDefinitions()
        for name in ["show_reminders", "show_all_reminders"] {
            let tool = try #require(definitions.first(where: { $0.name == name }))
            let properties = try #require(tool.inputSchema.properties)
            #expect(properties["due_before"] != nil, "\(name) missing due_before")
            #expect(properties["due_after"] != nil, "\(name) missing due_after")
        }
    }
}
