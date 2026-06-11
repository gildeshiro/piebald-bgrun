#!/usr/bin/env python3
# apply-bg-directive.py — anexa a diretiva de "background execution" ao system
# prompt do profile Default do Piebald (tabela base_gen_cfg_data no app.db).
#
# Idempotente (marcador BG_MARKER), faz backup antes de escrever, detecta o
# config_id do profile Default DINAMICAMENTE (o id muda — não hardcode).
#
# IDEAL: rodar com o Piebald FECHADO (evita o cache em memória do app sobrescrever).
# Ao vivo funciona, mas a ativação exige restart do app de qualquer forma.
#
# Uso:  python apply-bg-directive.py [--db <caminho>] [--revert]
import sqlite3, shutil, sys, os, datetime, argparse

DEFAULT_DB = os.path.expandvars(r"%APPDATA%\piebald\app.db")
BG_MARKER = "## Background execution"

DIRECTIVE = """

---

## Background execution — rode tarefas longas DESTACADAS (não bloqueie o chat)

Este host é Piebald: o terminal roda SÍNCRONO, então um comando longo síncrono TRAVA
o chat (o usuário não consegue mandar outra mensagem até o comando voltar). Por isso,
quando uma tarefa for demorada e não-bloqueante — builds, suítes de teste, debates
multi-LLM (gemini/codex), downloads grandes, varreduras longas —, NÃO rode síncrono:
dispare destacada com o wrapper `bgrun`, por instinto, como o run_in_background do
Claude Code.

- Disparar: `bgrun "<descrição curta>" "<comando completo>"` (ou `bgrun "<comando>"`).
  Retorna na hora com um job-id; o chat fica livre.
- NÃO faça poll síncrono nem sleep esperando. Quando o job termina, o hook
  UserPromptSubmit injeta um bloco `<background-task-status>` automaticamente no
  próximo turno — confie nisso, não fique checando.
- Sob demanda: `bg-status [job-id]` (estado) · `bg-kill <job-id>` (matar).
- O output de cada job vive em `~/.piebald-bg/<job-id>/out` — leia com Read quando o
  status chegar, só se precisar dos detalhes.

Bom senso: tarefa rápida (~<20s) roda síncrona normal; tarefa longa vai pro `bgrun`.
É reflexo — não pergunte antes."""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--revert", action="store_true", help="remove a diretiva")
    args = ap.parse_args()

    db = args.db
    if not os.path.exists(db):
        sys.exit(f"app.db não encontrado: {db}")

    # backup app.db + wal + shm
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    for suf in ("", "-wal", "-shm"):
        src = db + suf
        if os.path.exists(src):
            shutil.copy2(src, f"{src}.bak-{ts}")
    print(f"[backup] {db}.bak-{ts} (+ wal/shm se existiam)")

    con = sqlite3.connect(db, timeout=15)
    con.execute("PRAGMA busy_timeout=15000")
    cur = con.cursor()

    # config_id do profile Default (dinâmico)
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
        sys.exit(f"sem base_gen_cfg_data pra gen_cfg_id={cfg_id}")
    sp = r[0] or ""
    print(f"[antes] system_prompt: {len(sp)} chars; marcador presente? {BG_MARKER in sp}")

    if args.revert:
        if BG_MARKER not in sp:
            print("[revert] marcador ausente — nada a fazer."); con.close(); return
        new = sp.split("\n\n---\n\n" + BG_MARKER)[0]
        cur.execute("UPDATE base_gen_cfg_data SET system_prompt=? WHERE gen_cfg_id=?", (new, cfg_id))
        con.commit()
        print(f"[revert] removido -> {len(new)} chars")
        con.close(); return

    if BG_MARKER in sp:
        print("[idempotente] diretiva já presente — no-op."); con.close(); return

    new = sp + DIRECTIVE
    cur.execute("UPDATE base_gen_cfg_data SET system_prompt=? WHERE gen_cfg_id=?", (new, cfg_id))
    con.commit()
    try:
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass

    # verificação read-back
    cur.execute("SELECT length(system_prompt), instr(system_prompt,?) FROM base_gen_cfg_data WHERE gen_cfg_id=?", (BG_MARKER, cfg_id))
    ln, pos = cur.fetchone()
    con.close()
    print(f"[depois] system_prompt: {ln} chars; marcador na posição {pos}")
    print("[ok] diretiva aplicada." if pos else "[FALHA] marcador não encontrado após write")
    print(">>> reinicie o Piebald pra ativar (o profile é lido na criação do chat).")


if __name__ == "__main__":
    main()
