# Public OpenAPI endpoint design

## Goal

Expose the network server's REST contract as OpenAPI JSON at `GET /openapi` so
people and tools can discover the API without reading the source or README.

## Contract

- `GET /openapi` returns an OpenAPI 3.1 JSON document with status 200 and
  `Content-Type: application/json`.
- The endpoint is public and ignores the presence or absence of a bearer token.
  The REST and MCP operations described by the document remain authenticated.
- Serving the document does not request Reminders permission and does not touch
  EventKit.
- The document describes the seven `/api` operations, their query parameters,
  request bodies, success responses, JSON error responses, and HTTP bearer
  authentication.
- The document uses a relative server URL so it works unchanged for the default
  Tailscale address, bind overrides, and alternate ports.

## Implementation

Embed a static OpenAPI 3.1 JSON document in the `RemindersServer` target and
serve it from the existing router. Register it after request logging and before
bearer middleware; Hummingbird applies middleware only to endpoints registered
after the middleware is added. Keeping the document in Swift ensures `make
install`, which copies only the executable, cannot strand a resource bundle.

The specification is intentionally manual. Adding a route requires updating
both the router and document; endpoint tests pin the documented path set to make
drift visible. No OpenAPI-generation dependency is added.

## Testing

- An unauthenticated request returns 200, JSON content type, valid JSON, OpenAPI
  version 3.1, the exact REST path set, and the bearer security declaration.
- Existing REST and MCP authentication tests continue to return empty 401
  responses for missing or incorrect tokens.
- `make check` remains the canonical full gate with zero warnings.

## Non-goals

Swagger UI, YAML output, `/openapi.json`, automatic schema generation, and an
OpenAPI model for the JSON-RPC MCP endpoint are out of scope.
