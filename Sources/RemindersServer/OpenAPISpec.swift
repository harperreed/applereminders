// ABOUTME: Embedded OpenAPI 3.1 document for the REST network surface.
// ABOUTME: Kept in the executable so binary-only installs can always serve it.

import Hummingbird
import NIOCore

let openAPISpecJSON = #"""
{
  "openapi": "3.1.0",
  "info": {
    "title": "reminders-mcp REST API",
    "version": "1.0.0",
    "description": "Manage Apple Reminders over an authenticated Tailscale HTTP service."
  },
  "servers": [{"url": "/"}],
  "security": [{"bearerAuth": []}],
  "paths": {
    "/api/lists": {
      "get": {
        "operationId": "listReminderLists",
        "summary": "List reminder lists",
        "responses": {
          "200": {
            "description": "All reminder lists",
            "content": {
              "application/json": {
                "schema": {"type": "array", "items": {"$ref": "#/components/schemas/ReminderList"}}
              }
            }
          },
          "401": {"$ref": "#/components/responses/Unauthorized"},
          "500": {"$ref": "#/components/responses/ServerError"}
        }
      }
    },
    "/api/reminders": {
      "get": {
        "operationId": "listReminders",
        "summary": "List and filter reminders",
        "parameters": [
          {"name": "list", "in": "query", "schema": {"type": "string"}},
          {
            "name": "completed",
            "in": "query",
            "schema": {"type": "string", "enum": ["false", "all", "only"], "default": "false"}
          },
          {
            "name": "due_before",
            "in": "query",
            "description": "Inclusive upper bound in a supported CLI date format.",
            "schema": {"type": "string"}
          },
          {
            "name": "due_after",
            "in": "query",
            "description": "Inclusive lower bound in a supported CLI date format.",
            "schema": {"type": "string"}
          }
        ],
        "responses": {
          "200": {
            "description": "Matching reminders",
            "content": {
              "application/json": {
                "schema": {"type": "array", "items": {"$ref": "#/components/schemas/ReminderItem"}}
              }
            }
          },
          "400": {"$ref": "#/components/responses/BadRequest"},
          "401": {"$ref": "#/components/responses/Unauthorized"},
          "404": {"$ref": "#/components/responses/NotFound"},
          "500": {"$ref": "#/components/responses/ServerError"}
        }
      },
      "post": {
        "operationId": "createReminder",
        "summary": "Create a reminder",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {"schema": {"$ref": "#/components/schemas/CreateReminderRequest"}}
          }
        },
        "responses": {
          "201": {"$ref": "#/components/responses/Reminder"},
          "400": {"$ref": "#/components/responses/BadRequest"},
          "401": {"$ref": "#/components/responses/Unauthorized"},
          "404": {"$ref": "#/components/responses/NotFound"},
          "500": {"$ref": "#/components/responses/ServerError"}
        }
      }
    },
    "/api/reminders/{id}": {
      "patch": {
        "operationId": "updateReminder",
        "summary": "Update a reminder",
        "parameters": [{"$ref": "#/components/parameters/ReminderID"}],
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {"schema": {"$ref": "#/components/schemas/PatchReminderRequest"}}
          }
        },
        "responses": {
          "200": {"$ref": "#/components/responses/Reminder"},
          "400": {"$ref": "#/components/responses/BadRequest"},
          "401": {"$ref": "#/components/responses/Unauthorized"},
          "404": {"$ref": "#/components/responses/NotFound"},
          "500": {"$ref": "#/components/responses/ServerError"}
        }
      },
      "delete": {
        "operationId": "deleteReminder",
        "summary": "Delete a reminder",
        "parameters": [{"$ref": "#/components/parameters/ReminderID"}],
        "responses": {
          "200": {"$ref": "#/components/responses/Reminder"},
          "401": {"$ref": "#/components/responses/Unauthorized"},
          "404": {"$ref": "#/components/responses/NotFound"},
          "500": {"$ref": "#/components/responses/ServerError"}
        }
      }
    },
    "/api/reminders/{id}/complete": {
      "post": {
        "operationId": "completeReminder",
        "summary": "Complete a reminder",
        "parameters": [{"$ref": "#/components/parameters/ReminderID"}],
        "responses": {
          "200": {"$ref": "#/components/responses/Reminder"},
          "401": {"$ref": "#/components/responses/Unauthorized"},
          "404": {"$ref": "#/components/responses/NotFound"},
          "500": {"$ref": "#/components/responses/ServerError"}
        }
      }
    },
    "/api/reminders/{id}/uncomplete": {
      "post": {
        "operationId": "uncompleteReminder",
        "summary": "Mark a reminder incomplete",
        "parameters": [{"$ref": "#/components/parameters/ReminderID"}],
        "responses": {
          "200": {"$ref": "#/components/responses/Reminder"},
          "401": {"$ref": "#/components/responses/Unauthorized"},
          "404": {"$ref": "#/components/responses/NotFound"},
          "500": {"$ref": "#/components/responses/ServerError"}
        }
      }
    }
  },
  "components": {
    "securitySchemes": {
      "bearerAuth": {"type": "http", "scheme": "bearer"}
    },
    "parameters": {
      "ReminderID": {
        "name": "id",
        "in": "path",
        "required": true,
        "description": "Stable EventKit reminder identifier.",
        "schema": {"type": "string"}
      }
    },
    "schemas": {
      "ReminderList": {
        "type": "object",
        "required": ["id", "title"],
        "properties": {
          "id": {"type": "string"},
          "title": {"type": "string"}
        }
      },
      "ReminderItem": {
        "type": "object",
        "required": ["id", "title", "isCompleted", "priority", "dueDate", "listID", "listName"],
        "properties": {
          "id": {"type": "string"},
          "title": {"type": "string"},
          "notes": {"type": "string"},
          "isCompleted": {"type": "boolean"},
          "completionDate": {"type": "string", "format": "date-time"},
          "priority": {"$ref": "#/components/schemas/Priority"},
          "dueDate": {"type": ["string", "null"], "format": "date-time"},
          "listID": {"type": "string"},
          "listName": {"type": "string"}
        }
      },
      "CreateReminderRequest": {
        "type": "object",
        "required": ["list", "title"],
        "properties": {
          "list": {"type": "string"},
          "title": {"type": "string", "minLength": 1},
          "notes": {"type": "string"},
          "due_date": {"type": "string", "description": "A supported CLI date string."},
          "priority": {"$ref": "#/components/schemas/Priority"}
        }
      },
      "PatchReminderRequest": {
        "type": "object",
        "properties": {
          "title": {"type": "string"},
          "notes": {"type": "string"},
          "due_date": {
            "type": ["string", "null"],
            "description": "A supported CLI date string, or null to clear the due date."
          },
          "priority": {"$ref": "#/components/schemas/Priority"},
          "list": {"type": "string"}
        }
      },
      "Priority": {
        "type": "string",
        "enum": ["none", "low", "medium", "high"]
      },
      "Error": {
        "type": "object",
        "required": ["error"],
        "properties": {"error": {"type": "string"}}
      }
    },
    "responses": {
      "Reminder": {
        "description": "A reminder snapshot",
        "content": {
          "application/json": {"schema": {"$ref": "#/components/schemas/ReminderItem"}}
        }
      },
      "BadRequest": {
        "description": "Invalid request",
        "content": {
          "application/json": {"schema": {"$ref": "#/components/schemas/Error"}}
        }
      },
      "Unauthorized": {"description": "Missing or incorrect bearer token"},
      "NotFound": {
        "description": "Reminder or list not found",
        "content": {
          "application/json": {"schema": {"$ref": "#/components/schemas/Error"}}
        }
      },
      "ServerError": {
        "description": "Reminders access or operation failed",
        "content": {
          "application/json": {"schema": {"$ref": "#/components/schemas/Error"}}
        }
      }
    }
  }
}
"""#

func openAPISpecResponse() -> Response {
    Response(
        status: .ok,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string: openAPISpecJSON))
    )
}
