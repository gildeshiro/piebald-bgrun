# system-prompt-directive

Texto exato que a **peça A** (`bin/apply-bg-directive.py`) anexa ao `system_prompt` do
profile Default. São ~1193 chars acrescentados ao final do system prompt existente,
separados por `\n\n---\n\n`. O marcador de idempotência é a linha `## Background execution`.

No Piebald isso é gravado no `app.db` (`base_gen_cfg_data.system_prompt`). No Claude Code
(linux-dev/phone) cole este mesmo bloco em `~/.claude/CLAUDE.md` (global) ou no
`AGENTS.md`/`CLAUDE.md` de raiz.

---

```markdown
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
É reflexo — não pergunte antes.
```

---

## Aplicar / reverter (Piebald, app.db)

```bash
python bin/apply-bg-directive.py            # anexa (idempotente, com backup automático)
python bin/apply-bg-directive.py --revert   # remove a diretiva
python bin/apply-bg-directive.py --db <path># app.db alternativo
```

- Detecta o `config_id` do profile Default **dinamicamente** (não hardcoda 135).
- Backup automático: `app.db.bak-<timestamp>` (+ `-wal`/`-shm`).
- Idempotente: se o marcador já existe, é no-op.
- Ativação: **chat novo** (o Piebald clona o config do profile na criação do chat).
