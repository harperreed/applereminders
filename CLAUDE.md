# reminders-mcp

Drop-in replacement for `reminders-cli` using EventKit with async/await. Also serves as an MCP server.

## Build

```bash
swift build
```

## Run CLI

```bash
.build/debug/reminders show-lists
.build/debug/reminders show MyList
.build/debug/reminders add MyList Buy groceries
```

## Run as MCP server

```bash
.build/debug/reminders --mcp
```

Add to Claude Code:
```bash
claude mcp add reminders -- /path/to/reminders --mcp
```

Other MCP clients use the equivalent JSON config:
```json
{
  "mcpServers": {
    "reminders": {
      "command": "/path/to/reminders",
      "args": ["--mcp"]
    }
  }
}
```

## Run network server

```bash
.build/debug/reminders serve --generate-token   # first time: create the bearer token
.build/debug/reminders serve                    # MCP at /mcp, REST under /api, tailscale interface, port 7364
.build/debug/reminders agent install            # keep it running via launchd
```

Live smoke: `scripts/serve-smoke.sh` (TCC-dependent, best effort).

## Test

```bash
make check   # canonical: build + full test suite
swift test
```

## Architecture

- `RemindersCore` - Actor-based EventKit wrapper, no semaphores
- `RemindersServer` - MCP server (stdio and HTTP transports), Hummingbird REST layer, token file, tailscale discovery, launchd plist
- `RemindersCLI` - swift-argument-parser CLI; subcommands include `serve` and `agent`
- `RemindersTestSupport` - shared in-memory fake of the EventKit seam; tests run without TCC
- Single binary: `reminders`
