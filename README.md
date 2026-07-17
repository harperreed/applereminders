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
reminders new-list Projects
reminders new-list Projects --source iCloud
```

Put options (`-d`, `-p`, `-n`) before the title words in `add` and `edit`.
Everything after the first word that is not an option becomes part of the title.

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
| `delete_reminder` | Delete permanently; returns the deleted reminder as JSON |
| `edit_reminder` | Change title and/or notes |
| `create_list` | Create a new reminder list |

Every reminder object includes a stable `id`, and models should pass that back
to the mutating tools instead of a positional index. The server watches
EventKit change notifications, so edits made in the Reminders app show up
without a restart.

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

The package has two targets: `RemindersCore`, an actor that wraps
`EKEventStore`, and the `reminders` executable, which holds the
swift-argument-parser CLI and the MCP server. Notes for coding agents live in
[CLAUDE.md](CLAUDE.md).

## Author

Harper Reed ([harper@modest.com](mailto:harper@modest.com))

## License

[MIT](LICENSE)
