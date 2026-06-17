#!/usr/bin/env bash
# bg-wake.sh — UserPromptSubmit wake hook for the `bgrun` wrapper (FALLBACK + retry).
#
# Primary delivery is now PUSH (bg-push.mjs, fired by bgrun's runner on completion):
# it resolves the ORIGIN chat and pushes the completion recap straight into it, so the
# agent auto-progresses in the RIGHT chat with no cross-session leak. This hook is the
# safety net:
#   1. a job already delivered by push (`.pushed`) -> ack, never re-announce;
#   2. otherwise RETRY the push here (resolve origin + deliver to the right chat) —
#      covers jobs whose done-time push failed (BFF was down) or predate the wiring;
#   3. only if the push still can't deliver (BFF down / origin unresolvable) fall back
#      to a pull-announce in the CURRENT chat (the old global behavior, last resort).
# The retry (2) is what kills the leak for non-pushed jobs: it sends to the job's
# origin, not the current chat.
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
    # (2) retry the push: resolve origin + deliver to the RIGHT chat (not this one).
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
