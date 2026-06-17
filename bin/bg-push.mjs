#!/usr/bin/env node
// bg-push.mjs — on a bgrun job's completion, RESOLVE the originating chat and PUSH
// a completion recap into THAT chat via the piebald-mobile-mod BFF, so the agent
// auto-progresses (Claude-Code-style loop) in the RIGHT chat — no cross-session leak.
//
// This is the PUSH half that Piebald's pull-only UserPromptSubmit hook cannot do.
// Invoked ONE-SHOT by bgrun's detached runner right after the `done` sentinel is
// written (the job's RunTerminalCommand row is committed in app.db by then, so the
// chat is resolvable). Best-effort: ANY failure is swallowed and the job is left for
// the bg-wake.sh pull fallback (which only announces jobs without `.pushed`).
//
// Usage:  node bg-push.mjs <jobdir>
//
// Why Node + node:sqlite (not the scoop `sqlite3` shim): the shim deadlocks/junctions
// flake on this host (see RTK memory); node:sqlite (DatabaseSync) is the robust path
// already proven in piebald-dynamic-subagents/hooks/pretooluse-route.mjs.
//
// Identity (done-time binding): Piebald gives the terminal NO chat id (env has only
// TERM_PROGRAM=piebald) and the hook payload carries none. But app.db stores every
// terminal tool call's command text in message_part_tool_call.tool_input, joinable to
// chats. We match the bgrun invocation (contains the job's cmd) nearest to the job's
// start epoch -> origin chat_id. Proven on win-work 2026-06-17 (resolved to chat 653).

import { readFileSync, existsSync, writeFileSync } from "node:fs";
import path from "node:path";
import os from "node:os";

// ---- config -----------------------------------------------------------------
const JOBDIR = process.argv[2];
const DB_PATH = process.env.PIEBALD_APP_DB ||
  path.join(process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming"), "Piebald", "app.db");
// BFF default on this host is 8788 (running instance); code default is 8787. Try both.
const BFF_PORTS = (process.env.BG_BFF_PORT ? [process.env.BG_BFF_PORT] : ["8788", "8787"]);
const WINDOW_BEFORE_S = 90;   // tool call is created up to ~Ns before the job start
const WINDOW_AFTER_S = 30;    // ...or shortly after (clock skew / commit lag)
const UNIQUE_WINDOW_S = 15;   // tight window for the "single bgrun launch" safe fallback
const CANDIDATE_LIMIT = 300;  // most-recent RunTerminalCommand rows to scan

function readFileSafe(p) { try { return readFileSync(p, "utf8"); } catch { return ""; } }

async function main() {
  if (!JOBDIR || !existsSync(JOBDIR)) return;
  const f = (n) => path.join(JOBDIR, n);

  // idempotent: already pushed -> nothing to do
  if (existsSync(f(".pushed"))) return;

  const cmd = readFileSafe(f("cmd")).trim();
  const desc = readFileSafe(f("desc")).trim();
  const rc = readFileSafe(f("done")).trim() || "?";
  const job = path.basename(JOBDIR);
  const startEpoch = parseInt(readFileSafe(f("start")).trim(), 10);
  const outFile = f("out");

  if (!cmd) return;

  // ---- resolve origin chat_id (or reuse a previously written binding) -------
  let chatId = parseInt(readFileSafe(f("chat_id")).trim(), 10);
  if (!Number.isInteger(chatId)) {
    chatId = await resolveChatId({ cmd, desc, startEpoch });
    if (Number.isInteger(chatId)) {
      try { writeFileSync(f("chat_id"), String(chatId)); } catch {}
    }
  }
  if (!Number.isInteger(chatId)) return; // unknown origin -> leave to pull fallback

  // dry-run: resolve only (testing) — print the chat and exit, no push
  if (process.env.BG_PUSH_DRYRUN) { console.log(`resolved chat_id=${chatId} for job ${job}`); return; }

  // ---- build recap (mirrors bg-wake.sh's <background-task-status> shape) -----
  const ok = rc === "0";
  const st = ok ? "completed" : "failed";
  const recap =
    `<background-task-status>\n` +
    `${ok ? "✅" : "❌"} background ${st} (exit ${rc}) — "${desc || cmd}"  [job ${job}]\n` +
    `output: ${outFile}\n` +
    `</background-task-status>\n` +
    `O job de background acima terminou. Retome de onde parou: se precisar dos ` +
    `detalhes, leia o arquivo de output com Read; depois prossiga com a tarefa ` +
    `pendente. Se não houver próximo passo claro, faça um recap curto e pare — não entre em loop.`;

  // ---- push into the origin chat (next_iteration => engine `yield`):
  //      idle chat -> fires a fresh turn; working chat -> queues, no interrupt/branch
  //      (both proven on win-work 2026-06-17, chats 661 idle + 653 working). ----
  const pushed = await pushToChat(chatId, recap);
  if (pushed) { try { writeFileSync(f(".pushed"), `${chatId}`); } catch {} }
  // not pushed (BFF down) -> no .pushed marker -> bg-wake.sh pull fallback covers it
}

// ---------------------------------------------------------------------------
async function resolveChatId({ cmd, desc, startEpoch }) {
  let DatabaseSync;
  try { ({ DatabaseSync } = await import("node:sqlite")); } catch { return NaN; }
  let db;
  try {
    db = new DatabaseSync(DB_PATH, { readOnly: true });
  } catch {
    try { db = new DatabaseSync(DB_PATH); } catch { return NaN; }
  }
  try {
    db.exec("PRAGMA busy_timeout=3000");
    const rows = db.prepare(
      `SELECT m.parent_chat_id AS chat_id, m.created_at AS created_at, tc.tool_input AS tool_input
       FROM message_part_tool_call tc
       JOIN message_parts mp ON mp.id = tc.message_part_id
       JOIN messages m ON m.id = mp.parent_chat_message_id
       WHERE tc.tool_name = 'RunTerminalCommand' AND tc.tool_input LIKE '%bgrun%'
       ORDER BY tc.message_part_id DESC
       LIMIT ${CANDIDATE_LIMIT}`
    ).all();

    const startMs = Number.isInteger(startEpoch) ? startEpoch * 1000 : NaN;
    // Resolve the origin in two tiers, both safe against mis-binding:
    //  (1) TEXT match — the bgrun launch tool_input contains the job's DESC or CMD
    //      verbatim. desc is a static label (survives shell expansion); cmd covers the
    //      single-arg case. This is the normal, deterministic path. Nearest-in-time
    //      breaks ties when the same label/command ran in two parallel chats.
    //  (2) UNIQUE-LAUNCH fallback — for a fully dynamic invocation (both desc & cmd
    //      contain $(...) / vars so neither appears verbatim): if there is exactly ONE
    //      chat that fired a bgrun launch within a TIGHT window around the job start,
    //      trust it. If 0 or >1, return NaN (let the pull hook announce) — never guess.
    const descKey = (desc && desc.length >= 4) ? desc : null;
    const cands = [];
    for (const r of rows) {
      const ti = String(r.tool_input || "");
      const t = Date.parse(String(r.created_at || ""));
      let delta = NaN;
      if (!Number.isNaN(startMs) && !Number.isNaN(t)) delta = (t - startMs) / 1000;
      const inWindow = Number.isNaN(delta) ? true : (delta >= -WINDOW_BEFORE_S && delta <= WINDOW_AFTER_S);
      if (!inWindow) continue;
      const textMatch = (descKey && ti.includes(descKey)) || (cmd && ti.includes(cmd));
      cands.push({ chat_id: r.chat_id, adelta: Number.isNaN(delta) ? Infinity : Math.abs(delta), textMatch });
    }
    // (1) text match — nearest in time wins
    const textCands = cands.filter((c) => c.textMatch).sort((a, b) => a.adelta - b.adelta);
    if (textCands.length) return Number.isInteger(textCands[0].chat_id) ? textCands[0].chat_id : NaN;
    // (2) unique bgrun launch in the tight window (dynamic-command case)
    const tightChats = [...new Set(cands.filter((c) => c.adelta <= UNIQUE_WINDOW_S).map((c) => c.chat_id))];
    if (tightChats.length === 1 && Number.isInteger(tightChats[0])) return tightChats[0];
    return NaN;
  } catch {
    return NaN;
  } finally {
    try { db && db.close(); } catch {}
  }
}

async function pushToChat(chatId, text) {
  const body = JSON.stringify({ text, queue_type: "next_iteration" });
  const TO_MS = parseInt(process.env.BG_PUSH_TIMEOUT_MS || "1500", 10); // /send hangs on
  // the stream; localhost delivery is <100ms, so a short abort still delivers (proven
  // 2026-06-17: message landed despite client-side timeout). Bounds wake-hook latency.
  for (const port of BFF_PORTS) {
    try {
      const ctrl = new AbortController();
      const to = setTimeout(() => ctrl.abort(), TO_MS);
      try {
        await fetch(`http://127.0.0.1:${port}/chats/${chatId}/send`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body,
          signal: ctrl.signal,
        });
      } catch (e) {
        // AbortError after the request was sent still means it FIRED (the BFF holds
        // the response open on the stream). Treat abort as success; treat connection
        // refused (ECONNREFUSED) as a real failure -> try next port.
        if (e && (e.name === "AbortError" || /aborted/i.test(String(e.message)))) {
          clearTimeout(to); return true;
        }
        clearTimeout(to);
        continue; // BFF not on this port -> try next
      }
      clearTimeout(to);
      return true;
    } catch {
      continue;
    }
  }
  return false;
}

main().catch(() => {}).finally(() => { try { process.exit(0); } catch {} });
