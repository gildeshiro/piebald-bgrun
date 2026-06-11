# piebald-bgrun — agent rules

Projeto que dá ao Piebald o `run_in_background` do Claude Code: dispara tarefas longas
**destacadas** e notifica a conclusão automaticamente, sem travar o chat síncrono.

Quando trabalhar NESTE repo:

- Os 6 artefatos canônicos vivem em `bin/`. Os que rodam de verdade ficam **instalados**
  em `~/bin/` (no PATH) — `bin/` aqui é a **fonte**. Editou aqui? rode `bash install.sh`
  pra reinstalar, OU edite e copie o arquivo específico pra `~/bin/`.
- **NÃO renomeie `bgrun` pra `bg`**: `bg` é builtin de job control do bash e tem
  precedência no PATH — o script nunca seria chamado.
- A peça A (diretiva no system prompt) é gravada no `app.db` do Piebald via
  `bin/apply-bg-directive.py` — **sempre com backup** e detecção dinâmica do `config_id`.
  Nunca hardcode o id (varia). Em Claude Code não há `app.db`: vai em CLAUDE.md/AGENTS.md.
- Hook em Piebald/Windows: invoque bash pelo caminho 8.3 `C:\PROGRA~1\Git\bin\bash.exe`
  (o `cmd /C` do Piebald tem PATH mínimo, sem git-bash).
- Progresso/tracking vai em `progress-log.md` (local), **não** no daemon de memória.

Leia `docs/DESIGN.md` antes de mexer na arquitetura — explica o mapeamento 1:1 com os
internals do Claude Code e o teto arquitetural do Piebald (wake é pull-no-próximo-turno,
não push-no-meio-do-turno).

Testar mudança end-to-end: `bgrun "t" "sleep 4 && echo ok"` → `bash bin/bg-wake.sh`
(deve injetar `<background-task-status>` quando o `done` aparece; 2ª chamada = silêncio,
idempotência via `.ack`).
