#!/usr/bin/env bash
# bg-wake.sh — UserPromptSubmit wake hook for the `bgrun` wrapper (PRIMARY delivery).
#
# bgrun's runner does NOT push at completion (reverted 2026-06-17 by user decision —
# the runner is back to old/simple: fire detached + write `done` + `.pending`). This
# hook is what DELIVERS the completion, on the next UserPromptSubmit, to the ORIGIN
# chat that fired the job (resolve via bg-push.mjs → BFF append) — so it lands in the
# RIGHT chat, not whatever chat is currently active (no cross-session leak). Order:
#   1. a job already delivered (`.pushed`) -> ack, never re-announce;
#   2. else resolve the origin + append there via bg-push.mjs (deliver to the RIGHT
#      chat — this is the primary path, at hook/pull timing, not at done-time);
#   3. only if that can't deliver (BFF down / origin unresolvable) fall back to a
#      pull-announce in the CURRENT chat (the old global behavior, last resort).
#
# CONTRACT:
#   NON-FATAL  — always exits 0; never blocks a prompt
#   IDEMPOTENT — .pushed / .ack prevent re-delivery and re-injection
#   GATE       — removes .pending when no live jobs remain (cuts future spawns)
trap 'exit 0' ERR INT TERM

BG_ROOT="${PIEBALD_BG_ROOT:-$HOME/.piebald-bg}"
[[ -d "$BG_ROOT" ]] || exit 0
shopt -s nullglob

# node for the retry-push (the cmd /C hook PATH may lack it -> resolve explicitly)
NODE_BIN="$(command -v node 2>/dev/null || command -v node.exe 2>/dev/null || echo 'C:/PROGRA~1/nodejs/node.exe')"
BG_PUSH="$HOME/bin/bg-push.mjs"

NOTES=()
ALIVE=0
for d in "$BG_ROOT"/*/; do
  job="$(basename "$d")"
  if [[ -f "$d/done" ]]; then
    [[ -f "$d/.ack" ]] && continue
    # (1) already delivered to the origin chat via push -> never announce here.
    if [[ -f "$d/.pushed" ]]; then touch "$d/.ack" 2>/dev/null || true; continue; fi
    # (2) PRIMARY delivery: resolve the origin chat + append there (not this chat).
    if [[ -x "$NODE_BIN" || -f "$BG_PUSH" ]]; then
      "$NODE_BIN" "$BG_PUSH" "$d" >/dev/null 2>&1 || true
    fi
    if [[ -f "$d/.pushed" ]]; then touch "$d/.ack" 2>/dev/null || true; continue; fi
    # (3) true fallback (BFF down / unresolvable origin): pull-announce in this chat.
    # ack BEFORE emitting -> prevents double-fire if interrupted mid-write
    touch "$d/.ack" 2>/dev/null || true
    rc="$(cat "$d/done" 2>/dev/null || echo '?')"
    desc="$(cat "$d/desc" 2>/dev/null || echo "$job")"
    st="completed"; [[ "$rc" != "0" ]] && st="failed"
    NOTES+=("$st (exit $rc) — \"$desc\"  [job $job]  output: ${d}out")
  else
    ALIVE=$((ALIVE + 1))   # no done = still running -> keep .pending
  fi
done

# nothing alive anymore -> remove the gate marker; the .cmd hook stops spawning bash
[[ $ALIVE -eq 0 ]] && rm -f "$BG_ROOT/.pending" 2>/dev/null || true

if [[ ${#NOTES[@]} -gt 0 ]]; then
  echo "<background-task-status>"
  for n in "${NOTES[@]}"; do echo "✅ background $n"; done
  echo "Read the output file with Read only if you need the details. Do not poll synchronously."
  echo "</background-task-status>"
fi
exit 0
