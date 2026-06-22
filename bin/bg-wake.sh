#!/usr/bin/env bash
# bg-wake.sh — UserPromptSubmit wake hook for the `bgrun` wrapper (QUEUE model).
#
# Mirrors Claude Code's commandQueue: completion is delivered through a tiny FIFO
# file (~/.piebald-bg/.queue) that the detached runner appends to when a job ends.
# This hook reads ONLY that queue — it NEVER scans ~/.piebald-bg/*/. So its runtime
# is O(jobs-completed-since-last-turn), not O(total-dirs): instant regardless of how
# many job folders have accumulated. (The old design swept every dir and, even
# fork-free, paid ~3ms/dir of stat() under Windows Defender → 200 dirs ≈ 600ms, which
# is what froze every prompt. Proven empirically on win-work 2026-06-22.)
#
# Folder GC / orphan reaping / TTL kills are NOT done here (they would force an O(N)
# sweep + forks). They live in `bg-clean`, run DETACHED by bgrun at launch and
# manually — off the synchronous chat path. This hook stays read-only + fork-free.
#
# CONTRACT:
#   NON-FATAL  — always exits 0; never blocks a prompt
#   INSTANT    — reads one queue file; no per-dir scan, no network
#   IDEMPOTENT — .ack per job prevents re-injection; queue is drained once (snapshot)
#   GATE       — removes .pending when the queue is empty (cuts future spawns)
trap 'exit 0' ERR INT TERM

BG_ROOT="${PIEBALD_BG_ROOT:-$HOME/.piebald-bg}"
QUEUE="$BG_ROOT/.queue"
PENDING="$BG_ROOT/.pending"

# Fast exit: nothing queued -> clear the gate and leave. The .cmd gate already
# short-circuits when .pending is absent, so this path is rarely even reached.
[[ -s "$QUEUE" ]] || { rm -f "$PENDING" 2>/dev/null || true; exit 0; }

# Snapshot the queue atomically so completions that land mid-drain are not lost:
# rename the live queue aside, then process the snapshot. New appends create a fresh
# .queue (+ .pending) and are caught on the next turn. (One `mv` fork — only on turns
# that actually have completions; idle turns never get here.)
SNAP="$QUEUE.$$"
mv "$QUEUE" "$SNAP" 2>/dev/null || { rm -f "$PENDING" 2>/dev/null || true; exit 0; }

NOTES=()
while IFS= read -r job; do
  [[ -n "$job" ]] || continue
  d="$BG_ROOT/$job"
  [[ -f "$d/done" ]] || continue          # folder GC'd or never finished -> skip
  [[ -f "$d/.ack" ]] && continue          # already announced -> idempotent
  : > "$d/.ack"                            # builtin redirection, no `touch` fork
  rc=""; read -r rc < "$d/done" 2>/dev/null || true; [[ -n "$rc" ]] || rc='?'
  desc=""; read -r desc < "$d/desc" 2>/dev/null || true; [[ -n "$desc" ]] || desc="$job"
  st="completed"; [[ "$rc" != "0" ]] && st="failed"
  NOTES+=("$st (exit $rc) — \"$desc\"  [job $job]  output: $d/out")
done < "$SNAP"

rm -f "$SNAP" 2>/dev/null || true
# Queue drained. If no fresh completion re-created .queue, clear the gate.
[[ -s "$QUEUE" ]] || rm -f "$PENDING" 2>/dev/null || true

if [[ ${#NOTES[@]} -gt 0 ]]; then
  echo "<background-task-status>"
  for n in "${NOTES[@]}"; do echo "✅ background $n"; done
  echo "Read the output file with Read only if you need the details. Do not poll synchronously."
  echo "</background-task-status>"
fi
exit 0
