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

Add to Claude Code settings:
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
swift test
```

## Architecture

- `RemindersCore` — Actor-based EventKit wrapper, no semaphores
- `RemindersCLI` — swift-argument-parser CLI + MCP server in one binary
- Single binary: `reminders`
