#!/usr/bin/env bash
# bg-wake.sh — UserPromptSubmit wake hook pro wrapper `bg`.
#
# Varre ~/.piebald-bg/*/done ainda não-ackados, imprime um bloco
# <background-task-status> no stdout (Piebald/Claude Code injetam isso no próximo
# turno -> o agente "acorda" e vê a conclusão sem poll). Marca .ack por job pra
# não repetir. Replica enqueueShellNotification + flag `notified` do Claude Code,
# só que pull-no-próximo-turno em vez de push-no-meio-do-turno.
#
# CONTRATO (igual ao userpromptsubmit-wake.sh do octo-fullstep):
#   NON-FATAL  — sai 0 sempre; nunca bloqueia um prompt
#   FAST       — glob + stat, zero rede
#   IDEMPOTENTE— .ack impede reinjeção
#   GATE       — remove .pending quando não há mais job vivo (corta o spawn futuro)
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
    # ack ANTES de emitir -> evita double-fire se interromper no meio
    touch "$d/.ack" 2>/dev/null || true
    rc="$(cat "$d/done" 2>/dev/null || echo '?')"
    desc="$(cat "$d/desc" 2>/dev/null || echo "$job")"
    st="completed"; [[ "$rc" != "0" ]] && st="failed"
    NOTES+=("$st (exit $rc) — \"$desc\"  [job $job]  output: ${d}out")
  else
    ALIVE=$((ALIVE + 1))   # sem done = ainda rodando -> mantém .pending
  fi
done

# nada mais vivo -> apaga o marcador de gate; o hook .cmd para de spawnar bash
[[ $ALIVE -eq 0 ]] && rm -f "$BG_ROOT/.pending" 2>/dev/null || true

if [[ ${#NOTES[@]} -gt 0 ]]; then
  echo "<background-task-status>"
  for n in "${NOTES[@]}"; do echo "✅ background $n"; done
  echo "Leia o arquivo de output com Read só se precisar dos detalhes. Não rode poll síncrono."
  echo "</background-task-status>"
fi
exit 0
