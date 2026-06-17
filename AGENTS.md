# piebald-bgrun — agent rules

This project gives Piebald the equivalent of Claude Code's `run_in_background`: fires
long tasks **detached** and notifies completion automatically, without blocking the
synchronous chat.

When working IN THIS repo:

- The 7 canonical artifacts live in `bin/`. The ones that actually run are **installed**
  in `~/bin/` (on the PATH) — `bin/` here is the **source**. Edited here? Run
  `bash install.sh` to reinstall, OR edit and copy the specific file to `~/bin/`.
- Piece **D** = `bin/bg-push.mjs` (PUSH to the origin chat) was built + tested, then
  **ROLLED BACK 2026-06-17** and is **NOT installed/wired**. Reason: a BFF-issued WS
  send renders live on **no** surface (not even the origin chat's own UI — the BFF is a
  separate connection, so the React cache gate drops it everywhere → refresh-only). The
  trio is back to the **original pull hook** (`bg-wake.sh` stdout-announce in the
  current chat; the cross-session leak is accepted as the lesser evil since the pull
  hook is the only path that renders live). `bin/bg-push.mjs` stays in-repo as a
  documented experiment; see `docs/LIMITATION-cross-client-live-render.md`. So the
  **active** trio is A (directive) + B (`bgrun`) + C (`bg-wake.sh` pull).
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
