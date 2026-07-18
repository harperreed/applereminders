# Public OpenAPI Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the REST API's OpenAPI 3.1 document from public `GET /openapi` without touching EventKit.

**Architecture:** Add one focused source file containing the embedded JSON document and a response builder. Register the route after global request logging but before bearer middleware; Hummingbird middleware applies only to endpoints registered after it. An in-memory endpoint test validates public access, no TCC access, media type, path/operation coverage, and the bearer security declaration for the APIs described by the document.

**Tech Stack:** Swift 6, Hummingbird 2, Swift Testing, OpenAPI 3.1 JSON.

## Global Constraints

- `GET /openapi` is public; `/api/*` and `/mcp` retain the existing bearer-token requirement and empty 401 behavior.
- A successful response is status 200 with `Content-Type: application/json`.
- The document describes exactly the five REST paths and seven operations; MCP, Swagger UI, YAML, and `/openapi.json` are out of scope.
- Serving the document must not request Reminders permission or access EventKit.
- Add no dependency and no runtime resource file; `make install` copies only the executable.
- `make check` is the canonical final gate and must add zero warnings.

---

### Task 1: Serve the public OpenAPI document

**Files:**
- Create: `Tests/RemindersServerTests/OpenAPIEndpointTests.swift`
- Create: `Sources/RemindersServer/OpenAPISpec.swift`
- Modify: `Sources/RemindersServer/RemindersServerApp.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `buildRouter(store:token:log:)`, order-scoped `BearerTokenMiddleware`, Hummingbird `Response`, and `ByteBuffer`.
- Produces: internal `let openAPISpecJSON: String` and `func openAPISpecResponse() -> Response`.

- [ ] **Step 1: Write the failing endpoint contract test**

Create `Tests/RemindersServerTests/OpenAPIEndpointTests.swift`:

```swift
// ABOUTME: End-to-end tests for the public GET /openapi endpoint.
// ABOUTME: Validates the embedded document's routes and bearer security without TCC.

import Foundation
import EventKit
import Hummingbird
import HummingbirdTesting
import Testing
@testable import RemindersServer

@Suite("OpenAPI endpoint")
struct OpenAPIEndpointTests {

    @Test func isPublicAndDescribesEveryRESTOperation() async throws {
        let (backend, store) = makeTestStore()
        backend.authorizationStatus = .denied
        let app = makeTestApp(store: store)

        try await app.test(.router) { client in
            try await client.execute(uri: "/openapi", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")

                let data = Data(String(buffer: response.body).utf8)
                let document = try #require(
                    JSONSerialization.jsonObject(with: data) as? [String: Any]
                )
                #expect(document["openapi"] as? String == "3.1.0")

                let servers = try #require(document["servers"] as? [[String: Any]])
                #expect(servers.first?["url"] as? String == "/")

                let paths = try #require(document["paths"] as? [String: Any])
                let expectedOperations: [String: Set<String>] = [
                    "/api/lists": ["get"],
                    "/api/reminders": ["get", "post"],
                    "/api/reminders/{id}": ["patch", "delete"],
                    "/api/reminders/{id}/complete": ["post"],
                    "/api/reminders/{id}/uncomplete": ["post"],
                ]
                #expect(Set(paths.keys) == Set(expectedOperations.keys))
                for (path, methods) in expectedOperations {
                    let item = try #require(paths[path] as? [String: Any])
                    #expect(Set(item.keys) == methods)
                }

                let components = try #require(document["components"] as? [String: Any])
                let schemes = try #require(components["securitySchemes"] as? [String: Any])
                let bearer = try #require(schemes["bearerAuth"] as? [String: Any])
                #expect(bearer["type"] as? String == "http")
                #expect(bearer["scheme"] as? String == "bearer")

                let schemas = try #require(components["schemas"] as? [String: Any])
                #expect(Set(schemas.keys) == [
                    "ReminderList",
                    "ReminderItem",
                    "CreateReminderRequest",
                    "PatchReminderRequest",
                    "Priority",
                    "Error",
                ])

                let security = try #require(document["security"] as? [[String: Any]])
                #expect(security.first?["bearerAuth"] is [Any])
            }
        }

        #expect(backend.accessRequestCount == 0)
    }
}
```

- [ ] **Step 2: Run the endpoint test and verify RED**

Run:

```bash
swift test --filter OpenAPIEndpointTests
```

Expected: the unauthenticated request fails with status 404 rather than 200.

- [ ] **Step 3: Add the embedded OpenAPI document**

Create `Sources/RemindersServer/OpenAPISpec.swift`:

```swift
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
```

- [ ] **Step 4: Register the route before bearer middleware**

In `Sources/RemindersServer/RemindersServerApp.swift`, replace the existing global middleware block:

```swift
    // Request logging is public so it covers /openapi and authenticated routes.
    router.middlewares.add(RequestLogMiddleware(log: log))

    router.get("openapi") { _, _ -> Response in
        openAPISpecResponse()
    }

    // Hummingbird middleware applies only to routes registered after this call.
    router.middlewares.add(BearerTokenMiddleware(token: token))
```

This ordering keeps request logging on every route, leaves `/openapi` public,
and preserves bearer authentication for the `/api` and `/mcp` routes registered
afterward. The route also remains outside `RemindersAccessMiddleware`.

- [ ] **Step 5: Run the endpoint test and verify GREEN**

Run:

```bash
swift test --filter OpenAPIEndpointTests
```

Expected: 1 test passes with zero warnings.

- [ ] **Step 6: Document discovery and usage**

In `README.md`, add `/openapi` to the network-server surface list:

```markdown
- `GET /openapi`: public OpenAPI 3.1 JSON for the REST surface
```

Replace the REST authentication introduction with:

```markdown
Every REST and MCP request needs `Authorization: Bearer <token>`; `/openapi`
is public. REST errors: 401 with an empty body; 400, 404, and 500 with
`{"error": "message"}`.
```

After the REST endpoint table, add:

````markdown
Fetch the public OpenAPI document:

```bash
curl -fsS \
  http://<tailscale-ip>:7364/openapi | jq
```
````

- [ ] **Step 7: Run the canonical gate**

Run:

```bash
make check
bash -n scripts/serve-smoke.sh
git diff --check
```

Expected: all 241 tests pass in 37 suites, build output has zero warnings, shell syntax passes, and `git diff --check` prints nothing.

- [ ] **Step 8: Run a live public request**

Run:

```bash
.build/debug/reminders serve &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
TAILSCALE_IP=$(ifconfig | awk '
  /inet 100\./ {
    split($2, octets, ".")
    if (octets[2] >= 64 && octets[2] <= 127) {print $2; exit}
  }
')
curl -fsS "http://$TAILSCALE_IP:7364/openapi" \
  | jq -e '.openapi == "3.1.0" and (.paths | length == 5)'
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
trap - EXIT
```

Expected: `jq` prints `true`; the server exits; no token is needed and response bodies do not enter request logs.

- [ ] **Step 9: Commit**

```bash
git add Sources/RemindersServer/OpenAPISpec.swift \
  Sources/RemindersServer/RemindersServerApp.swift \
  Tests/RemindersServerTests/OpenAPIEndpointTests.swift \
  README.md
git commit -m "feat: serve public OpenAPI spec"
```
