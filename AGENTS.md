# piebald-bgrun — agent rules

This project gives Piebald the equivalent of Claude Code's `run_in_background`: fires
long tasks **detached** and notifies completion automatically, without blocking the
synchronous chat.

When working IN THIS repo:

- The 6 canonical artifacts live in `bin/`. The ones that actually run are **installed**
  in `~/bin/` (on the PATH) — `bin/` here is the **source**. Edited here? Run
  `bash install.sh` to reinstall, OR edit and copy the specific file to `~/bin/`.
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
with Claude Code internals and Piebald's architectural ceiling (wake is pull-on-next-turn,
not push-mid-turn).

End-to-end test: `bgrun "t" "sleep 4 && echo ok"` → `bash bin/bg-wake.sh`
(should inject `<background-task-status>` when `done` appears; 2nd call = silence,
idempotency via `.ack`).
