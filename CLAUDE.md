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

## Test

```bash
make check   # canonical: build + full test suite
swift test
```

## Architecture

- `RemindersCore` - Actor-based EventKit wrapper, no semaphores
- `RemindersCLI` - swift-argument-parser CLI + MCP server in one binary
- `RemindersTestSupport` - shared in-memory fake of the EventKit seam; tests run without TCC
- Single binary: `reminders`
