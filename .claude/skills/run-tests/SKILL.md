---
name: run-tests
description: Run the agmsg Bats test suite and summarize failures. Use when asked to test, verify, or check a change to the scripts/CLI.
---

Run the test suite and report concisely.

1. Ensure the runner is available: tests use **Bats** (`bats`). If missing, install it (`npm i -g bats` or the OS package) — `sqlite3` is pre-installed on web.
2. Run `bats tests/` (all `test_*.bats`). Single file: `bats tests/test_dispatch.bats`. Quick smoke: `npm test`.
3. Summarize: total pass/fail (Bats `ok`/`not ok`), and for each failure the test name + first failing line.
4. Do not edit scripts unless asked; the shell + SQLite escaping paths are load-bearing (see the safety tests).
