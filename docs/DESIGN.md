# DESIGN — piebald-bgrun

Full anatomy: how Claude Code's `run_in_background` works internally, what Piebald
lacks, and how the trio (A/B/C) recreates that fluidity within its constraints.

---

## 1. How Claude Code implements `run_in_background` internally

Source: reading the BashTool/LocalShellTask source of Claude Code. What makes
`run_in_background` fluid are **two independent pieces**:

### 1.1 The trigger (the model knows to fire by reflex)
The tool description (`BashTool/prompt.ts`) instructs: "use `run_in_background` for
long commands; you will be notified when they finish — do not sleep/poll". This lives
in the system/tool-description, always present → becomes a reflex.

### 1.2 The decoupling (short-circuit)
When `run_in_background: true`, `BashTool` **does not enter the wait loop**. It spawns
the native process and calls `spawnBackgroundTask()`, which **returns immediately**
`{ backgroundTaskId, code: 0, stdout: '' }`. The tool call resolves instantly → the LLM
unblocks and continues.

Internally (`ShellCommand.background(taskId)`):
- disables the foreground **timeout** (otherwise it would kill long-running commands);
- **`spillToDisk()`**: redirects the child's stdout/stderr to write **directly to a
  file on disk**, bypassing RAM (avoids memory bloat for hour-long jobs);
- attaches a **size-watchdog** on the file (the source cites a "768GB" incident — a
  stuck loop filling the disk — that motivated this guard).

### 1.3 The wake (the notification that "wakes" the model)
A detached Promise (`void shellCommand.result.then(...)`) watches the process die.
When it dies, `enqueueShellNotification()` builds an XML block:
```xml
<task_notification>
  <task_id>0a1b</task_id>
  <output_file>/tmp/.../output.txt</output_file>
  <status>completed</status>
  <summary>"npm run build" completed (exit code 0)</summary>
</task_notification>
```
and pushes it into a **global message queue** (`commandQueue` via
`enqueuePendingNotification()`). The main event loop unilaterally injects that message
into the LLM context on the next turn. A per-task `notified` flag prevents duplication.

**The two pieces that matter:** (1.1) the trigger and (1.3) the wake. The decoupling
(1.2) is "just" I/O detachment.

---

## 2. What Piebald does NOT have

- **No native `run_in_background`.** The terminal (`RunTerminalCommand`) runs
  synchronously, in an embedded terminal, with no session persistence. A long
  synchronous command **blocks the chat**.
- **No unilateral injection event loop** (`commandQueue`) that "wakes" the model
  mid-turn. Nothing pushes a message into context without user input.

Therefore, moving the instruction to the system prompt solves **only the trigger (1.1)**.
The wake (1.3) must be recreated — and the piece that recreates it already exists in
the setup: the **`UserPromptSubmit`** hook (which the cluster already uses to inject
memories/cluster-notes). It is our `commandQueue`, but **pull-on-next-turn** instead of
**push-mid-turn**.

---

## 3. The trio — 1:1 mapping with Claude Code

| Claude Code | piebald-bgrun | How |
| --- | --- | --- |
| trigger (tool prompt) | **A** directive in system prompt | `apply-bg-directive.py` appends to `base_gen_cfg_data.system_prompt` of the Default profile |
| `spawnBackgroundTask` + detach | **B** `bgrun` | PowerShell `Start-Process` (Win) / `setsid` (Linux) — independent process that survives the tool call |
| `spillToDisk` (output to disk) | **B** `bgrun` | runner redirects `> out 2>&1`; state in `~/.piebald-bg/<job>/` |
| `enqueueShellNotification` + `commandQueue` | **C** `bg-wake.sh` | scans `*/done`, injects `<background-task-status>` into hook stdout |
| `notified` flag | **C** `.ack` per job | `touch .ack` before emitting → idempotent |
| size-watchdog (768GB) | (n/a) | short jobs; common sense. Can be added later |

### 3.1 Why `bgrun` and not `bg`
`bg` is a **bash job-control builtin** (alongside `fg`/`jobs`) and has **precedence
over PATH** even in non-interactive shells. An executable `~/bin/bg` would never be
reached — the builtin intercepts ("bg: no job control"). Hence `bgrun`.

### 3.2 Cheap hook gate
`bg-wake-hook.cmd` (Windows) only spawns git-bash if the sentinel
`~/.piebald-bg/.pending` exists. No pending job → exit ~5ms, zero spawn. `bg-wake.sh`
removes `.pending` when no jobs are still alive (no `done`). Mirrors the gate used in
the `fullstep-wake-hook.cmd` already proven on this host.

### 3.3 Bash invocation in Piebald/Windows hooks
The `cmd /C` that Piebald uses to run hooks has a **minimal PATH, without git-bash**.
So the `.cmd` calls bash via the 8.3 path: `C:\PROGRA~1\Git\bin\bash.exe`. (`Get-Command
bash` is misleading — it inherits the parent shell's PATH.)

---

## 4. Hard limitation (architectural ceiling)

Without a unilateral injection event loop, **true push mid-generation is not possible**.
The best achievable is **wake on the next `UserPromptSubmit`** (next time the user
types). The normal flow (fire → converse → status appears) hides this; but firing and
going silent for 10 min means the agent only sees completion when the user types again.
Anyone promising "real push" in Piebald is mistaken.

---

## 5. Where everything lives (host win-work)

- **Installed scripts:** `~/bin/` (on the git-bash PATH). Canonical source: this repo's `bin/`.
- **Registered hook:** `~/.claude/settings.json` → `UserPromptSubmit` (3rd hook,
  alongside `piebald-memory-selector.cmd` and `fullstep-wake-hook.cmd`).
- **Directive (piece A):** `app.db` at `%APPDATA%\piebald\app.db`, table
  `base_gen_cfg_data.system_prompt` for the `config_id` of the Default profile (id=1).
  Schema 2026-06: the system prompt migrated from `override_gen_cfg_data` →
  `base_gen_cfg_data`. The `config_id` **varies** (was 36, later 135) — that is why
  the script detects it dynamically.
- **Propagation:** editing the Default profile config propagates to every **new chat**
  (Piebald clones the config on chat creation). Verified: configs created after the
  edit were born with the directive.

---

## 6. Portability (Claude Code / linux-dev / phone)

- **B** (`bgrun`): already branches by OS (`Start-Process` on Windows; `setsid`/`nohup`
  elsewhere). Portable.
- **C** (hook): on Claude Code/Linux register `bg-wake.sh` directly as a
  `UserPromptSubmit` hook (no `.cmd` wrapper, which exists only for Piebald/Windows's
  minimal PATH).
- **A** (trigger): in **Claude Code there is no `app.db`** — the directive goes in
  `~/.claude/CLAUDE.md` (global) or the project's `AGENTS.md`/`CLAUDE.md`. In Piebald
  it is the `app.db` (the only path for strong adherence = the `system` field of the
  API).
