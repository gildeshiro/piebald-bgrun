# system-prompt-directive

The exact text that **piece A** (`bin/apply-bg-directive.py`) appends to the
`system_prompt` of the Default profile. Approximately 1193 characters added at the
end of the existing system prompt, separated by `\n\n---\n\n`. The idempotency marker
is the line `## Background execution`.

In Piebald this is written to `app.db` (`base_gen_cfg_data.system_prompt`). In Claude
Code (linux-dev/phone) paste this same block into `~/.claude/CLAUDE.md` (global) or the
project's `AGENTS.md`/`CLAUDE.md`.

---

```markdown
## Background execution — run long tasks DETACHED (do not block the chat)

This host is Piebald: the terminal runs SYNCHRONOUSLY, so a long synchronous command
BLOCKS the chat (the user cannot send another message until it returns). Therefore,
when a task is long-running and non-blocking — builds, test suites, multi-LLM debates
(gemini/codex), large downloads, long scans — do NOT run synchronously: fire it
detached with the `bgrun` wrapper, by reflex, just as you would use run_in_background
in Claude Code.

- Launch: `bgrun "<short description>" "<full command>"` (or `bgrun "<command>"`).
  Returns immediately with a job-id; the chat stays free.
- Do NOT poll synchronously or sleep waiting. When the job finishes, the
  UserPromptSubmit hook injects a `<background-task-status>` block automatically in
  the next turn — trust that, do not keep checking.
- On demand: `bg-status [job-id]` (status) · `bg-kill <job-id>` (kill).
- Each job's output lives in `~/.piebald-bg/<job-id>/out` — read it with Read when
  the status arrives, only if you need the details.

Use your judgment: fast tasks (~<20s) run normally inline; long tasks go to `bgrun`.
This is a reflex — do not ask first.
```

---

## Apply / revert (Piebald, app.db)

```bash
python bin/apply-bg-directive.py            # append (idempotent, with automatic backup)
python bin/apply-bg-directive.py --revert   # remove the directive
python bin/apply-bg-directive.py --db <path># alternate app.db path
```

- Detects the `config_id` of the Default profile **dynamically** (does not hardcode 135).
- Automatic backup: `app.db.bak-<timestamp>` (+ `-wal`/`-shm`).
- Idempotent: if the marker already exists, this is a no-op.
- Activation: **new chat** (Piebald clones the profile config on chat creation).
