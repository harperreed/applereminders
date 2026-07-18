# reminders-mcp

One binary that is both a CLI for macOS Reminders and an MCP server. It is a
drop-in replacement for [keith/reminders-cli](https://github.com/keith/reminders-cli),
rebuilt on EventKit with Swift 6 async/await (actors, no semaphores), and it
speaks the Model Context Protocol, so Claude Code, Claude Desktop, or any other
MCP client can manage your reminders too.

## Install

### Homebrew

```sh
brew install harperreed/tap/applereminders
```

The binary installs as `reminders`. Heads up: keith/reminders-cli installs a
binary with the same name, so pick one or the other.

If macOS Gatekeeper blocks the downloaded binary:

```sh
xattr -d com.apple.quarantine "$(which reminders)"
```

### From source

```sh
git clone https://github.com/harperreed/applereminders.git
cd applereminders
make install   # release build into /usr/local/bin (override with PREFIX=...)
```

## Reminders access (TCC)

The first command that touches your reminders triggers the macOS permission
prompt. macOS records the grant against the app that launched the process: your
terminal (Terminal.app, iTerm2, Ghostty, whatever you use) for CLI use, or the
MCP host app for server use.

Manage grants in System Settings under Privacy & Security > Reminders. If a
grant gets stuck, `tccutil reset Reminders` clears every app's grant and each
one re-prompts on next use.

If access is denied, CLI commands exit with an error on stderr. MCP tool calls
return an error result that tells the model how to fix it, and the server
stays up.

## CLI usage

```sh
reminders show-lists                        # list names, one per line
reminders show Groceries                    # incomplete reminders, numbered from 0
reminders show Groceries --only-completed
reminders show Groceries --include-completed
reminders show Groceries --due-date today
reminders show-all                          # every list at once
reminders add Groceries Oat milk            # title = the remaining words
reminders add Groceries -d tomorrow -p high Call the dentist
reminders complete Groceries 0
reminders uncomplete Groceries 0            # index counts COMPLETED reminders only
reminders delete Groceries 2
reminders edit Groceries 1 New title text
reminders edit Groceries 1 -n "new note"
reminders edit Groceries 1 -d tomorrow -p high  # options only: title stays
reminders edit Groceries 1 --clear-due-date
reminders edit Groceries 1 --move-to Projects
reminders delete Groceries 2 --include-completed
reminders new-list Projects
reminders new-list Projects --source iCloud
```

Put options (`-d`, `-p`, `-n`) before the title words in `add` and `edit`.
Everything after the first word that is not an option becomes part of the title.

`edit` changes only what you pass: title words, `-n` notes, `-d` due date,
`--clear-due-date`, `-p` priority, or `--move-to LIST`. Add `--include-completed`
to `edit` or `delete` to target completed reminders; the index then counts the
combined view from `show --include-completed`, while stable ids keep working
unchanged.

### Targeting a reminder: index vs id

`complete`, `uncomplete`, `delete`, and `edit` take either a zero-based index
from `show` or a stable id in the same argument slot.

Indexes are positional and shift as reminders change. `complete`, `delete`, and
`edit` count the incomplete view; `uncomplete` counts the completed view
(`show <list> --only-completed`).

The stable id is the `id` field in `show <list> --format json`. It survives
reordering, which makes it the better choice for scripts.

### Dates

`--due-date` / `-d` accepts: `today`, `tomorrow`, `next week`, `yyyy-MM-dd`,
`yyyy-MM-dd HH:mm`, `MM/dd/yyyy`, `MM/dd`. A time component also sets an alarm
at that time. The commands reject dates they cannot parse instead of silently
dropping the filter.

### JSON output

`show`, `show-all`, `show-lists`, and `add` take `--format json`
(pretty-printed, sorted keys, ISO 8601 dates).

## MCP server

Run `reminders --mcp` for JSON-RPC 2.0 over stdio, one message per line.

Claude Code:

```sh
claude mcp add reminders -- "$(which reminders)" --mcp
```

Any other MCP client:

```json
{
  "mcpServers": {
    "reminders": {
      "command": "/opt/homebrew/bin/reminders",
      "args": ["--mcp"]
    }
  }
}
```

### Tools

| Tool | What it does |
|---|---|
| `show_lists` | All reminder lists (id + title) |
| `show_reminders` | Reminders in one list; `include_completed` / `only_completed` flags |
| `show_all_reminders` | Reminders across every list |
| `add_reminder` | Create with title, notes, due date, priority |
| `complete_reminder` | Mark complete (by stable id or index) |
| `uncomplete_reminder` | Reopen (by stable id, or index into the completed view) |
| `delete_reminder` | Delete permanently; returns the deleted reminder as JSON. `include_completed` targets completed ones |
| `edit_reminder` | Change title, notes, due date (set or clear), priority, or list |
| `create_list` | Create a new reminder list |

Every reminder object includes a stable `id`, and models should pass that back
to the mutating tools instead of a positional index. The server watches
EventKit change notifications, so edits made in the Reminders app show up
without a restart.

`show_reminders` and `show_all_reminders` also take `due_before` and
`due_after` (day-granular, same date formats as the CLI) to narrow results
to a due-date window.

## Compatibility with keith/reminders-cli

Core command names and positional index semantics match upstream. The
deliberate additions are `--mcp` mode, stable-id addressing, `edit`,
`--include-completed` / `--only-completed`, and `--due-date` filtering.
Confirmation strings differ slightly, so check the actual output before you
script against it.

## Development

```sh
make check    # canonical: swift build + swift test
make build    # debug build
make test     # test suite only
bash scripts/mcp-freshness-smoke.sh   # e2e freshness check (needs TCC grant)
```

The package separates EventKit domain logic (`RemindersCore`), MCP and HTTP
serving (`RemindersServer`), the swift-argument-parser executable
(`reminders`), and the shared in-memory test fake (`RemindersTestSupport`).
Notes for coding agents live in [CLAUDE.md](CLAUDE.md).

## Network server

`reminders serve` runs an HTTP server that exposes the same reminder tools over
the network. One listener exposes three surfaces:

- `POST /mcp`: MCP over Streamable HTTP (stateless: no sessions, no SSE)
- `/api/*`: a JSON REST API
- `GET /openapi`: public OpenAPI 3.1 JSON for the REST surface

### Setup

```bash
# one time: create the bearer token (saved to ~/.config/reminders-mcp/token, mode 600)
reminders serve --generate-token

# run in the foreground
reminders serve

# or keep it running via launchd (runs at login, restarts on crashes)
reminders agent install
reminders agent status
reminders agent uninstall
```

`serve --generate-token` prints the token once, but it is not ephemeral: it is
saved to `~/.config/reminders-mcp/token` and you can read it back anytime with
`cat ~/.config/reminders-mcp/token`. To rotate it, delete that file and
generate again; `--generate-token` refuses to overwrite an existing token, so
you cannot clobber it by accident. Rotating invalidates every client using the
old token.

The server binds the Mac's tailscale interface by default and refuses to start
without one. `--bind` overrides the interface, `--port` overrides the default
7364, and `--token-file` overrides the token path
(`~/.config/reminders-mcp/token`).

### Connect an MCP client

```bash
claude mcp add --transport http reminders \
  "http://<tailscale-ip>:7364/mcp" \
  --header "Authorization: Bearer <token>"
```

### REST API

Every REST and MCP request needs `Authorization: Bearer <token>`; `/openapi`
is public. REST errors: 401 with an empty body; 400, 404, and 500 with
`{"error": "message"}`.

| Method and path | Body / query | Returns |
| --- | --- | --- |
| GET /api/lists | | all lists |
| GET /api/reminders | query: `list`, `completed` (false, all, only), `due_before`, `due_after` | reminders (default: incomplete, all lists) |
| POST /api/reminders | `{list, title, notes?, due_date?, priority?}` | 201 + the new reminder |
| PATCH /api/reminders/{id} | any of `{title, notes, due_date, priority, list}`; `"due_date": null` clears it | the updated reminder |
| POST /api/reminders/{id}/complete | | the completed reminder |
| POST /api/reminders/{id}/uncomplete | | the reopened reminder |
| DELETE /api/reminders/{id} | | the deleted reminder |

Fetch the public OpenAPI document:

```bash
curl -fsS \
  http://<tailscale-ip>:7364/openapi | jq
```

Dates accept the CLI formats (`today`, `tomorrow`, `next week`, `2030-01-15`,
`2030-01-15 09:30`, `01/15/2030`, `01/15`). Priorities: `none`, `low`,
`medium`, `high`. Reminder ids come from the API's own responses.

### Security model

- No built-in TLS: tailscale (WireGuard) encrypts the transport, and the default
  listener binds only the tailscale interface. If you override `--bind`, keep
  the listener on a trusted network or provide TLS in front of it; never expose
  the plain HTTP port directly to an untrusted network.
- No Origin checking: DNS rebinding can let a hostile page reach the listener,
  but the page does not know the bearer token. Cross-origin Authorization
  headers also require a preflight that this server does not authorize, so the
  request never reaches a reminder route.
- Request logs are one line each (method, path, status, duration); bodies and tokens are never logged.
- launchd caveat: macOS ties Reminders access to the binary's path and
  signature. Rebuilding or moving the binary can silently re-trigger the
  permission prompt, which nobody sees under launchd; the server then fails
  until you run the binary by hand and re-grant access. `reminders agent
  status` shows the last exit state.

### Smoke test

```bash
scripts/serve-smoke.sh                       # starts .build/debug/reminders serve itself
scripts/serve-smoke.sh http://100.x.y.z:7364 # or target a running server
```

## Author

Harper Reed ([harper@modest.com](mailto:harper@modest.com))

## License

[MIT](LICENSE)
