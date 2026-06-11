# piebald-bgrun

Background execution para o **Piebald** no estilo do `run_in_background` do Claude Code.

O terminal do Piebald roda **síncrono**: um comando longo bloqueia o chat até voltar
(você não consegue mandar outra mensagem). Este projeto dá ao agente o reflexo de
disparar tarefas longas **destacadas** (builds, suítes de teste, debates multi-LLM,
downloads) e ser **notificado automaticamente** quando terminam — sem travar a conversa
e sem poll manual.

> Replica a fluidez do `run_in_background` do Claude Code dentro das limitações do
> Piebald (que não tem event loop de injeção unilateral de notificação). Ver
> [`docs/DESIGN.md`](docs/DESIGN.md) pra anatomia completa, incluindo como o Claude
> Code faz por dentro.

---

## O trio

Fluidez de verdade precisa de três peças independentes — cada uma cobre uma lacuna:

| Peça | O quê | Cobre | Arquivo |
| --- | --- | --- | --- |
| **A** Gatilho | Diretiva no **system prompt** do profile (reflexo permanente) | "quando disparar" | `bin/apply-bg-directive.py` |
| **B** Fricção | Wrapper `bgrun` + `bg-status` + `bg-kill` | "fácil de disparar" | `bin/bgrun`, `bin/bg-status`, `bin/bg-kill` |
| **C** Wake | Hook `UserPromptSubmit` que injeta a conclusão | "descobre que acabou" | `bin/bg-wake.sh`, `bin/bg-wake-hook.cmd` |

Tirar qualquer peça deixa o sistema manco: só A = sabe disparar mas checa na mão; só
B = dispara fácil mas você lembra de checar; A+B sem C = falta o "acordar sozinho".

---

## Uso (depois de instalado)

```bash
# dispara destacado, retorna na hora com um job-id
bgrun "build do tmoney" "cargo build --release"

# ...a conversa segue normalmente...

# no PRÓXIMO turno, o hook injeta automaticamente:
#   <background-task-status>
#   ✅ background completed (exit 0) — "build do tmoney"  [job 20260611-...]  output: ~/.piebald-bg/.../out
#   </background-task-status>

# sob demanda:
bg-status            # lista todos os jobs e estado
bg-status <job-id>   # filtra
bg-kill  <job-id>    # mata targeted (pela cmdline)
```

Formas de chamar:
- `bgrun "<comando>"` — a descrição vira o próprio comando.
- `bgrun "<descrição curta>" "<comando completo>"` — descrição explícita.

O estado de cada job vive em `~/.piebald-bg/<job-id>/`:
```
cmd desc cwd   entrada
out            stdout+stderr combinados (leia com Read se precisar dos detalhes)
start end      epoch
done           escrito por ÚLTIMO; contém o exit code (sentinela de conclusão)
.ack           o hook marca ao notificar (idempotência)
```

---

## Instalação

```bash
bash install.sh            # instala B (wrappers) + C (hook) + A (diretiva no app.db)
bash install.sh --no-app   # pula a peça A (não toca no app.db)
bash uninstall.sh          # reverte tudo (restaura app.db do backup, tira o hook, remove ~/bin/*)
```

Detalhes e adaptação por SO (Windows/Piebald vs Linux/phone/Claude Code) em
[`docs/DESIGN.md`](docs/DESIGN.md) e nos comentários de cada script.

### Ativação
- **B (`bgrun`)** funciona na hora.
- **A (system prompt)** e **C (hook)** pegam num **chat novo** (o Piebald clona o
  config do profile e recarrega os hooks na criação do chat). Um chat aberto *antes*
  da instalação fica com o estado velho em cache — abra um chat novo.

---

## Limitação arquitetural (honesta)

O Piebald **não tem** event loop que injete mensagem no meio de um turno sem input do
usuário. Então o wake é **pull no próximo prompt**, não **push no meio da geração**
como o Claude Code. Na prática quase não se nota (dispara → conversa → status aparece),
mas se você disparar e sumir 10 min, o agente só "descobre" que terminou quando você
voltar a digitar. É o teto do Piebald — ver `docs/DESIGN.md §4`.

---

## Layout

```
piebald-bgrun/
├── README.md
├── AGENTS.md                       # lido por Piebald/Claude Code ao abrir o projeto
├── install.sh / uninstall.sh
├── progress-log.md                 # tracking local do projeto
├── bin/
│   ├── bgrun  bg-status  bg-kill   # peça B
│   ├── bg-wake.sh  bg-wake-hook.cmd# peça C
│   └── apply-bg-directive.py       # peça A
└── docs/
    ├── DESIGN.md                   # internals do run_in_background + anatomia do trio
    └── system-prompt-directive.md  # o texto exato injetado no system prompt
```
