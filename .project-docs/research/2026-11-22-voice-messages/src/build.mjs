// Builds the voice-message mockups and renders PNGs. Run: node build.mjs
import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
const require = createRequire("/Users/maxim/node_modules/");
const { chromium } = require("playwright");

const OUT = "/Users/maxim/.claude/orchestrator/voice-messages";
const SRC = path.join(OUT, "src");

const PLAY = `<svg width="12" height="12" viewBox="0 0 12 12"><path d="M3 1.5v9l7.5-4.5z" fill="#fff"/></svg>`;
const PAUSE = `<svg width="12" height="12" viewBox="0 0 12 12"><rect x="2.5" y="1.5" width="2.6" height="9" rx="1" fill="#fff"/><rect x="7" y="1.5" width="2.6" height="9" rx="1" fill="#fff"/></svg>`;
const APP = (lg) => `<span class="appicon${lg ? " lg" : ""}"><svg width="${lg ? 12 : 10}" height="${lg ? 12 : 10}" viewBox="0 0 10 10"><path d="M5 1C2.8 1 1 2.5 1 4.4c0 1 .5 1.9 1.3 2.5L2 9l2.1-1.2c.3.1.6.1.9.1 2.2 0 4-1.5 4-3.5S7.2 1 5 1z" fill="#fff"/></svg></span>`;
const X = `<span class="x"><svg width="8" height="8" viewBox="0 0 8 8"><path d="M1 1l6 6M7 1L1 7" stroke="rgba(255,255,255,.75)" stroke-width="1.4" stroke-linecap="round"/></svg></span>`;
const bars = (h, dim) => `<span class="bars">${h.map((v) => `<i style="height:${v}px;${dim ? "opacity:.35" : ""}"></i>`).join("")}</span>`;

const WAVE = [6,10,14,9,16,20,12,8,14,18,10,6,12,16,20,14,9,6,10,14,18,12,8,6,10,14,9,12,16,10,7,5];
const wave = (progress) => WAVE.map((h, i) => `<i style="height:${h}px" class="${i / WAVE.length < progress ? "p" : ""}"></i>`).join("");
const voice = (dur, progress = 0, playing = false) =>
  `<div class="voice${playing ? " playing" : ""}"><span class="play">${playing ? PAUSE : PLAY}</span><span class="wave">${wave(progress)}</span><span class="dur">${dur}</span></div>`;

function messenger(state) {
  // state: which voice is playing and how far
  const p = (i) => state[i] ?? [0, false];
  return `<div class="win"><div class="dots"><i></i><i></i><i></i></div>
  <div class="side">
    <div class="chat-item sel"><span class="ava">А</span><div>Аня<small>Голосовое · 0:23</small></div></div>
    <div class="chat-item"><span class="ava b">Р</span><div>Рабочий чат<small>Лёша: ок, завтра</small></div></div>
    <div class="chat-item"><span class="ava c">М</span><div>Мама<small>Фото</small></div></div>
  </div>
  <div class="main">
    <div class="head"><span class="ava" style="width:30px;height:30px">А</span><div>Аня<small>в сети</small></div></div>
    <div class="msgs">
      <div class="text-msg">ну что там по пятнице?</div>
      ${voice("0:42", ...p(0))}
      ${voice("1:15", ...p(1))}
      ${voice("0:23", ...p(2))}
    </div>
    <div class="compose">Сообщение…</div>
  </div></div>`;
}

const menubar = `<div class="menubar"><div class="l"><span>&#63743;</span><b>Messenger</b><span>File</span><span>Edit</span><span>View</span><span>Window</span></div><div class="r"><span>Wi‑Fi</span><span>100%</span><span>Sun 22 Nov 14:05</span></div></div>`;

const T1 = "Привет! Слушай, по поводу пятницы — я посмотрела, у них свободно только на восемь, так что давай либо на восемь, либо переносим на субботу. И ещё, возьми, пожалуйста, зарядку, я свою опять забыла у мамы.";
const T2 = "Короче, я поговорила с Лёшей, он сказал, что договор пришлют завтра до обеда, но там надо будет поправить реквизиты, потому что они опять старые вставили. Сможешь глянуть? Я тебе скину на почту.";
const T3a = "И да, забыла сказать — бронь на восемь я уже сделала, если что, отменить можно ";
const T3b = "до четверга";

function frame({ title, sub, island, notes, msgr, pins = "" }) {
  return `<section class="frame-wrap"><div class="frame-title">${title} <span>${sub}</span></div>
  <div class="frame">${menubar}${messenger(msgr)}${island}${pins}<div class="notes">${notes.map((n, i) => `<div class="note"><span class="n">${i + 1}</span>${n}</div>`).join("")}</div></div></section>`;
}

const page = (h1, lede, frames) => `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="mock.css"></head><body>
<h1>${h1}</h1><p class="lede">${lede}</p>${frames.join("\n")}</body></html>`;

// ---------- Variant A: explicit Listen, live line in the wing, card at the end
const A1 = frame({
  title: "A1 · Взвели", sub: "⌥L или тайл Listen, голосовое ещё не играет",
  msgr: {},
  island: `<div class="island" style="width:380px;height:62px">
    <div class="wing-l">${bars([4,7,10,7,4], true)}</div>
    <div class="wing-r">${X}</div>
    <div class="line" style="text-align:center;color:var(--ink-2)">Play a voice message <span class="kbd">⌥L</span><span style="font-size:12px;color:var(--ink-3)"> stops</span></div>
  </div>`,
  notes: [
    "<b>Жест.</b> ⌥L (свободный хоткей инструмента) или тайл <b>Listen</b> в Hover. Это только «взвод»: звук ещё не пишется.",
    "<b>Чей звук.</b> Берём первое приложение, которое <b>начнёт</b> звучать после нажатия. Музыка, игравшая до этого, не попадает.",
    "Если 30 с ничего не заиграло — тихо снимается. Повторный ⌥L или × — отмена.",
  ],
});
const A2 = frame({
  title: "A2 · Слушаем", sub: "живой текст бегущей строкой, как у Drop",
  msgr: { 0: [0.45, true] },
  island: `<div class="island" style="width:440px;height:62px">
    <div class="wing-l" style="gap:8px">${APP()} ${bars([5,11,8,13,6])}</div>
    <div class="wing-r" style="gap:10px"><span class="timer">0:19</span>${X}</div>
    <div class="line"><span class="fade">…давай либо на восемь, либо переносим </span>на субботу. И ещё, возьми<span class="new">, пожалуйста</span></div>
  </div>`,
  notes: [
    "Иконка слева — приложение, которое слушаем (здесь условный Messenger). Сразу видно, что звонок или музыка не пишутся.",
    "<b>Стоп:</b> ⌥L ещё раз, ×, или само — через 4 с тишины от этого приложения.",
    "<b>Минус:</b> одна строка. Длинное голосовое так не прочитать — читать придётся в конце.",
  ],
});
const A3 = frame({
  title: "A3 · Готово", sub: "карточка под островом, остаётся до закрытия",
  msgr: { 0: [1, false] },
  island: `<div class="island" style="width:460px;height:204px">
    <div class="wing-l" style="gap:8px">${APP()}</div>
    <div class="wing-r">${X}</div>
    <div class="card">
      <div class="meta"><b>Messenger</b> · 0:42 · 14:05</div>
      <div class="body">${T1}</div>
      <div class="actions"><span class="btn primary">Copy <span class="kbd">⌘C</span></span><span class="btn">Ask Agent <span class="kbd">⌘↩</span></span><span class="btn ghost">In History</span></div>
    </div>
  </div>`,
  notes: [
    "Финальный текст — второй проход по всей записи (как Retry у Drop), точнее живой строки.",
    "<b>Ask Agent</b> открывает Agent с этим текстом: «ответь на это», «что она хочет».",
    "Аудио не сохраняется. Текст уходит в History (строка Listen). Esc или × закрывают карточку.",
  ],
});

// ---------- Variant B: Whytap offers by itself
const B1 = frame({
  title: "B1 · Предложение", sub: "мессенджер начал звучать — остров спрашивает",
  msgr: { 0: [0.08, true] },
  island: `<div class="island" style="width:470px;height:62px">
    <div class="wing-l" style="gap:8px">${APP()}</div>
    <div class="wing-r" style="gap:10px"><span class="timer">0:03</span></div>
    <div class="line" style="display:flex;align-items:center;justify-content:space-between;text-align:left;top:34px">
      <span style="color:var(--ink)">Transcribe this voice message?</span>
      <span style="display:flex;gap:6px"><span class="btn primary" style="height:24px">Transcribe</span><span class="btn" style="height:24px">Skip</span></span>
    </div>
  </div>`,
  notes: [
    "<b>Триггер.</b> Приложение из списка мессенджеров начало выводить звук — CoreAudio сообщает это по процессу, без записи. Короче 1.5 с (звук уведомления) — игнор.",
    "<b>Начало не теряется:</b> с момента срабатывания звук держится только в памяти; Skip или 8 с без ответа стирают его. Это слабое место по приватности.",
    "Выключено по умолчанию: Settings → Other → «Offer to transcribe voice messages», список приложений.",
  ],
});
const B2 = frame({
  title: "B2 · Читаем во время воспроизведения", sub: "текст абзацем под островом",
  msgr: { 0: [0.6, true] },
  island: `<div class="island" style="width:460px;height:200px">
    <div class="wing-l" style="gap:8px">${APP()} ${bars([5,11,8,13,6])}</div>
    <div class="wing-r" style="gap:10px"><span class="timer">0:25</span>${X}</div>
    <div class="card">
      <div class="body">Привет! Слушай, по поводу пятницы — я посмотрела, у них свободно только на восемь, так что давай либо на восемь, либо переносим на субботу. И ещё, возьми<span class="tail">, пожалуйста, зарядку</span><span class="caret"></span></div>
      <div class="actions"><span class="btn">Copy <span class="kbd">⌘C</span></span><span class="btn">Ask Agent</span><span class="btn ghost">Stop <span class="kbd">esc</span></span></div>
    </div>
  </div>`,
  notes: [
    "Текст читается целиком, пока голосовое ещё играет. Последние слова светлее: они ещё могут уточниться.",
    "Конец: звук приложения затих на 4 с — карточка остаётся с финальным текстом (как A3).",
    "<b>Риск:</b> ложные срабатывания — видео, кружки, звонки в том же мессенджере. Звонок отсекаем по микрофону: если приложение пишет микрофон, это звонок, не голосовое.",
  ],
});

// ---------- Variant C: a series of messages as one thread
const C1 = frame({
  title: "C1 · Серия голосовых", sub: "одна сессия, каждое сообщение — свой блок",
  msgr: { 0: [1, false], 1: [1, false], 2: [0.55, true] },
  island: `<div class="island" style="width:480px;height:372px">
    <div class="wing-l" style="gap:8px">${APP()}<span class="timer" style="color:var(--ink)">3 messages</span></div>
    <div class="wing-r" style="gap:10px"><span class="timer">2:04</span>${X}</div>
    <div class="card" style="padding-top:10px">
      <div class="msg-block"><div class="meta">0:42</div><div class="body">${T1}</div></div>
      <div class="msg-block"><div class="meta">1:15</div><div class="body">${T2}</div></div>
      <div class="msg-block"><div class="meta"><span class="live-dot"></span> 0:13</div><div class="body">${T3a}<span class="tail">${T3b}</span><span class="caret"></span></div></div>
      <div class="actions" style="border-top:1px solid var(--rule);padding-top:12px;margin-top:4px"><span class="btn primary">Copy all <span class="kbd">⌘C</span></span><span class="btn">Ask Agent <span class="kbd">⌘↩</span></span><span class="btn ghost">Stop <span class="kbd">⌥L</span></span></div>
    </div>
  </div>`,
  notes: [
    "<b>Граница сообщения:</b> звук приложения замолк ≥ 1.2 с → новый блок с длительностью. Мессенджеры сами проигрывают голосовые подряд — один ⌥L на всю пачку.",
    "Автостоп через 20 с тишины. Stop, ⌥L или × — раньше.",
    "Copy all — блоки через пустую строку. Клик по блоку копирует только его. Длинная лента прокручивается, новое внизу.",
  ],
});
const C2 = frame({
  title: "C2 · Потом", sub: "где текст живёт после закрытия: History в Hover",
  msgr: { 0: [1, false], 1: [1, false], 2: [1, false] },
  island: `<div class="island" style="width:312px;height:262px;border-radius:0 0 18px 18px">
    <div class="card" style="top:40px;padding:0 10px">
      <div style="font:600 12px system-ui, 'Helvetica Neue', sans-serif;color:var(--ink-2);padding:0 6px 6px">History</div>
      ${[
        ["Listen", "Messenger · 3 messages · 2:20", "Привет! Слушай, по поводу пятницы — я…", true],
        ["Drop", "Notes · 14:01", "Купить зарядку, позвонить Лёше про договор"],
        ["Agent", "14:00", "Свободные столики в пятницу после 19:00…"],
        ["Clipboard", "13:52", "https://docs.example.com/contract-v3"],
      ].map(([k, m, t, sel]) => `<div style="padding:8px 8px;border-radius:10px;${sel ? "background:rgba(255,255,255,.10)" : ""};margin-bottom:2px">
        <div class="meta" style="font-size:11px"><b>${k}</b> · ${m}</div>
        <div style="font:13px/1.35 system-ui, 'Helvetica Neue', sans-serif;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px">${t}</div></div>`).join("")}
    </div>
  </div>`,
  notes: [
    "Текст хранится в History (локальная база, не в бэкапах), как Drop и Agent. Аудио — никогда.",
    "Return по строке — вставить, ⌘C — скопировать, как у остальных строк History.",
    "Одна сессия = одна строка, внутри блоки сообщений.",
  ],
});

const pages = {
  "variant-A-listen-button": page("A · Кнопка Listen", "Явный жест: ⌥L взводит, затем включаешь голосовое. Живой текст одной строкой в острове, полный текст — в карточке после окончания.", [A1, A2, A3]),
  "variant-B-auto-offer": page("B · Whytap предлагает сам", "Мессенджер начал звучать — остров спрашивает «расшифровать?». Текст читается абзацем, пока голосовое играет.", [B1, B2]),
  "variant-C-series": page("C · Серия голосовых", "Один запуск на пачку голосовых: каждое сообщение — свой блок, общий Copy all и Ask Agent. Потом всё лежит в History.", [C1, C2]),
};

for (const [name, html] of Object.entries(pages)) writeFileSync(path.join(SRC, `${name}.html`), html);

const browser = await chromium.launch({ executablePath: "/Users/maxim/Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" });
const ctx = await browser.newContext({ deviceScaleFactor: 2, viewport: { width: 1230, height: 900 } });
const pg = await ctx.newPage();
for (const name of Object.keys(pages)) {
  await pg.goto("file://" + path.join(SRC, `${name}.html`));
  await pg.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: true });
  const frames = await pg.$$(".frame");
  const ids = { "variant-A-listen-button": ["A1", "A2", "A3"], "variant-B-auto-offer": ["B1", "B2"], "variant-C-series": ["C1", "C2"] }[name];
  for (let i = 0; i < frames.length; i++) await frames[i].screenshot({ path: path.join(OUT, "frames", `${ids[i]}.png`) });
}
await browser.close();
console.log("ok");
