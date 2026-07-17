# Network server design

Date: 2026-07-17
Status: approved by Harper (brainstorm 2026-07-17)
Feeds: implementation plan (writing-plans)

## Context

reminders-mcp currently offers a CLI and an MCP server over stdio. Harper works
remotely over tailscale and wants reminder management reachable over the
network, from both agents (MCP clients on other machines) and plain HTTP
consumers (curl, scripts, future UI). EventKit data and the TCC grant live on
this Mac, so the server runs here and network clients reach in.

SSH-forwarded stdio (`claude mcp add reminders -- ssh <mac> reminders --mcp`)
already works and remains available; the server earns its keep by removing the
SSH requirement, adding a REST surface, and running unattended.

## Decisions (made during brainstorm, in order)

1. Clients: both MCP clients and plain HTTP consumers. One server, two
   surfaces.
2. Access control: bind only to the tailscale interface AND require a bearer
   token on every request.
3. Lifecycle: launchd LaunchAgent for always-on operation, plus a foreground
   mode.
4. HTTP stack: Hummingbird 2 (Swift 6 native, SwiftNIO based). Dependency tree
   pinned by committing Package.resolved.

## Requirements

R1. `reminders serve` starts an HTTP server exposing `POST /mcp` (MCP
    Streamable HTTP transport) and a REST surface under `/api/`.
R2. Both surfaces call the same `RemindersStore` actor used by the CLI and
    stdio MCP mode. Stdio mode (`--mcp`) is unchanged.
R3. The listener binds to the Mac's tailscale interface address by default and
    refuses to start when no tailscale interface exists. `--bind` overrides
    (needed for tests and non-tailscale setups; overriding is an explicit act).
R4. Every request must carry `Authorization: Bearer <token>`. Missing or wrong
    token gets 401 with an empty error body. One middleware enforces this for
    both surfaces.
R5. The token lives in `~/.config/reminders-mcp/token` (file mode 600).
    `reminders serve --generate-token` creates it and prints it once.
    `--token-file` overrides the path.
R6. Default port 7364 ("REMI" on a phone keypad). `--port` overrides. At
    implementation time verify 7364 is not a registered/conflicting port on
    this machine; pick the next free thematic option if it is.
R7. `reminders agent install|uninstall|status` manages a LaunchAgent plist at
    `~/Library/LaunchAgents/com.harperreed.reminders-mcp.plist`: run at login,
    keep alive on crash, stdout/stderr to log files under
    `~/Library/Logs/reminders-mcp/`.
R8. No TLS in v1. Tailscale (WireGuard) encrypts transport; the spec's DNS
    rebinding concern is addressed by the bearer token (browsers cannot attach
    it), so no Origin checking. Document both rationales in the README.
R9. Server logs one line per request: method, path, status, duration. Never
    log request bodies, response bodies, or the token. The stdio-mode `recv:`
    logging is out of scope here but must not leak into the HTTP path.

## MCP over HTTP

- Each JSON-RPC message arrives as one `POST /mcp` with a JSON body and gets
  one `application/json` response. The handler feeds the same per-message
  dispatch the stdio loop uses; `MCPServer` exposes a per-message entry point
  (extracted from the run loop; the injectable I/O seam from phase 2 makes
  this a small internal refactor).
- Stateless: no `Mcp-Session-Id` issued or required, no SSE. `GET /mcp`
  returns 405. `DELETE /mcp` returns 405. The Streamable HTTP spec permits
  stateless servers that never push; this server never pushes.
- JSON-RPC notifications (requests without id, for example the
  `notifications/initialized` message) get 202 Accepted with an empty body.
- Tool errors remain MCP tool results with `isError: true`, exactly as in
  stdio mode. Protocol errors (-32700, -32601) remain JSON-RPC error
  responses with HTTP 200, per the transport spec.
- Client recipe (documented in README):
  `claude mcp add --transport http reminders http://<tailscale-ip>:7364/mcp
  --header "Authorization: Bearer <token>"`.

## REST surface

All under `/api/`, JSON in and out, addressed by the stable EventKit
`calendarItemIdentifier` values already present in every `ReminderItem`.

| Method and path | Body / params | Success | Notes |
| --- | --- | --- | --- |
| GET /api/lists | none | 200 `[ReminderList]` | |
| GET /api/reminders | query: `list` (optional; absent = all lists), `completed` = `false` (default) / `all` / `only`, `due_before`, `due_after` (CLI date formats) | 200 `[ReminderItem]` | reuses `filterByDueWindow` and the predicate-based fetches |
| POST /api/reminders | `{list, title, notes?, due_date?, priority?}` | 201 `ReminderItem` | priority strings: none/low/medium/high, as in the MCP tools |
| PATCH /api/reminders/{id} | any of `{title, notes, due_date, priority, list}`; `"due_date": null` clears it, absent leaves it untouched | 200 `ReminderItem` | maps onto `ReminderUpdate` (the `Date??` double optional); `notes` is set-only in v1, matching existing capability |
| POST /api/reminders/{id}/complete | none | 200 `ReminderItem` | |
| POST /api/reminders/{id}/uncomplete | none | 200 `ReminderItem` | |
| DELETE /api/reminders/{id} | none | 200 `ReminderItem` (the deleted item) | mirrors `delete_reminder` returning the deleted JSON |

Error mapping: 400 for validation failures (bad date, bad priority, missing
required field), 401 for auth (empty body, per R4), 404 for unknown id or
list, 500 for store failures. Error body for 400/404/500:
`{"error": "message"}` using the same message wording as the MCP tools where
an equivalent exists.

## Store additions (RemindersCore)

REST needs by-id addressing. `RemindersStore` gains:

- `func reminder(byID id: String) async throws -> ReminderItem`
- `func update(byID id: String, with update: ReminderUpdate) async throws -> ReminderItem`
- `func setCompleted(byID id: String, completed: Bool) async throws -> ReminderItem`
- `func delete(byID id: String) async throws -> ReminderItem`

The `EventStoreBackend` protocol gains one member for id lookup
(`calendarItem(withIdentifier:)` equivalent) and `FakeEventStoreBackend`
implements it, preserving the no-TCC test discipline. Unknown ids throw the
store's not-found error, surfaced as 404.

## New target layout

- `RemindersServer` (library): Hummingbird app builder, routes, bearer
  middleware, MCP transport glue, tailscale interface discovery.
- `RemindersCLI` gains the `serve` and `agent` subcommands, both thin
  wrappers over `RemindersServer`.
- `RemindersServerTests`: HummingbirdTesting in-memory client against
  `FakeEventStoreBackend`.
- Single `reminders` binary remains the only product.

## launchd notes

The plist runs `reminders serve` with the user's config. Known risk, stated
loudly in README and `agent install` output: TCC grants key on binary path and
signature, so an unsigned rebuild can silently re-trigger the Reminders
permission prompt, which no one sees under launchd (the server then fails with
the existing permission error). Mitigation: ad-hoc codesign with a stable
identifier (already on the phase 3 backlog); `agent status` surfaces the
last run's failure state so this is diagnosable.

## Testing requirements

- Unit: bearer middleware (missing/wrong/correct token), tailscale interface
  discovery (parse from injected interface list, no live network dependency),
  by-id store operations against the fake, PATCH null-vs-absent decoding.
- End to end (in-memory, no TCC): every REST endpoint happy path and error
  path; MCP-over-HTTP initialize, tools/list, tools/call, notification (202),
  parse error, unknown method; auth applied to both surfaces.
- Live smoke: `scripts/serve-smoke.sh` starts the server (or targets a
  running one), curls lists and a create/edit/delete cycle with the token,
  over the tailscale address. TCC-dependent, best effort, mirrors
  `mcp-freshness-smoke.sh` conventions.
- `make check` remains the canonical gate; zero new warnings.

## Non-goals (v1)

TLS, MCP sessions/SSE/server push, web UI, tailscale funnel or any public
exposure, rate limiting, multi-user support, notes clearing via PATCH. The
stateless MCP choice and single middleware keep all of these addable without
redesign.

## Success criteria

1. From another tailnet machine: `claude mcp add --transport http` connects,
   lists tools, and completes a full add/edit/clear/delete cycle.
2. From another tailnet machine: the curl cycle in `serve-smoke.sh` passes.
3. Requests without the token get 401 on every route.
4. The listener is not reachable on non-tailscale interfaces (default bind).
5. `reminders agent install` produces a server that survives logout/login and
   appears in `reminders agent status`.
6. `make check` green, zero warnings, no TCC required by the suite.
