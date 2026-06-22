#!/usr/bin/env bash
# test-bg-clean.sh — acceptance harness for the queue-model bg-wake + bg-clean fix.
# Uses an ISOLATED PIEBALD_BG_ROOT (never touches the real ~/.piebald-bg).
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAKE="$REPO/bin/bg-wake.sh"
CLEAN="$REPO/bin/bg-clean"
export PIEBALD_BG_ROOT="$(mktemp -d)/bgroot"
mkdir -p "$PIEBALD_BG_ROOT"
ROOT="$PIEBALD_BG_ROOT"
now="$(date +%s)"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }
ms(){ local s e; s=$(date +%s%N); "$@" >/dev/null 2>&1; e=$(date +%s%N); echo $(( (e-s)/1000000 )); }
msmin(){ local n="$1"; shift; local best=999999 i v; for ((i=0;i<n;i++)); do v=$(ms "$@"); (( v<best )) && best=$v; done; echo "$best"; }

echo "ROOT=$ROOT"

# ---- T1: runtime must be O(1) in the number of accumulated dirs (the actual bug).
# The bash-startup floor (~200ms under Defender) dominates and is unavoidable for any
# bash hook; what matters is that runtime does NOT grow with N (old hook was O(N):
# ~42s at N=269). We also assert the script logic itself adds ~nothing over a bare
# bash launch. In production the .cmd gate skips bash entirely when .pending is absent.
echo "== T1: hook runtime is O(1) in dir count (empty queue) =="
mkroot(){ local n="$1" r; r="$(mktemp -d)/r"; mkdir -p "$r"; local i d; for i in $(seq 1 "$n"); do d="$r/j$i"; mkdir -p "$d"; : > "$d/cmd"; printf '0' > "$d/done"; : > "$d/.ack"; printf 'd%s' "$i" > "$d/desc"; done; echo "$r"; }
base=$(msmin 5 bash -c 'exit 0')
R0=$(mkroot 0);   export PIEBALD_BG_ROOT="$R0";   t0=$(msmin 5 bash "$WAKE")
R500=$(mkroot 500); export PIEBALD_BG_ROOT="$R500"; t500=$(msmin 5 bash "$WAKE")
export PIEBALD_BG_ROOT="$ROOT"
echo "  bash floor=${base}ms | hook N=0:${t0}ms | hook N=500:${t500}ms (min-of-5)"
# logic overhead above bash startup, at N=500, must be small (min filters spawn jitter)
over=$(( t500 - base )); (( over < 0 )) && over=0
echo "  script overhead over bash floor at N=500: ${over}ms"
(( over < 120 )) && ok "script logic adds <120ms even at N=500 (O(1), not O(N))" || no "script overhead ${over}ms"
# the decisive assertion: runtime at N=500 ~ N=0 (hook never scans dirs)
delta=$(( t500 - t0 )); (( delta < 0 )) && delta=$(( -delta ))
(( delta < 150 )) && ok "runtime flat across N (|N=500 - N=0|=${delta}ms)" || no "runtime grew with N (${t0}->${t500}ms)"
rm -rf "$(dirname "$R0")" "$(dirname "$R500")"

# .pending hygiene with dirs present but empty queue
for i in 1 2 3; do d="$ROOT/orphan-$i"; mkdir -p "$d"; : > "$d/cmd"; printf '999999' > "$d/pid"; printf '%s' "$((now-99999))" > "$d/start"; printf 'orph %s' "$i" > "$d/desc"; done
rm -f "$ROOT/.queue" "$ROOT/.pending"
bash "$WAKE" >/dev/null 2>&1
[[ -e "$ROOT/.pending" ]] && no ".pending should be absent" || ok ".pending absent when nothing queued"
# seed the 200 completed for the GC test later
for i in $(seq 1 200); do d="$ROOT/job-$i"; mkdir -p "$d"; : > "$d/cmd"; printf '0' > "$d/done"; : > "$d/.ack"; printf 'desc %s' "$i" > "$d/desc"; printf '%s' "$((now-99999))" > "$d/end"; done

# ---- T2: a real completion enqueued -> hook announces it once, then idempotent
echo "== T2: one queued completion -> announced once, then silent =="
d="$ROOT/job-live"; mkdir -p "$d"; : > "$d/cmd"; printf '0' > "$d/done"; printf 'meu build' > "$d/desc"; printf '%s' "$now" > "$d/end"
printf '%s\n' "job-live" > "$ROOT/.queue"; : > "$ROOT/.pending"
out1="$(bash "$WAKE" 2>/dev/null)"
echo "$out1" | grep -q 'meu build' && ok "announced the completion" || no "did not announce"
echo "$out1" | grep -q '<background-task-status>' && ok "emitted status block" || no "no status block"
[[ -f "$d/.ack" ]] && ok "marked .ack" || no "no .ack"
[[ -e "$ROOT/.pending" ]] && no ".pending should be cleared after drain" || ok ".pending cleared after drain"
out2="$(bash "$WAKE" 2>/dev/null)"
[[ -z "$out2" ]] && ok "second run silent (idempotent)" || no "re-announced: $out2"

# ---- T3: bg-clean GC — completed folders older than TTL_DONE are purged
echo "== T3: bg-clean GC purges old completed, keeps fresh =="
before=$(ls -d "$ROOT"/*/ 2>/dev/null | wc -l)
BG_TTL_DONE=10 BG_TTL_RUN=86400 bash "$CLEAN" >/dev/null 2>&1
after=$(ls -d "$ROOT"/*/ 2>/dev/null | wc -l)
echo "  dirs: $before -> $after"
(( after < before )) && ok "GC removed old completed dirs ($before->$after)" || no "GC removed nothing"
[[ -d "$ROOT/job-1" ]] && no "old job-1 should be gone" || ok "old completed purged"

# ---- T4: bg-clean reaps dead-pid orphans (recent -> announced; old -> purged)
echo "== T4: bg-clean reaps orphans =="
nowt4="$(date +%s)"   # fresh: the harness above can take >60s under Defender
# recent dead-pid orphan
r="$ROOT/orphan-recent"; mkdir -p "$r"; : > "$r/cmd"; printf '999999' > "$r/pid"; printf '%s' "$nowt4" > "$r/start"; printf 'orfa nova' > "$r/desc"
# old dead-pid orphan
o="$ROOT/orphan-old"; mkdir -p "$o"; : > "$o/cmd"; printf '999999' > "$o/pid"; printf '%s' "$((nowt4-99999))" > "$o/start"; printf 'orfa velha' > "$o/desc"
BG_TTL_DONE=600 BG_TTL_RUN=86400 bash "$CLEAN" >/dev/null 2>&1
[[ -f "$r/done" ]] && ok "recent orphan got synthetic done" || no "recent orphan not reaped"
grep -q 'orphan-recent' "$ROOT/.queue" 2>/dev/null && ok "recent orphan enqueued (will announce)" || no "recent orphan not enqueued"
[[ -d "$o" ]] && no "old orphan should be purged" || ok "old orphan purged silently"

# ---- T5: non-job dir (no cmd) is left untouched
echo "== T5: non-bgrun dir left untouched =="
n="$ROOT/not-a-job"; mkdir -p "$n"; printf 'x' > "$n/some.md"
BG_TTL_DONE=1 BG_TTL_RUN=1 bash "$CLEAN" >/dev/null 2>&1
[[ -d "$n" ]] && ok "non-job dir preserved" || no "non-job dir was deleted"

echo
echo "RESULT: $pass passed, $fail failed"
rm -rf "$(dirname "$ROOT")"
exit $(( fail > 0 ? 1 : 0 ))
