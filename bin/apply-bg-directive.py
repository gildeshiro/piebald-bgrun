#!/usr/bin/env python3
# apply-bg-directive.py — appends the "background execution" directive to the system
# prompt of the Default profile in Piebald (table base_gen_cfg_data in app.db).
#
# Idempotent (BG_MARKER sentinel), makes a backup before writing, detects the
# config_id of the Default profile DYNAMICALLY (the id changes — never hardcode it).
#
# RECOMMENDED: run with Piebald CLOSED (avoids the in-memory cache overwriting the
# change). Running live works, but activation requires a new chat regardless.
#
# Usage:  python apply-bg-directive.py [--db <path>] [--revert]
import sqlite3, shutil, sys, os, datetime, argparse

DEFAULT_DB = os.path.expandvars(r"%APPDATA%\piebald\app.db")
BG_MARKER = "## Background execution"

DIRECTIVE = """

---

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
This is a reflex — do not ask first."""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--revert", action="store_true", help="remove the directive")
    args = ap.parse_args()

    db = args.db
    if not os.path.exists(db):
        sys.exit(f"app.db not found: {db}")

    # backup app.db + wal + shm
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    for suf in ("", "-wal", "-shm"):
        src = db + suf
        if os.path.exists(src):
            shutil.copy2(src, f"{src}.bak-{ts}")
    print(f"[backup] {db}.bak-{ts} (+ wal/shm if present)")

    con = sqlite3.connect(db, timeout=15)
    con.execute("PRAGMA busy_timeout=15000")
    cur = con.cursor()

    # config_id of the Default profile (dynamic)
    cur.execute("SELECT id,name,config_id FROM profiles WHERE name='Default' AND is_system=1")
    row = cur.fetchone()
    if not row:
        cur.execute("SELECT id,name,config_id FROM profiles ORDER BY id LIMIT 1")
        row = cur.fetchone()
    prof_id, prof_name, cfg_id = row
    print(f"[profile] {prof_name} (id={prof_id}) -> config_id={cfg_id}")

    cur.execute("SELECT system_prompt FROM base_gen_cfg_data WHERE gen_cfg_id=?", (cfg_id,))
    r = cur.fetchone()
    if not r:
        sys.exit(f"no base_gen_cfg_data for gen_cfg_id={cfg_id}")
    sp = r[0] or ""
    print(f"[before] system_prompt: {len(sp)} chars; marker present? {BG_MARKER in sp}")

    if args.revert:
        if BG_MARKER not in sp:
            print("[revert] marker not found — nothing to do."); con.close(); return
        new = sp.split("\n\n---\n\n" + BG_MARKER)[0]
        cur.execute("UPDATE base_gen_cfg_data SET system_prompt=? WHERE gen_cfg_id=?", (new, cfg_id))
        con.commit()
        print(f"[revert] removed -> {len(new)} chars")
        con.close(); return

    if BG_MARKER in sp:
        print("[idempotent] directive already present — no-op."); con.close(); return

    new = sp + DIRECTIVE
    cur.execute("UPDATE base_gen_cfg_data SET system_prompt=? WHERE gen_cfg_id=?", (new, cfg_id))
    con.commit()
    try:
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass

    # read-back verification
    cur.execute("SELECT length(system_prompt), instr(system_prompt,?) FROM base_gen_cfg_data WHERE gen_cfg_id=?", (BG_MARKER, cfg_id))
    ln, pos = cur.fetchone()
    con.close()
    print(f"[after] system_prompt: {ln} chars; marker at position {pos}")
    print("[ok] directive applied." if pos else "[FAIL] marker not found after write")
    print(">>> restart Piebald to activate (the profile is read when a new chat is created).")


if __name__ == "__main__":
    main()
