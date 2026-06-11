# DESIGN — piebald-bgrun

Anatomia completa: como o `run_in_background` do Claude Code funciona por dentro, o que
falta no Piebald, e como o trio (A/B/C) recria essa fluidez dentro das limitações dele.

---

## 1. Como o Claude Code faz `run_in_background` por dentro

Fonte: leitura do source da BashTool/LocalShellTask do Claude Code. O que torna o
`run_in_background` fluido são **duas peças independentes**:

### 1.1 O gatilho (o modelo sabe disparar por reflexo)
A descrição da tool (`BashTool/prompt.ts`) instrui: "use `run_in_background` pra
comando longo; você será notificado quando terminar — não faça sleep/poll". Isso vive
no system/tool-description, sempre presente → vira reflexo.

### 1.2 O desacoplamento (short-circuit)
Quando `run_in_background: true`, a `BashTool` **não entra no loop de espera**. Faz
spawn do processo nativo e chama `spawnBackgroundTask()`, que **retorna imediatamente**
`{ backgroundTaskId, code: 0, stdout: '' }`. A tool call resolve na hora → o LLM
desbloqueia e continua.

Internamente (`ShellCommand.background(taskId)`):
- desliga o **timeout** do foreground (senão mataria o comando longo);
- **`spillToDisk()`**: redireciona stdout/stderr do filho pra escrever **direto num
  arquivo no disco**, bypassando a RAM (evita memory-bloat em jobs de horas);
- liga um **size-watchdog** no arquivo (o source cita um incidente de "768GB" — um loop
  preso enchendo o disco — que motivou essa trava).

### 1.3 O wake (a notificação que "acorda" o modelo)
Uma Promise solta (`void shellCommand.result.then(...)`) observa o processo morrer.
Quando morre, `enqueueShellNotification()` monta um bloco XML:
```xml
<task_notification>
  <task_id>0a1b</task_id>
  <output_file>/tmp/.../output.txt</output_file>
  <status>completed</status>
  <summary>"npm run build" completed (exit code 0)</summary>
</task_notification>
```
e o empurra pra uma **fila de mensagens global** (`commandQueue` via
`enqueuePendingNotification()`). O event loop principal injeta unilateralmente essa
mensagem no contexto do LLM no próximo turno. Um flag `notified` por task impede
duplicação.

**As duas peças que importam:** (1.1) o gatilho e (1.3) o wake. O desacoplamento (1.2)
é "só" detach de I/O.

---

## 2. O que o Piebald NÃO tem

- **Não tem `run_in_background` nativo.** O terminal (`RunTerminalCommand`) roda
  síncrono, num terminal embutido, sem persistência de sessão. Comando longo síncrono
  **trava o chat**.
- **Não tem o event loop de injeção unilateral** (`commandQueue`) que "acorda" o modelo
  no meio de um turno. Nada empurra mensagem pro contexto sem input do usuário.

Portanto, mover a instrução pro system prompt resolve **só o gatilho (1.1)**. O wake
(1.3) precisa ser recriado — e a peça que o recria já existe no setup: o hook
**`UserPromptSubmit`** (que o cluster já usa pra injetar memórias/cluster-notes). Ele é
o nosso `commandQueue`, só que **pull-no-próximo-turno** em vez de **push-no-meio-do-turno**.

---

## 3. O trio — mapeamento 1:1 com o Claude Code

| Claude Code | piebald-bgrun | Como |
| --- | --- | --- |
| gatilho (tool prompt) | **A** diretiva no system prompt | `apply-bg-directive.py` anexa ao `base_gen_cfg_data.system_prompt` do profile Default |
| `spawnBackgroundTask` + detach | **B** `bgrun` | PowerShell `Start-Process` (Win) / `setsid` (Linux) — processo independente que sobrevive ao tool call |
| `spillToDisk` (output no disco) | **B** `bgrun` | runner redireciona `> out 2>&1`; estado em `~/.piebald-bg/<job>/` |
| `enqueueShellNotification` + `commandQueue` | **C** `bg-wake.sh` | varre `*/done`, injeta `<background-task-status>` no stdout do hook |
| flag `notified` | **C** `.ack` por job | `touch .ack` antes de emitir → idempotente |
| size-watchdog (768GB) | (n/a) | jobs curtos; bom senso. Pode-se adicionar depois |

### 3.1 Por que `bgrun` e não `bg`
`bg` é **builtin de job control do bash** (junto de `fg`/`jobs`) e tem **precedência
sobre o PATH** mesmo em shell não-interativo. Um executável `~/bin/bg` nunca seria
chamado — o builtin intercepta ("bg: no job control"). Daí `bgrun`.

### 3.2 Gate barato do hook
O `bg-wake-hook.cmd` (Windows) só spawna git-bash se existir o marcador
`~/.piebald-bg/.pending`. Sem job pendente → exit ~5ms, zero spawn. O `bg-wake.sh`
remove `.pending` quando não há mais job vivo (sem `done`). Espelha o gate do
`fullstep-wake-hook.cmd` já comprovado no host.

### 3.3 Invocação de bash em hook no Piebald/Windows
O `cmd /C` que o Piebald usa pra rodar hooks tem **PATH mínimo, sem git-bash**. Então
o `.cmd` chama o bash pelo caminho 8.3: `C:\PROGRA~1\Git\bin\bash.exe`. (`Get-Command
bash` engana — herda o PATH do shell pai.)

---

## 4. Limitação dura (teto arquitetural)

Sem event loop de injeção unilateral, **não dá** "push no meio da geração". O máximo é
**wake no próximo `UserPromptSubmit`** (próxima vez que o usuário digita). Fluxo normal
(dispara → conversa → status aparece) mascara isso; mas disparar e ficar 10 min em
silêncio significa que o agente só vê a conclusão quando o usuário voltar a falar.
Quem prometer "push real" no Piebald está enganado.

---

## 5. Onde vive cada coisa (host win-work)

- **Scripts instalados:** `~/bin/` (no PATH do git-bash). Fonte canônica: este repo `bin/`.
- **Hook registrado:** `~/.claude/settings.json` → `UserPromptSubmit` (3º hook, ao lado
  de `piebald-memory-selector.cmd` e `fullstep-wake-hook.cmd`).
- **Diretiva (peça A):** `app.db` em `%APPDATA%\piebald\app.db`, tabela
  `base_gen_cfg_data.system_prompt` do `config_id` do profile Default (id=1). Schema
  2026-06: o system prompt migrou de `override_gen_cfg_data` → `base_gen_cfg_data`.
  O `config_id` **varia** (já foi 36, depois 135) — por isso o script detecta dinâmico.
- **Propagação:** editar o config do profile Default propaga pra todo **chat novo**
  (o Piebald clona o config na criação do chat). Verificado: configs criados após a
  edição nasceram com a diretiva.

---

## 6. Portabilidade (Claude Code / linux-dev / phone)

- **B** (`bgrun`): já ramifica por SO (`Start-Process` no Windows; `setsid`/`nohup`
  fora). Portável.
- **C** (hook): em Claude Code/Linux registrar o `bg-wake.sh` direto no
  `UserPromptSubmit` (sem o wrapper `.cmd`, que é só pro PATH-mínimo do Piebald/Windows).
- **A** (gatilho): em **Claude Code não há `app.db`** — a diretiva vai em
  `~/.claude/CLAUDE.md` (global) ou no `AGENTS.md`/`CLAUDE.md` de raiz do projeto. No
  Piebald é o `app.db` (o único caminho de aderência forte = campo `system` da API).
