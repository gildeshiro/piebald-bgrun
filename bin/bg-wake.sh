#!/usr/bin/env bash
# bg-wake.sh — UserPromptSubmit wake hook for the `bgrun` wrapper.
#
# Scans ~/.piebald-bg/*/done entries not yet acknowledged, prints a
# <background-task-status> block to stdout (Piebald/Claude Code inject this on the
# next turn -> the agent "wakes up" and sees completion without polling). Marks .ack
# per job to prevent repetition. Replicates enqueueShellNotification + the `notified`
# flag from Claude Code, but pull-on-next-turn instead of push-mid-turn.
#
# CONTRACT (identical to userpromptsubmit-wake.sh in octo-fullstep):
#   NON-FATAL  — always exits 0; never blocks a prompt
#   FAST       — glob + stat, zero network
#   IDEMPOTENT — .ack prevents re-injection
#   GATE       — removes .pending when no live jobs remain (cuts future spawns)
trap 'exit 0' ERR INT TERM

BG_ROOT="${PIEBALD_BG_ROOT:-$HOME/.piebald-bg}"
[[ -d "$BG_ROOT" ]] || exit 0
shopt -s nullglob

NOTES=()
ALIVE=0
for d in "$BG_ROOT"/*/; do
  job="$(basename "$d")"
  if [[ -f "$d/done" ]]; then
    [[ -f "$d/.ack" ]] && continue
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
