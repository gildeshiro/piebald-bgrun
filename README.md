# piebald-bgrun

Background execution for **Piebald** in the style of Claude Code's `run_in_background`.

Piebald's terminal runs **synchronously**: a long command blocks the chat until it
returns (no further messages can be sent). This project gives the agent the instinct to
fire long tasks **detached** (builds, test suites, multi-LLM debates, downloads) and be
**notified automatically** when they finish — without blocking the conversation or
requiring manual polling.

> Replicates the fluidity of Claude Code's `run_in_background` within Piebald's
> constraints (no event loop for unilateral notification injection). See
> [`docs/DESIGN.md`](docs/DESIGN.md) for the full anatomy, including how Claude Code
> implements it internally.

---

## The trio

True fluidity requires three independent pieces — each one covers a gap:

| Piece | What | Covers | File |
| --- | --- | --- | --- |
| **A** Trigger | Directive in the profile's **system prompt** (permanent reflex) | "when to fire" | `bin/apply-bg-directive.py` |
| **B** Wrapper | `bgrun` + `bg-status` + `bg-kill` | "easy to launch" | `bin/bgrun`, `bin/bg-status`, `bin/bg-kill` |
| **C** Wake | `UserPromptSubmit` hook that injects the completion notice | "learns it finished" | `bin/bg-wake.sh`, `bin/bg-wake-hook.cmd` |

Remove any piece and the system limps: A alone = knows to fire but checks manually;
B alone = easy to fire but you have to remember to check; A+B without C = missing the
"wake up on its own" part.

---

## Usage (after installation)

```bash
# fire detached, returns immediately with a job-id
bgrun "build do tmoney" "cargo build --release"

# ...the conversation continues normally...

# on the NEXT turn, the hook automatically injects:
#   <background-task-status>
#   ✅ background completed (exit 0) — "build do tmoney"  [job 20260611-...]  output: ~/.piebald-bg/.../out
#   </background-task-status>

# on demand:
bg-status            # lists all jobs and their status
bg-status <job-id>   # filter by job id
bg-kill  <job-id>    # targeted kill (by cmdline)
```

Invocation forms:
- `bgrun "<command>"` — the description defaults to the command itself.
- `bgrun "<short description>" "<full command>"` — explicit description.

Each job's state lives in `~/.piebald-bg/<job-id>/`:
```
cmd desc cwd   input
out            stdout+stderr combined (read with Read if you need the details)
start end      epoch
done           written LAST; contains the exit code (completion sentinel)
.ack           written by the hook upon notification (idempotency)
```

---

## Installation

```bash
bash install.sh            # installs B (wrappers) + C (hook) + A (directive in app.db)
bash install.sh --no-app   # skips piece A (does not touch app.db / system prompt)
bash install.sh --no-hook  # skips piece C (does not register the hook)
```

```bash
bash uninstall.sh          # reverts everything (restores app.db from backup, removes hook, deletes ~/bin/*)
```

Details and per-OS adaptation (Windows/Piebald vs Linux/phone/Claude Code) in
[`docs/DESIGN.md`](docs/DESIGN.md) and in the comments of each script.

### Activation
- **B (`bgrun`)** works immediately.
- **A (system prompt)** and **C (hook)** take effect in a **new chat** (Piebald clones the
  profile config and reloads hooks when a new chat is created). A chat opened *before*
  installation keeps the old cached state — open a new chat.

---

## Architectural limitation (honest)

Piebald has **no** event loop that injects messages mid-turn without user input. So the
wake is **pull on the next prompt**, not **push mid-generation** like Claude Code. In
practice this is nearly invisible (fire → converse → status appears), but if you fire
and go quiet for 10 min, the agent only "discovers" completion when you type again.
That is Piebald's ceiling — see `docs/DESIGN.md §4`.

---

## Layout

```
piebald-bgrun/
├── README.md
├── AGENTS.md                       # read by Piebald/Claude Code when the project is opened
├── install.sh / uninstall.sh
├── progress-log.md                 # local project tracking log
├── bin/
│   ├── bgrun  bg-status  bg-kill   # piece B
│   ├── bg-wake.sh  bg-wake-hook.cmd# piece C
│   └── apply-bg-directive.py       # piece A
└── docs/
    ├── DESIGN.md                   # run_in_background internals + anatomy of the trio
    └── system-prompt-directive.md  # the exact text injected into the system prompt
```
