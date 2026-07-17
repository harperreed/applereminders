# Handoff: network-server branch final review

Updated 2026-07-17. Branch `network-server`.

## Current state

All 13 tasks in `docs/plans/2026-07-17-network-server.md` are implemented and committed. The implementation HEAD before this handoff commit is `5161abb` (`docs: add network server docs and smoke test`). The next step is the whole-branch review, followed by `make check`, branch-finish review, and Doctor Biz's integration choice.

The most recent canonical gate passed 240 tests in 36 suites with zero warnings. `scripts/serve-smoke.sh` passed a real tailscale REST/MCP cycle and deleted its probe reminder. `reminders agent install` was deliberately not run.

## Tasks 9 through 13

- Task 9: `3987942..a595c4d`, REST write endpoints. Independent spec and quality review passed after fixing Hummingbird 413 preservation and adding non-null PATCH due-date coverage.
- Task 10: `a126ab7`, stateless MCP over HTTP. Controller spec and quality review passed.
- Task 11: `026081b`, serve command. Controller TDD, live, quality, and fresh-eyes review passed.
- Task 12: `ea86818`, launchd agent management. Controller TDD, safe CLI, quality, and fresh-eyes review passed. Added XML path escaping, safe process-pipe draining, LaunchAgents directory creation, and truthful bootout failure handling.
- Task 13: `5161abb`, smoke script and docs. Controller live, quality, and fresh-eyes review passed. The smoke script safely cleans partial probes and encodes JSON and reminder ids.

Task 10 onward used controller review because every new subagent turn failed before reading files with: `Your access token could not be refreshed because you have since logged out or signed in to another account.` Do not describe those reviews as independent.

## Local artifacts

- Generated `~/.config/reminders-mcp/token` for the live smoke. Directory mode is 700; file mode is 600. The token was not printed into conversation logs.
- No LaunchAgent plist was installed or bootstrapped.
- Task 11's plan command placed a token directly under `/tmp`, which conflicts with the required 700 parent-directory rule. The live check used a private `mktemp -d` directory instead.
- Cross-machine tailscale checks remain manual.

## Accumulated minor findings for final triage

- T3: MCP parse-error log text differs from the envelope; entry-point tests use substring JSON assertions.
- T4: one by-id due-date test depends on fake reminder ordering; one pre-existing delete doc comment is awkward.
- T5: `HTTPJSON.swift` creates a fresh encoder per response; one middleware test could assert 503 specifically.
- T6: token loading conflates a missing file with non-UTF-8 contents.
- T7: one brief-mandated test reads live `getifaddrs` state.
- T8: one REST list-filter test lacks an explicit 200 assertion; the completion-mode test does not assert `.completed` for its only-completed case.
- T10: the `tools/list` HTTP test asserts content without an explicit 200 assertion.

## Final-review commands

```bash
git diff --check 06b82d1..HEAD
make check
bash -n scripts/serve-smoke.sh
grep -rnE '—|–' Package.swift Sources Tests scripts README.md CLAUDE.md || true
```

The ignored SDD ledger is `.superpowers/sdd/progress.md`. Task reports and review packages are under `.superpowers/sdd/`.
