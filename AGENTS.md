# piebald-bgrun — agent rules

This project gives Piebald the equivalent of Claude Code's `run_in_background`: fires
long tasks **detached** and notifies completion automatically, without blocking the
synchronous chat.

When working IN THIS repo:

- The 7 canonical artifacts live in `bin/`. The ones that actually run are **installed**
  in `~/bin/` (on the PATH) — `bin/` here is the **source**. Edited here? Run
  `bash install.sh` to reinstall, OR edit and copy the specific file to `~/bin/`.
- Piece **D** = `bin/bg-push.mjs` (PUSH / auto-progression): on a job's completion the
  detached runner resolves the ORIGIN chat (from `app.db`) and pushes the recap into it
  via the `piebald-mobile-mod` BFF (`127.0.0.1:8788`) → that chat auto-continues, no
  cross-session leak. Needs the BFF up (`remote-control` skill); BFF down → `bg-wake.sh`
  pull fallback. Uses `node:sqlite` (NOT the scoop `sqlite3` shim — it deadlocks here).
- **DO NOT rename `bgrun` to `bg`**: `bg` is a bash job-control builtin with PATH
  precedence — the script would never be reached.
- Piece A (directive in the system prompt) is written to Piebald's `app.db` via
  `bin/apply-bg-directive.py` — **always with a backup** and dynamic `config_id`
  detection. Never hardcode the id (it varies). In Claude Code there is no `app.db`:
  the directive goes in CLAUDE.md/AGENTS.md.
- Hook in Piebald/Windows: invoke bash via the 8.3 path `C:\PROGRA~1\Git\bin\bash.exe`
  (the Piebald `cmd /C` has a minimal PATH without git-bash).
- Progress/tracking goes in `progress-log.md` (local), **not** in the memory daemon.

Read `docs/DESIGN.md` before touching the architecture — it explains the 1:1 mapping
with Claude Code internals. Note: the old "architectural ceiling" (pull-only, no push)
is **refuted** — §4 now documents real push into the origin chat via the BFF
(`send_message_streaming`). Pull (`bg-wake.sh`) is the fallback.

End-to-end test (push): `bgrun "t" "echo ok && sleep 3"` in a chat → the runner pushes
a `<background-task-status>` recap into THAT chat (verify: `~/.piebald-bg/<job>/.pushed`
+ `chat_id` written; the recap arrives as a new turn ONLY in the origin chat). Requires
the BFF up. Pull fallback test: `bash bin/bg-wake.sh` with a done job whose origin can't
be resolved → it pull-announces (idempotent via `.ack`).
