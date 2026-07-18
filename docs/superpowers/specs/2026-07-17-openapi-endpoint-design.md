# Authenticated OpenAPI endpoint design

## Goal

Expose the network server's REST contract as OpenAPI JSON at `GET /openapi` so
people and tools can discover the API without reading the source or README.

## Contract

- `GET /openapi` returns an OpenAPI 3.1 JSON document with status 200 and
  `Content-Type: application/json`.
- The existing global bearer-token middleware protects the endpoint. Missing or
  incorrect credentials return the existing empty 401 response.
- Serving the document does not request Reminders permission and does not touch
  EventKit.
- The document describes the seven `/api` operations, their query parameters,
  request bodies, success responses, JSON error responses, and HTTP bearer
  authentication.
- The document uses a relative server URL so it works unchanged for the default
  Tailscale address, bind overrides, and alternate ports.

## Implementation

Embed a static OpenAPI 3.1 JSON document in the `RemindersServer` target and
serve it from the existing router. Keeping it in Swift ensures `make install`,
which copies only the executable, cannot strand a separate resource bundle.

The specification is intentionally manual. Adding a route requires updating
both the router and document; endpoint tests pin the documented path set to make
drift visible. No OpenAPI-generation dependency is added.

## Testing

- An authenticated request returns 200, JSON content type, valid JSON, OpenAPI
  version 3.1, the exact REST path set, and the bearer security declaration.
- An unauthenticated request returns the existing empty 401 response.
- `make check` remains the canonical full gate with zero warnings.

## Non-goals

Swagger UI, YAML output, `/openapi.json`, automatic schema generation, and an
OpenAPI model for the JSON-RPC MCP endpoint are out of scope.
