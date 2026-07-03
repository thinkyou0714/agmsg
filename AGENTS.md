# AGENTS.md — agmsg

Cross-vendor messaging for CLI AI coding agents — let Claude Code, Codex, Gemini & Copilot talk to
each other in one team. **Bash + SQLite, no daemon, no framework.**

- **Stack**: POSIX shell + `sqlite3` (message store); thin Node CLI entrypoint (`bin/agmsg.js`, Node `>=14`, zero npm deps). Skills under `plugins/`; a root `SKILL.md` ships the distributable skill.
- **Setup**: `.claude/bootstrap.sh` (SessionStart) is effectively a no-op (no lockfile / zero deps) — cloning is enough. `sqlite3` is pre-installed in the web sandbox.
- **Test**: `bats tests/` (Bats — Bash Automated Testing System; `test_*.bats`). Quick smoke: `npm test` (→ `node bin/agmsg.js --version`).
- **Layout**: `bin/` CLI · `scripts/` core (send/inbox/delivery/…) · `plugins/` per-agent shims · `tests/` bats · `docs/`.
- **Conventions**: see `CONTRIBUTING.md`; `bats (ubuntu-latest)` + `bats (macos-latest)` are required checks.

## Claude Code on the web

A cloud session loads this `AGENTS.md` + `.claude/skills/`. agmsg's runtime message store is a local
SQLite file, so a cloud session is for reading/editing/testing the code, not running a live team.
MCP is local-only. See `thinkyou0714/.github` → `docs/claude-code-web-readiness.md`.
