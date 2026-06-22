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
| `enqueueShellNotification` + `commandQueue` | **D** `bg-push.mjs` (push) + **C** `bg-wake.sh` (fallback) | D resolves the origin chat from `app.db` and pushes the recap via the BFF `POST /chats/:id/send` → the ORIGIN chat auto-continues. C is the safety net: retries the push, else pull-announces. |
| `notified` flag | **D/C** `.pushed` (push delivered) + `.ack` (pull announced) per job | written before/after delivery → idempotent |
| size-watchdog (768GB) | (n/a) | short jobs; common sense. Can be added later |

### 3.1 Why `bgrun` and not `bg`
`bg` is a **bash job-control builtin** (alongside `fg`/`jobs`) and has **precedence
over PATH** even in non-interactive shells. An executable `~/bin/bg` would never be
reached — the builtin intercepts ("bg: no job control"). Hence `bgrun`.

### 3.2 Cheap hook gate + queue model (revised 2026-06-22)
`bg-wake-hook.cmd` (Windows) only spawns git-bash if the sentinel
`~/.piebald-bg/.pending` exists. No pending job → exit ~5ms, zero spawn.

The wake hook is **queue-driven**, not sweep-driven (this is the core of the
2026-06-22 fix — see progress-log). The detached runner, on completion, appends the
job id to `~/.piebald-bg/.queue` (the FIFO that IS Piebald's `commandQueue`) and
raises `.pending`. `bg-wake.sh` reads **only** that queue (snapshot via rename, drain,
clear `.pending`) — it **never scans `~/.piebald-bg/*/`**. So its runtime is
**O(jobs-completed-since-last-turn)**, independent of how many job folders have
accumulated. The old design swept every dir; even fork-free that costs ~3ms/dir of
`stat()` under Windows Defender (200 dirs ≈ 600ms; the real bug was orphan folders
that never cleared `.pending`, so the sweep ran on **every** prompt → 42–56s freeze,
measured 2026-06-22). Folder GC / orphan reaping / TTL kills live in `bg-clean`, run
**detached** by bgrun at launch (off the chat path) and manually — never in the hook.

### 3.3 No-orphan guarantee
`bgrun`'s runner installs a `trap` that writes the `done` sentinel (+rc) and enqueues
on EXIT/INT/TERM, so a crashed or group-killed runner can never become an orphan that
holds `.pending` forever. `bg-kill` writes a synthetic `done` (rc=143) and enqueues.
Hard SIGKILL (taskkill /F) bypasses the trap; that residue is reaped by `bg-clean`'s
pid-liveness sweep (`kill -0` on the recorded group-leader pid).

### 3.4 Bash invocation in Piebald/Windows hooks
The `cmd /C` that Piebald uses to run hooks has a **minimal PATH, without git-bash**.
So the `.cmd` calls bash via the 8.3 path: `C:\PROGRA~1\Git\bin\bash.exe`. (`Get-Command
bash` is misleading — it inherits the parent shell's PATH.)

---

## 4. Push — auto-progression in the ORIGIN chat (the §4 ceiling, refuted)

> **⚠️ ROLLED BACK 2026-06-17.** The push below works *mechanically* but was disabled:
> a BFF-issued WS send renders live on **no** surface — not even the origin chat's own
> UI (the BFF is a separate connection → the client cache gate drops it everywhere →
> refresh-only). Only the pull hook (§3 C) renders live. The active trio is pull-only;
> the leak is accepted. See `docs/LIMITATION-cross-client-live-render.md`. The rest of
> this section is kept as the (valid) reverse-engineering of the push mechanism.

Earlier this doc claimed true push was impossible in Piebald and that the best
achievable was pull-on-next-`UserPromptSubmit`. **That was wrong** — refuted by
reverse-engineering the `piebald-mobile-mod` BFF (the bridge to Piebald's internal
WebSocket). Push IS possible, and the trio now does it.

### 4.1 The mechanism
The BFF (`piebald-mobile-mod`, HTTP on `127.0.0.1:8788`) wraps Piebald's WS
`send_message_streaming` as `POST /chats/:id/send` `{text, queue_type}`. Posting a
message into a chat id **triggers a real generation** in that chat — the agent there
"wakes" and continues, exactly like Claude Code's `commandQueue` injection, but
delivered to the **specific origin chat** (no cross-session leak).

- `queue_type:"next_iteration"` → engine `queue_type:"yield"`. Proven on win-work
  2026-06-17: into an **idle** chat it fires a fresh turn; into a **working** chat it
  queues for the next iteration without interrupting or branching. (The other surface
  modes: `after_loop`→`followup`; `interrupt`→omit/immediate. We always use
  `next_iteration` — deliver cleanly without cutting a running loop.)
- The `/send` HTTP response **hangs** on the stream; the send still fires. So the push
  is **fire-and-forget** with a short abort (~1.5s; localhost delivery is <100ms).

### 4.2 The identity problem (and the solution)
Piebald gives the terminal **no chat id** (env has only `TERM_PROGRAM=piebald`) and the
hook payload carries none. But `app.db.message_part_tool_call.tool_input` stores every
terminal tool call's command text, joinable to `chats` via `message_parts → messages`.
So at **done-time** (the bgrun launch row is committed by then), we resolve the origin:
the `RunTerminalCommand` whose `tool_input` contains the job's command **verbatim**,
nearest in time to the job's `start` epoch → origin `chat_id`. A literal command match
is required (no time-only fallback — that risks mis-binding to the wrong chat); if
nothing matches, we return nothing and let the pull hook announce. Proven 2026-06-17
(resolved to chat 653; an unresolvable synthetic job correctly returned no binding).

### 4.3 What still can't be done
The push is **pull-triggered from the runner's own completion**, not a Piebald event
loop — but the effect is the Claude-Code loop: fire → go silent → on completion the
ORIGIN chat auto-continues, with **no user input required** and **no leak**. The only
hard dependency is the BFF being up (the `remote-control` skill manages it). BFF down →
graceful fall back to the old pull-on-next-turn announce.

---

## 5. Where everything lives (host win-work)

- **Installed scripts:** `~/bin/` (on the git-bash PATH). Canonical source: this repo's `bin/`.
- **Push (piece D):** `~/bin/bg-push.mjs` (Node 24 one-shot, `node:sqlite` for the
  origin-chat resolve, `fetch` for the BFF POST). Invoked by bgrun's detached runner on
  completion, and retried by `bg-wake.sh`. Depends on the `piebald-mobile-mod` BFF
  (`127.0.0.1:8788`, default port on this host; code default 8787 — bg-push tries both).
  Bring the BFF up with the `remote-control` skill. node:sqlite is used (not the scoop
  `sqlite3` shim, which junctions/deadlocks here — same robust path as
  `piebald-dynamic-subagents/hooks/pretooluse-route.mjs`).
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
