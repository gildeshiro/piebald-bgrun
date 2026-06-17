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

- The auto-progression **push works**: `bg-push.mjs` resolves the origin chat and the
  BFF `send_message_streaming` makes that chat continue — it lands in the **right**
  chat (no cross-session leak) and the agent continues the loop.
- **But you only SEE it live on the UI/connection that is the origin of the loop.** On
  any other UI viewing that chat, the continuation does not render until refresh. So
  "push to the origin chat" is correct and useful, but it does **not** give live visual
  feedback on a non-origin surface.
- **Decision (2026-06-17, user):** revert the runner's done-time self-push; deliver the
  completion to the origin chat via the **hook on the next `UserPromptSubmit`**
  (`bg-wake.sh` → `bg-push.mjs`) instead of an immediate auto-progression at completion.
  `bg-push.mjs` is kept; the delivery is at hook/pull timing.

## What can / can't be done about the limitation itself

- **Official desktop + web = closed-source → not patchable.** Only path: an upstream
  feature request (Piebald-AI/piebald-issues; this project's tracking issue is **#57**).
- **Local bundle patch = rejected** (fragile: minified, content-hashed, overwritten on
  Piebald update; would need its own test harness).
- **Controllable client (the Flutter mod)** can be fixed to render any chat's stream
  live — handoff lives in the piebald-mobile-mod project; the user will take it in a
  dedicated session.
