# LIMITATION — cross-client live-render (Piebald), and how it bounds bgrun

> Hit during the 2026-06-17 push/auto-progression work. This is a **Piebald-platform**
> limitation (not a bug in bgrun or in this host's setup). It is the reason the
> auto-progression delivery was reverted from runner-done-time push back to
> hook/next-prompt delivery.

## The symptom

When a message/generation in a chat is **initiated by one client/connection** (e.g.
the bgrun completion push via the BFF `POST /chats/:id/send`, a script, or another
Piebald UI), the **other clients viewing the same chat do NOT render it live**. They
only catch up on **refresh / leaving and re-opening the chat** (a snapshot). It is not
real-time across clients — "it updates by chunks, but needs a refresh on the other host
per message."

"Client" here means a **UI/connection**, not a machine — desktop app, web UI, and the
Flutter mod all exhibit it. Sending from one, the others don't update on their own.

## Root cause (proven 2026-06-17)

- **Transport is fine.** The engine/piebald-web **broadcasts `StreamedChunk` to every
  WS connection**, including non-initiators. Proven: a separate passive WS connection
  (initiated nothing) received `19x StreamedChunk` for a chat whose generation was
  driven by a *different* connection, plus `72x` for yet another chat. So the data
  reaches every client.
- **The gate is client-side rendering.** The piebald-web React client (and the desktop
  app, which is WebView2 hosting the same bundle — inferred) applies an incoming chunk
  to the open thread **only if that chat's messages are already in its React-Query
  cache**. Minified gate in `main-<hash>.js`:
  `r.setQueryData(messages(chatId), e => e ? applyChunk(e) : (refetch(), e))`.
  A chat not currently loaded in that client drops the live chunks and schedules a
  refetch → you see it only on refresh. Bubble creation and `streamingMessageId` are
  **not** gated on who initiated — only on the cache being warm.
- Full reverse-engineering: `C:\Projects\piebald-mobile-mod\docs\RECON-piebald-web-bundle-stream-gate.md`
  and `…\RECON-external-stream-live-render.md`.

## How it bounds bgrun

- The auto-progression **push works mechanically**: `bg-push.mjs` resolves the origin
  chat and the BFF `send_message_streaming` makes that chat continue — it lands in the
  **right** chat (no cross-session leak) and the agent continues the loop.
- **But the push renders live on NO surface — not even the origin chat's own UI.**
  Corrected by the user 2026-06-17: the send is issued by the **BFF (a separate WS
  connection)**, so relative to that send *every* UI — including the one viewing the
  origin chat — is "another client" and hits the cache gate above → the continuation
  only shows on **refresh**, everywhere. There is no asterisk; it is a flat ❌ live.
- **Only the old pull hook renders live**, because its `<background-task-status>` rides
  the user's OWN next turn in the user's OWN UI (a context-notification on a turn that
  UI itself initiates) — never a separate WS-injected generation.
- **The trilemma (you can pick 2 of 3):** origin-targeted (no leak) · no autonomous
  send · live render. Targeting a specific chat ≡ `send_message_streaming` (fires + no
  live). No-fire + live ≡ the pull hook (current chat only → leak). No-fire + no-leak ≡
  a raw `app.db` insert (refresh-only, fragile — rejected).
- **Final decision (2026-06-17, user): full rollback to the original pull hook.** The
  push (piece D) is **disabled** — the leak (announce in the current chat) is accepted
  because the pull hook is the only path that renders live. Live state: `bgrun` runner
  reverted, `bg-wake.sh` = original stdout-announce (zero network), `bg-push.mjs`
  unwired/disabled (kept in-repo as a documented experiment).

## What can / can't be done about the limitation itself

- **Official desktop + web = closed-source → not patchable.** Only path: an upstream
  feature request (Piebald-AI/piebald-issues; this project's tracking issue is **#57**).
- **Local bundle patch = rejected** (fragile: minified, content-hashed, overwritten on
  Piebald update; would need its own test harness).
- **Controllable client (the Flutter mod)** can be fixed to render any chat's stream
  live — handoff lives in the piebald-mobile-mod project; the user will take it in a
  dedicated session.
