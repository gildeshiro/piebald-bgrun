#!/usr/bin/env bash
# install.sh — instala o trio piebald-bgrun (B wrappers + C hook + A diretiva).
#
#   bash install.sh            # tudo (B + C + A)
#   bash install.sh --no-app   # pula a peça A (não toca no app.db / system prompt)
#   bash install.sh --no-hook  # pula a peça C (não registra o hook)
#
# Portável: Windows/Piebald (git-bash) e Linux/Claude Code. Idempotente.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINSRC="$REPO/bin"
BINDST="$HOME/bin"
SETTINGS="$HOME/.claude/settings.json"

DO_APP=1; DO_HOOK=1
for a in "$@"; do
  case "$a" in
    --no-app)  DO_APP=0 ;;
    --no-hook) DO_HOOK=0 ;;
  esac
done

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;;
  *) IS_WIN=0 ;;
esac

echo "== piebald-bgrun install (win=$IS_WIN) =="

# ── B: wrappers ───────────────────────────────────────────────────────────────
mkdir -p "$BINDST"
for f in bgrun bg-status bg-kill bg-wake.sh apply-bg-directive.py; do
  cp "$BINSRC/$f" "$BINDST/$f"; chmod +x "$BINDST/$f"
done
[[ $IS_WIN -eq 1 ]] && cp "$BINSRC/bg-wake-hook.cmd" "$BINDST/bg-wake-hook.cmd"
echo "[B] wrappers -> $BINDST (bgrun, bg-status, bg-kill)"
case ":$PATH:" in *":$BINDST:"*) : ;; *) echo "    AVISO: $BINDST não está no PATH — adicione-o.";; esac

# ── C: hook UserPromptSubmit (idempotente) ────────────────────────────────────
if [[ $DO_HOOK -eq 1 ]]; then
  if [[ $IS_WIN -eq 1 ]]; then
    HOOKCMD="$(cygpath -w "$BINDST/bg-wake-hook.cmd" 2>/dev/null || echo "$BINDST/bg-wake-hook.cmd")"
  else
    HOOKCMD="$BINDST/bg-wake.sh"
  fi
  HOOKCMD="$HOOKCMD" python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
cmd  = os.environ["HOOKCMD"]
os.makedirs(os.path.dirname(path), exist_ok=True)
data = {}
if os.path.exists(path):
    data = json.load(open(path, encoding="utf-8"))
hooks = data.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
block = next((b for b in hooks if b.get("matcher") == "*"), None)
if block is None:
    block = {"matcher": "*", "hooks": []}
    hooks.append(block)
if not any(h.get("command") == cmd for h in block["hooks"]):
    block["hooks"].append({"type": "command", "command": cmd})
    json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print(f"[C] hook registrado: {cmd}")
else:
    print(f"[C] hook já registrado (idempotente): {cmd}")
PY
else
  echo "[C] pulado (--no-hook)"
fi

# ── A: diretiva no system prompt ──────────────────────────────────────────────
if [[ $DO_APP -eq 1 ]]; then
  if [[ $IS_WIN -eq 1 ]]; then
    python3 "$BINDST/apply-bg-directive.py" || echo "[A] FALHOU — rode manualmente (idealmente com o Piebald fechado)"
  else
    echo "[A] Claude Code/Linux: NÃO há app.db. Cole docs/system-prompt-directive.md em"
    echo "    ~/.claude/CLAUDE.md (global) ou no AGENTS.md/CLAUDE.md de raiz do projeto."
  fi
else
  echo "[A] pulado (--no-app)"
fi

echo "== feito. Ative A+C abrindo um CHAT NOVO no Piebald. B (bgrun) já funciona. =="
