// v2 mockups: transcribe voice messages without listening. Run: node build2.mjs
import { writeFileSync, mkdirSync, copyFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
const require = createRequire("/Users/maxim/node_modules/");
const { chromium } = require("playwright");

const OUT = "/Users/maxim/.claude/orchestrator/voice-messages/v2";
const SRC = path.join(OUT, "src");
mkdirSync(path.join(OUT, "frames"), { recursive: true });
mkdirSync(SRC, { recursive: true });
copyFileSync("/Users/maxim/.claude/orchestrator/voice-messages/src/mock.css", path.join(SRC, "mock.css"));

const F = "system-ui, 'Helvetica Neue', sans-serif";
const PLAY = `<svg width="12" height="12" viewBox="0 0 12 12"><path d="M3 1.5v9l7.5-4.5z" fill="#fff"/></svg>`;
const PAUSE = `<svg width="12" height="12" viewBox="0 0 12 12"><rect x="2.5" y="1.5" width="2.6" height="9" rx="1" fill="#fff"/><rect x="7" y="1.5" width="2.6" height="9" rx="1" fill="#fff"/></svg>`;
const APP = () => `<span class="appicon"><svg width="10" height="10" viewBox="0 0 10 10"><path d="M5 1C2.8 1 1 2.5 1 4.4c0 1 .5 1.9 1.3 2.5L2 9l2.1-1.2c.3.1.6.1.9.1 2.2 0 4-1.5 4-3.5S7.2 1 5 1z" fill="#fff"/></svg></span>`;
const FILEICON = (c = "#8e8e93") => `<svg width="18" height="20" viewBox="0 0 18 20"><path d="M2 1h9l5 5v12a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V2a1 1 0 0 1 1-1z" fill="#fff" stroke="${c}" stroke-width="1"/><path d="M11 1v5h5" fill="none" stroke="${c}"/><path d="M5 12h1M7 10v4M9 9v6M11 11v2" stroke="${c}" stroke-width="1.2" stroke-linecap="round"/></svg>`;
const FOLDER = `<svg width="16" height="16" viewBox="0 0 16 16"><path d="M1 4a1 1 0 0 1 1-1h4l1.5 1.5H14a1 1 0 0 1 1 1V13a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1z" fill="#5ac8fa"/></svg>`;
const MUTED = `<svg width="16" height="14" viewBox="0 0 16 14"><path d="M1 5h3l4-3.5v11L4 9H1z" fill="#f5f5f7"/><path d="M11 4.5l4 5M15 4.5l-4 5" stroke="#f5f5f7" stroke-width="1.5" stroke-linecap="round"/></svg>`;
const SPIN = `<svg width="14" height="14" viewBox="0 0 14 14"><circle cx="7" cy="7" r="5.5" stroke="rgba(255,255,255,.2)" stroke-width="2" fill="none"/><path d="M7 1.5a5.5 5.5 0 0 1 5.5 5.5" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round"/></svg>`;
const X = `<span class="x"><svg width="8" height="8" viewBox="0 0 8 8"><path d="M1 1l6 6M7 1L1 7" stroke="rgba(255,255,255,.75)" stroke-width="1.4" stroke-linecap="round"/></svg></span>`;
const bars = (h) => `<span class="bars">${h.map((v) => `<i style="height:${v}px"></i>`).join("")}</span>`;
const WAVE = [6,10,14,9,16,20,12,8,14,18,10,6,12,16,20,14,9,6,10,14,18,12,8,6,10,14,9,12,16,10,7,5];
const wave = (p) => WAVE.map((h, i) => `<i style="height:${h}px" class="${i / WAVE.length < p ? "p" : ""}"></i>`).join("");
const voice = (dur, p = 0, playing = false, chip = "") =>
  `<div class="voice${playing ? " playing" : ""}"><span class="play">${playing ? PAUSE : PLAY}</span><span class="wave">${wave(p)}</span>${chip}<span class="dur">${dur}</span></div>`;

const T1 = "Привет! Слушай, по поводу пятницы — я посмотрела, у них свободно только на восемь, так что давай либо на восемь, либо переносим на субботу. И ещё, возьми, пожалуйста, зарядку, я свою опять забыла у мамы.";
const T2 = "Короче, я поговорила с Лёшей, он сказал, что договор пришлют завтра до обеда, но там надо будет поправить реквизиты, потому что они опять старые вставили. Сможешь глянуть? Я тебе скину на почту.";

const menubar = (app) => `<div class="menubar"><div class="l"><span>&#63743;</span><b>${app}</b><span>File</span><span>Edit</span><span>View</span><span>Window</span></div><div class="r"><span>Wi‑Fi</span><span>100%</span><span>Sun 22 Nov 14:05</span></div></div>`;

const menu = (items, style) => `<div style="position:absolute;${style};min-width:210px;background:rgba(246,246,248,.96);border-radius:9px;padding:5px;box-shadow:0 12px 40px rgba(0,0,0,.35),0 0 0 .5px rgba(0,0,0,.25);font:13px ${F};color:#1d1d1f;z-index:8">${items
  .map((it) => (it === "-" ? `<div style="height:1px;background:#d8d8dc;margin:4px 8px"></div>` : `<div style="padding:4px 10px;border-radius:5px;display:flex;justify-content:space-between;${it.hl ? "background:#0a64ff;color:#fff" : ""}">${it.t}<span style="opacity:.6">${it.r ?? ""}</span></div>`))
  .join("")}</div>`;

function messenger({ playing = -1, p = 0, chip = "", overlay = "" } = {}) {
  return `<div class="win"><div class="dots"><i></i><i></i><i></i></div>
  <div class="side">
    <div class="chat-item sel"><span class="ava">А</span><div>Аня<small>Голосовое · 0:23</small></div></div>
    <div class="chat-item"><span class="ava b">Р</span><div>Рабочий чат<small>Лёша: ок, завтра</small></div></div>
    <div class="chat-item"><span class="ava c">М</span><div>Мама<small>Фото</small></div></div>
  </div>
  <div class="main" style="position:relative">
    <div class="head"><span class="ava" style="width:30px;height:30px">А</span><div>Аня<small>в сети</small></div></div>
    <div class="msgs">
      <div class="text-msg">ну что там по пятнице?</div>
      ${voice("0:42", playing === 0 ? p : 0, playing === 0, playing === 0 ? chip : "")}
      ${voice("1:15")}
      ${voice("0:23")}
    </div>
    <div class="compose">Сообщение…</div>${overlay}
  </div></div>`;
}

function finder(rows, overlay = "") {
  return `<div class="win" style="grid-template-columns:170px 1fr"><div class="dots"><i></i><i></i><i></i></div>
  <div class="side" style="font:12px ${F};color:#6b6b73;padding-top:44px">
    <div style="padding:2px 8px 6px;font-weight:600">Favorites</div>
    ${["Recents", "Applications", "Desktop", "Documents", "Downloads"].map((n) => `<div style="padding:5px 8px;border-radius:6px;display:flex;gap:6px;align-items:center;color:#1d1d1f;${n === "Downloads" ? "background:#dcdce1" : ""}">${FOLDER}${n}</div>`).join("")}
  </div>
  <div class="main" style="position:relative">
    <div class="head" style="justify-content:space-between">Downloads<small style="display:inline">4 items</small></div>
    <div style="padding:6px 10px;font:13px ${F};color:#1d1d1f">
      <div style="display:grid;grid-template-columns:1fr 70px 70px;color:#8a8a92;font-size:11.5px;padding:4px 8px">Name<span>Size</span><span>Kind</span></div>
      ${rows.map((r) => `<div style="display:grid;grid-template-columns:1fr 70px 70px;align-items:center;padding:5px 8px;border-radius:6px;${r.sel ? "background:#0a64ff;color:#fff" : ""}"><span style="display:flex;gap:8px;align-items:center">${FILEICON(r.sel ? "#fff" : "#8e8e93")}${r.n}</span><span style="opacity:.7">${r.s}</span><span style="opacity:.7">${r.k}</span></div>`).join("")}
    </div>${overlay}
  </div></div>`;
}

function frame({ title, sub, app = "Messenger", win, island = "", notes, extra = "" }) {
  return `<section class="frame-wrap"><div class="frame-title">${title} <span>${sub}</span></div>
  <div class="frame">${menubar(app)}${win}${island}${extra}<div class="notes">${notes.map((n, i) => `<div class="note"><span class="n">${i + 1}</span>${n}</div>`).join("")}</div></div></section>`;
}
const page = (h1, lede, frames) => `<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="mock.css"></head><body>
<h1>${h1}</h1><p class="lede">${lede}</p>${frames.join("\n")}</body></html>`;

const actions = (copyAll) => `<div class="actions"><span class="btn primary">${copyAll ? "Copy all" : "Copy"} <span class="kbd">⌘C</span></span><span class="btn">Ask Agent <span class="kbd">⌘↩</span></span><span class="btn ghost">Show file</span></div>`;

// ---------- 1. Downloads folder
const D1 = frame({
  title: "1A · Скачал — и всё", sub: "в мессенджере «Сохранить как…», дальше Whytap сам",
  win: messenger({ overlay: menu([{ t: "Reply" }, { t: "Forward" }, "-", { t: "Save As…", hl: true }, { t: "Copy Link" }, "-", { t: "Delete" }], "left:230px;top:150px") }),
  island: `<div class="island" style="width:440px;height:96px">
    <div class="wing-l" style="gap:8px">${APP()}</div><div class="wing-r">${X}</div>
    <div class="card" style="padding-top:8px">
      <div class="meta" style="gap:10px">${SPIN}<b>Transcribing</b> voice_2026-11-22_14-05.ogg · 0:42</div>
      <div class="meta" style="margin-top:6px;color:var(--ink-3)">From Downloads · On this Mac</div>
    </div></div>`,
  notes: [
    "<b>Действия пользователя:</b> 2–3 клика в мессенджере (правый клик → «Сохранить как…» → Save). В Whytap — ни одного в режиме Automatically (на кадре), один клик Transcribe в режиме Ask first.",
    "Whytap следит за папкой Загрузки (или выбранной). Файл берётся, когда перестал расти 1 с; временные .crdownload/.part/.download пропускаются.",
    "Иконка слева — откуда файл, если macOS это знает (метка карантина у скачанного). Иначе — значок файла.",
  ],
});
const D2 = frame({
  title: "1B · Готово, несколько подряд", sub: "файлы, скачанные в течение минуты, — одна карточка",
  win: messenger(),
  island: `<div class="island" style="width:480px;height:330px">
    <div class="wing-l" style="gap:8px">${APP()}<span class="timer" style="color:var(--ink)">2 voice messages</span></div><div class="wing-r">${X}</div>
    <div class="card" style="padding-top:10px">
      <div class="msg-block"><div class="meta">voice_14-05.ogg · 0:42</div><div class="body">${T1}</div></div>
      <div class="msg-block"><div class="meta">voice_14-06.ogg · 1:15</div><div class="body">${T2}</div></div>
      <div style="border-top:1px solid var(--rule);margin-top:4px">${actions(true)}</div>
    </div></div>`,
  notes: [
    "Минута голосовых расшифровывается за ~1–3 с: пакетный проход по файлу, без прослушивания.",
    "Copy all, Ask Agent («ответь на это»), Show file — открыть в Finder. Текст — строка в History; сам файл Whytap не трогает.",
    "Карточка остаётся до ×/Esc; если не смотрел — текст ждёт в History.",
  ],
});
const SETTINGS = `<div class="win" style="display:block;left:180px;width:640px;height:400px;background:#f5f5f7">
  <div class="dots"><i></i><i></i><i></i></div>
  <div style="padding:46px 28px 0;font:${F}">
    <div style="font:600 20px ${F};color:#1d1d1f;margin-bottom:14px">Other</div>
    <div style="background:#fff;border-radius:10px;padding:4px 14px;box-shadow:0 0 0 .5px #d8d8dc;font:13px ${F};color:#1d1d1f">
      ${[
        ["Transcribe voice messages", "Text of voice files you download, without playing them", `<span style="width:30px;height:18px;border-radius:9px;background:#0a64ff;display:inline-block;position:relative"><i style="position:absolute;right:2px;top:2px;width:14px;height:14px;border-radius:50%;background:#fff"></i></span>`],
        ["Watch folder", "", `<span style="border:1px solid #d0d0d6;border-radius:8px;padding:4px 10px">Downloads ⌄</span>`],
        ["When a voice file appears", "", `<span style="border:1px solid #d0d0d6;border-radius:8px;padding:4px 10px">Ask first ⌄</span>`],
        ["Skip files longer than", "Music and podcasts stay untouched", `<span style="border:1px solid #d0d0d6;border-radius:8px;padding:4px 10px">10 min ⌄</span>`],
      ].map(([t, s, c], i) => `<div style="display:flex;justify-content:space-between;align-items:center;padding:11px 0;${i ? "border-top:1px solid #ececf0" : ""}"><div>${t}${s ? `<div style="font-size:11.5px;color:#8a8a92;margin-top:2px">${s}</div>` : ""}</div>${c}</div>`).join("")}
    </div>
    <div style="font:11.5px ${F};color:#8a8a92;margin:10px 4px">Ask first: the island offers Transcribe. Automatically: only .ogg / .opus / .oga / .m4a voice files that are mono and short.</div>
  </div></div>`;
const D3 = frame({
  title: "1C · Настройка", sub: "Settings → Other, выключено по умолчанию", app: "Whytap", win: SETTINGS,
  notes: [
    "<b>Права:</b> Загрузки — защищённая папка: macOS один раз спросит «Whytap хочет доступ к Загрузкам». Другая папка через выбор в Finder — без вопроса.",
    "<b>Ask first</b> (по умолчанию): остров спрашивает «Transcribe?». <b>Automatically</b> — только похожее на голосовое: короткое, моно, низкий битрейт.",
    "Музыка (стерео, 128+ кбит/с) и файлы длиннее порога не трогаются: не тратим деньги и не шлём чужое провайдеру.",
  ],
});

// ---------- 2. Drag onto the island + Finder Quick Action
const Q1 = frame({
  title: "2A · Перетащить на остров", sub: "из Finder или прямо из мессенджера, если он отдаёт файл", app: "Finder",
  win: finder([
    { n: "voice_2026-11-22_14-05.ogg", s: "142 KB", k: "Ogg" },
    { n: "voice_2026-11-22_14-06.ogg", s: "251 KB", k: "Ogg" },
    { n: "contract-v3.pdf", s: "1.2 MB", k: "PDF" },
    { n: "IMG_2041.HEIC", s: "2.8 MB", k: "Image" },
  ]),
  island: `<div class="island" style="width:420px;height:92px;box-shadow:0 0 0 2px #3d8bff, 0 8px 30px rgba(61,139,255,.35)">
    <div class="card" style="top:30px;text-align:center"><div class="body" style="margin-top:6px;font-weight:600">Drop to transcribe</div><div class="meta" style="justify-content:center;margin-top:4px">2 audio files</div></div></div>`,
  extra: `<div style="position:absolute;left:600px;top:100px;transform:rotate(-4deg);z-index:9;display:flex;gap:8px;align-items:center;background:rgba(255,255,255,.85);border-radius:8px;padding:6px 10px;font:12px ${F};box-shadow:0 6px 20px rgba(0,0,0,.3)">${FILEICON()} 2 items</div>`,
  notes: [
    "Остров подсвечивается, только когда тащат аудиофайл. Несколько файлов — одна карточка с блоками, как 1B.",
    "<b>Прямо из мессенджера:</b> перетаскивание голосового наружу из Telegram/WhatsApp/eXpress я в документации не нашёл — скорее всего, сначала «Сохранить как…». Проверить руками.",
    "<b>Действия:</b> скачать (2–3 клика) + открыть Finder + перетащить. Дольше, чем 1A, но не нужен доступ к папке.",
  ],
});
const Q2 = frame({
  title: "2B · Quick Action в Finder", sub: "правый клик по файлу → Quick Actions → Transcribe with Whytap", app: "Finder",
  win: finder([
    { n: "voice_2026-11-22_14-05.ogg", s: "142 KB", k: "Ogg", sel: true },
    { n: "voice_2026-11-22_14-06.ogg", s: "251 KB", k: "Ogg" },
    { n: "contract-v3.pdf", s: "1.2 MB", k: "PDF" },
  ], menu([{ t: "Open" }, { t: "Open With", r: "›" }, "-", { t: "Copy" }, { t: "Share…" }, "-", { t: "Quick Actions", r: "›", hl: true }], "left:40px;top:110px") +
    menu([{ t: "Transcribe with Whytap", hl: true }, { t: "Rotate Left" }, { t: "Customize…" }], "left:255px;top:258px")),
  notes: [
    "Это macOS Service в Info.plist Whytap (тип файла — аудио), без отдельного расширения. Работает и в «Службах» других приложений.",
    "Результат — та же карточка у острова (1B).",
    "<b>Буфер:</b> ⌘C по аудиофайлу в Finder → History видит путь к файлу и может предложить Transcribe. Полезно редко — не рисую отдельно.",
  ],
});

// ---------- 3. Silent capture fallback
const S1 = frame({
  title: "3 · Тихий захват (запасной путь)", sub: "мессенджер не даёт скачать: ⌥L, включить голосовое на 2×, звук не слышен",
  win: messenger({ playing: 0, p: 0.45, chip: `<span style="font:600 11px ${F};color:#2f6bff;background:#e6eeff;border-radius:6px;padding:2px 5px">2×</span>` }),
  island: `<div class="island" style="width:460px;height:178px">
    <div class="wing-l" style="gap:8px">${APP()}${MUTED}</div>
    <div class="wing-r" style="gap:10px"><span class="timer">0:10 / 0:21</span>${X}</div>
    <div class="card">
      <div class="meta">Listening silently · the app's sound is off for you</div>
      <div class="body">Привет! Слушай, по поводу пятницы — я посмотрела, у них свободно только на восемь, так что давай либо на восемь<span class="tail">, либо переносим</span><span class="caret"></span></div>
      <div class="actions"><span class="btn">Copy <span class="kbd">⌘C</span></span><span class="btn">Ask Agent</span><span class="btn ghost">Stop <span class="kbd">⌥L</span></span></div>
    </div></div>`,
  notes: [
    "CoreAudio tap только на процесс мессенджера с <code>muteBehavior = .muted</code>: по документации Apple звук захватывается и <b>не идёт</b> в колонки. Руками не проверено.",
    "Ждать всё равно приходится: 42 с голосового на 2× — 21 с. Зато не слушаешь и можешь делать другое.",
    "<b>Минусы:</b> пока идёт захват, глушится весь звук мессенджера; 2× не во всех мессенджерах; распознавание на 2× хуже (гипотеза).",
  ],
});

const pages = {
  "variant-1-downloads": page("1 · Папка Загрузки", "Нажал «Скачать» в мессенджере — Whytap видит новый аудиофайл и расшифровывает его без прослушивания. Работает с любым мессенджером, который отдаёт файл.", [D1, D2, D3]),
  "variant-2-drop-and-quick-action": page("2 · Перетащить на остров / Quick Action", "Ручные входы в тот же конвейер: файл на остров или правый клик в Finder. Без доступа к папке.", [Q1, Q2]),
  "variant-3-silent-capture": page("3 · Тихий захват", "Запасной путь для мессенджера без скачивания: звук приложения перехватывается и не слышен, голосовое можно включить на 2×.", [S1]),
};
const ids = { "variant-1-downloads": ["1A", "1B", "1C"], "variant-2-drop-and-quick-action": ["2A", "2B"], "variant-3-silent-capture": ["3"] };
for (const [name, html] of Object.entries(pages)) writeFileSync(path.join(SRC, `${name}.html`), html);

const browser = await chromium.launch({ executablePath: "/Users/maxim/Library/Caches/ms-playwright/chromium-1248/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" });
const pg = await (await browser.newContext({ deviceScaleFactor: 2, viewport: { width: 1230, height: 900 } })).newPage();
for (const name of Object.keys(pages)) {
  await pg.goto("file://" + path.join(SRC, `${name}.html`));
  await pg.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: true });
  const frames = await pg.$$(".frame");
  for (let i = 0; i < frames.length; i++) await frames[i].screenshot({ path: path.join(OUT, "frames", `${ids[name][i]}.png`) });
}
await browser.close();
console.log("ok");
