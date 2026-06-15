#!/usr/bin/env bash
# uninstall.sh — reverts the piebald-bgrun trio.
#   bash uninstall.sh            # reverts A (directive) + C (hook) + removes B (wrappers)
#   bash uninstall.sh --keep-bin # keeps the wrappers in ~/bin
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINDST="$HOME/bin"
SETTINGS="$HOME/.claude/settings.json"
KEEP_BIN=0
for a in "$@"; do [[ "$a" == "--keep-bin" ]] && KEEP_BIN=1; done

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WIN=1 ;; *) IS_WIN=0 ;; esac

echo "== piebald-bgrun uninstall =="

# ── A: remove the directive (Piebald) ─────────────────────────────────────────
if [[ $IS_WIN -eq 1 && -f "$BINDST/apply-bg-directive.py" ]]; then
  python3 "$BINDST/apply-bg-directive.py" --revert || echo "[A] revert failed — restore an app.db.bak-* manually"
else
  echo "[A] Claude Code/Linux: manually remove the '## Background execution' block from CLAUDE.md/AGENTS.md."
fi

# ── C: remove the hook from settings.json ─────────────────────────────────────
if [[ -f "$SETTINGS" ]]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
changed = False
for block in data.get("hooks", {}).get("UserPromptSubmit", []):
    before = len(block.get("hooks", []))
    block["hooks"] = [h for h in block.get("hooks", [])
                      if "bg-wake-hook.cmd" not in h.get("command","")
                      and "bg-wake.sh" not in h.get("command","")]
    changed = changed or (len(block["hooks"]) != before)
if changed:
    json.dump(data, open(path, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
    print("[C] hook removed from settings.json")
else:
    print("[C] hook was not present in settings.json")
PY
fi

# ── B: remove wrappers ────────────────────────────────────────────────────────
if [[ $KEEP_BIN -eq 0 ]]; then
  for f in bgrun bg-status bg-kill bg-wake.sh bg-wake-hook.cmd apply-bg-directive.py; do
    rm -f "$BINDST/$f"
  done
  echo "[B] wrappers removed from $BINDST"
else
  echo "[B] kept (--keep-bin)"
fi

echo "== done. (Jobs in ~/.piebald-bg/ were NOT removed — clean them up manually if needed.) =="
