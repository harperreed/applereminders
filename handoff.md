# Handoff: network-server branch ready for integration

Updated 2026-07-17. Branch `network-server`.

## Current state

All 13 tasks in `docs/plans/2026-07-17-network-server.md` are implemented, audited, and committed. The reviewed implementation HEAD before this handoff update is `9e9907d` (`test: strengthen network endpoint coverage`). The branch is ready for Doctor Biz's integration choice.

The final canonical gate passed 240 tests in 36 suites with zero warnings. Shell syntax, `serve`/`agent` help, read-only agent status, branch whitespace checks, and local port availability passed. `scripts/serve-smoke.sh` previously passed a real tailscale REST/MCP cycle and deleted its probe reminder. `reminders agent install` was deliberately not run.

The direct whole-branch audit found and fixed two final gaps in `9e9907d`: the plan's dash gate in a touched source file, and the missing unknown-id error-path coverage for the REST uncomplete endpoint. It also strengthened exact HTTP status and completed-fetch assertions. Focused middleware, REST read/write, and MCP-over-HTTP suites passed after the changes.

## Tasks 9 through 13

- Task 9: `3987942..a595c4d`, REST write endpoints. Independent spec and quality review passed after fixing Hummingbird 413 preservation and adding non-null PATCH due-date coverage.
- Task 10: `a126ab7`, stateless MCP over HTTP. Controller spec and quality review passed.
- Task 11: `026081b`, serve command. Controller TDD, live, quality, and fresh-eyes review passed.
- Task 12: `ea86818`, launchd agent management. Controller TDD, safe CLI, quality, and fresh-eyes review passed. Added XML path escaping, safe process-pipe draining, LaunchAgents directory creation, and truthful bootout failure handling.
- Task 13: `5161abb`, smoke script and docs. Controller live, quality, and fresh-eyes review passed. The smoke script safely cleans partial probes and encodes JSON and reminder ids.

Task 10 onward used controller review because every new subagent turn failed before reading files with: `Your access token could not be refreshed because you have since logged out or signed in to another account.` The final roborev and web-connector attempts also failed on revoked authentication. Do not describe those reviews as independent.

## Local artifacts

- Generated `~/.config/reminders-mcp/token` for the live smoke. Directory mode is 700; file mode is 600. The token was not printed into conversation logs.
- No LaunchAgent plist was installed or bootstrapped.
- Task 11's plan command placed a token directly under `/tmp`, which conflicts with the required 700 parent-directory rule. The live check used a private `mktemp -d` directory instead.
- Cross-machine tailscale checks remain manual.
- The current IANA service-name registry had no entry for port 7364, and no local process was listening on it after verification.

## Deferred minor findings

- MCP entry-point tests still use substring JSON assertions rather than decoding envelopes.
- One by-id due-date test depends on fake reminder ordering; one older delete doc comment is awkward.
- `HTTPJSON.swift` creates a fresh encoder per response; this is harmless at the expected personal-server scale.
- Token loading conflates a missing file with non-UTF-8 contents.
- One plan-mandated tailscale smoke test reads live `getifaddrs` state.

## Final verification

```bash
git diff --check main..HEAD
make check
bash -n scripts/serve-smoke.sh
grep -rnE '—|–' Package.swift Sources Tests scripts README.md CLAUDE.md || true
```

Expected dash-gate output is limited to pre-existing matches in `Sources/RemindersCore/Models.swift` and `Tests/RemindersTestSupport/FakeEventStoreBackend.swift`, neither touched by this branch.

The ignored SDD ledger is `.superpowers/sdd/progress.md`. Task reports and review packages are under `.superpowers/sdd/`.
