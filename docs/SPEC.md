# Whytap — Спецификация продукта

> **Статус 2026-09.** Whytap — полностью локальный бесплатный open-source
> инструмент (MIT). Whytap-облака, аккаунтов, тарифов и телеметрии больше
> нет: STT и LLM работают либо на устройстве (Apple Silicon), либо напрямую
> у провайдера ключом пользователя; агент — локальный Claude Code / Codex.
> Разделы ниже про roadmap и vocabulary написаны в облачную эпоху и
> сохранены как продуктовый контекст; упоминания backend/подписки в них не
> актуальны. См. `docs/plans/2026-09-02-fully-local-open-source.md`.

> Версия 3. Базовая продуктовая версия — 2026-05-09; освежена после
> июньского пивота (агент = локальный CLI пользователя, монетизация =
> STT + meetings). Vision-разделы (vocabulary, artifacts, learning)
> остаются целевыми; «Что уже работает» отражает текущий клиент.

## Позиционирование

**Whytap превращает грязную речь в готовый к работе текст, ссылки и действия — внутри того приложения, в котором ты уже работаешь.**

Не "ещё одна диктовка". Голосовой слой поверх рабочих инструментов: говоришь как думаешь, а в Slack, Linear, Notion, GitHub, Cursor попадает уже готовое сообщение, тикет, промпт или артефакт — с правильным языком, стилем, ссылками и контекстом.

## Главный UX-принцип: приложение невидимо

Пользователю **не нужно ничего изучать**. SuperWhisper открывает огромное окно с настройками — у нас наоборот:

- Никаких больших окон с настройками
- Никакой админки и панелей управления
- Никакого onboarding-туториала
- Только маленькая плашечка справа снизу, которая всё делает за пользователя

Пользователь открыл приложение → увидел плашечку → начал работать. Всё. Никаких вопросов, никакого «как этим пользоваться». Любые настройки появляются только когда они нужны прямо сейчас и в минимально возможной форме (chips/labels в самой плашечке, не отдельные окна).

## Целевая аудитория

Knowledge workers — разработчики, продакт-менеджеры, операционщики. Стартовая аудитория: наша команда и круг (стек Slack, Linear, Notion, GitHub, Cursor).

## Что уже работает

- macOS 14.2+, Swift + AppKit + SwiftUI; surface — Dynamic Island (status-bar item нет)
- Voice flow: hold Space (удержание пробела в редактируемом поле; Escape — отмена) → запись → realtime STT: Local (FluidAudio Parakeet TDT v3, Apple Silicon) или «Your key» (OpenAI Realtime / Deepgram / Soniox / ElevenLabs / self-hosted OpenAI-compatible, напрямую ключом пользователя из Keychain) → cleanup (Local MLX Qwen3 / OpenRouter ключом пользователя / custom OpenAI-compatible endpoint / без LLM) → Cmd+V
- Agent flow: Right Cmd tap/hold → локальный agent-CLI пользователя (Connect Claude / Codex), рендер в окне
- Meeting Notes: always-on детектор → запись (mic + system audio) → fully-local pipeline (Parakeet + FluidAudio диаризация + MLX саммари) или BYOK-процессор → notes window
- App-aware форматирование (Notion/Linear/Slack/Telegram → markdown, остальное → plain)
- Без аккаунта, без серверов Whytap, без телеметрии
- Sparkle auto-update (download-on-action, pill в Dynamic Island), фид — GitHub Releases
- Bundle `com.rootwise.sidekey`
- Репозиторий: [AbsoluteMode/whytap](https://github.com/AbsoluteMode/whytap)

---

## Roadmap

### Milestone 1 — Диктовка, которой можно доверять

**Цель:** пользователь делает 30-100 вставок в день, ни разу не подумав "проще было напечатать".

| Фича | Описание |
|------|----------|
| Output language | Куда вставлять (русский, английский, …) |
| Input language / auto | На каком говорим |
| App-aware formatting | Уже есть, дорабатываем под целевые приложения |
| Manual vocabulary | Для bootstrap, до auto-learning |
| Voice Clipboard | Последние 20-50 результатов: поиск, copy, re-run, edit, delete (вместо "архив всех записей") |
| **Voice Edit** | Единая фича работы с текстом в области курсора. Если есть выделение — работаем с выделением, иначе — со всем содержимым поля. AX читает текст, LLM правит, заменяет. Use cases: перевод ("переведи на английский" — наш USP, лучше DeepL за счёт technical vocabulary + screen context), стиль ("сделай короче"), редактирование поля ("замени X на Y", "добавь приветствие"). Edit chip появляется когда курсор в text field с содержимым, скрывается через AX observers (focus change / app switch / value clear) — без таймера. **Cmd+Z отменяет правку.** |
| **Customizable hotkeys** | Пользователь может переназначить любой хоткей: диктовка, edit, ask mode. Дефолт `Right Option + /`, `Right Option + .` и т.п. |
| Screenshot gating | Скриншот не всегда — только когда есть deictic words ("вот это", "там"), high-context app или low confidence по терминам |
| Native macOS distribution | Code-signed DMG с нотаризацией (Apple Developer Team `<TEAM_ID>`). Установка drag-to-Applications, auto-update mechanism. |
| Basic eval suite | p95 latency, correction rate, edit distance after paste |

**Метрики успеха M1:**
- p95 latency на вставку
- Edit distance пользователя после нашей вставки
- Dictations per active user per day
- 7-day retention
- "Would you be upset if this disappeared?" survey

### Milestone 2 — Рабочий контекст

**Цель:** Whytap вставляет не просто текст, а текст с правильными ссылками, цитатами и тикетами.

| Фича | Описание |
|------|----------|
| **Artifact Suggestions** | Параллельный pipeline ищет связанные артефакты в Slack/Linear/Notion/GitHub. **НЕ вставляет** в текст — показывает как chip-карточки под полем ввода с превью и кнопкой attach. Пользователь сам прикрепляет нужное. |
| Anchored search only | Поиск артефактов **только при наличии якоря**: выделение, активный канал, URL вкладки, Linear/PR на экране, последнее скопированное, явное имя. Без якоря — не угадываем. |
| Slack channel/thread context | Знаем где ты сейчас в Slack |
| Linear issue detection | Из URL вкладки или скриншота |
| GitHub PR/repo/branch context | Из URL или активного редактора |
| Notion page context | Из URL вкладки |
| Auto workspace vocabulary | Словарь из Slack/Linear/Notion/GitHub: термины, люди, проекты, репозитории, ветки, тикеты + произносительные alias ("локейт" → Lokate) |
| Per-recipient style memory | С этим человеком — формально по-английски, в этот канал — коротко, в Telegram — casual |
| Artifact cards в Voice Clipboard | Видно какие артефакты были использованы и почему |
| Confidence thresholds | Низкая уверенность — не подмешиваем артефакт, лучше без него |

### Milestone 3 — Ask Mode (Connect Claude / Codex)

**Цель:** голосовой/текстовый ассистент поверх рабочего контекста. После
июньского пивота «мозг» — собственный локальный agent-CLI пользователя
(Claude Code или Codex), запущенный на его машине под его логином: его
подписка, его MCP-серверы, его память. Whytap = голос+UX; серверного
агента, managed-коннекторов и серверной памяти у нас НЕТ.

**UX-принципы (КРИТИЧНО):**
- **Никаких открытых окон поверх экрана без нужды** — ответ в pill/окне справа снизу
- Pill при ответе расширяется в более крупный bar (минималистичный, не модальное окно)
- Ответ короткий, естественный, с кнопкой copy / open link

**Активация:** Right Cmd (tap — текст, hold — голос).

**Подключение:** Settings → Agents → **Connect Claude Code** / **Connect
Codex**. Одновременно активен один; выбор другого заменяет активного.
Доступ к данным/инструментам определяется конфигом CLI пользователя
(его MCP-серверы), а не нами.

**Примеры (зависит от MCP пользователя):**

| Запрос | Как отвечает |
|--------|-------------|
| "Когда у меня следующая встреча?" | "В Antline с Сашей через полчаса" + кнопка open in Calendar |
| "Сева мне поставил задачу — какая?" | Ссылка на LIN-234 с заголовком + open |
| "Что в #product за последний час?" | 1-2 строки summary + open thread |
| "Какой PR у меня сейчас в работе?" | Имя PR + open в GitHub |
| "Что в README этого проекта про авторизацию?" | Цитата + open |

Safety и write-actions — на стороне CLI пользователя и его tool-permission
модели; Whytap их не проксирует и не хранит.

---

## Vocabulary architecture

> *Vision-раздел: архитектура продумана, не реализована. После пивота
> Whytap НЕ держит серверных коннекторов к Slack/Linear/Notion/GitHub —
> рабочий контекст приходит через CLI/MCP пользователя или из экрана.
> Таблица «Источники» ниже — целевая модель, а не текущая sync-инфра.*

### Где работает vocab

На **обоих** этапах pipeline, с разной логикой:

| Этап | Размер | Зачем | Что включаем |
|------|--------|-------|--------------|
| **Transcribe** (STT-промпт) | ~30 терминов | Чтобы STT правильно **расслышал** слово | Канонические термины + произносительные aliases ("Lokate; локейт; локате") |
| **Verify** (cleanup-промпт) | ~100-150 терминов | Чтобы LLM **исправил написание** + нормализовал | Только канонические формы |

Двухступенчатый ranking — до транскрипции (только app/screenshot) и после (+ raw text как сигнал).

### Источники

| Источник | Что забираем | Sync |
|----------|--------------|------|
| Slack | Каналы, люди, термины из сообщений | Initial pull 30 дней + events API |
| Linear | Проекты, тикеты (LIN-XXX), assignees, labels | GraphQL pull + webhook |
| Notion | Заголовки страниц, теги, базы | Initial pull + polling |
| GitHub | Repos, branches, PR, files, people | API pull + webhook |
| Screenshot OCR | Редкие слова из активного окна | On-fly при low confidence |
| User edits | Что правил после нашей вставки | Local diff loop |
| Manual | Через Settings | Bootstrap |

### Хранилище

Local SQLite. Минимальная структура: `term`, `aliases[]`, `source`, `frequency`, `last_seen`, `embedding`, `app_affinity`, `is_core`, `user_confirmed`.

### Ranking

```
score(term) =
    embedding_similarity(term, context) * 0.4 +
    app_affinity[active_app]            * 0.25 +
    log(frequency)                      * 0.15 +
    recency_decay(last_seen)            * 0.10 +
    user_confirmed_boost                * 0.10
```

Контекст: активное приложение + screenshot + selection + последняя вставка + (после транскрипции) raw text.

### Pronunciation aliases

| Способ | Когда |
|--------|-------|
| Auto-generation | LLM генерирует русские варианты при добавлении |
| Explicit user rule | "запомни локейт это Lokate" |
| Edit-driven | Поправил Spherix → Sferyx — добавляем alias |
| Acronym pattern | LIN-234 → "лин 234" |

### Embeddings

- **Старт:** OpenAI `text-embedding-3-small` (~$0.02 / 1M токенов)
- **Будущее:** локально через MLX/Foundation Models — privacy + no cost

### Privacy gates

- Per-source opt-in (Slack/Linear/Notion/GitHub отдельно)
- Per-channel denylist
- DM не индексируем по умолчанию
- Приватные каналы только с opt-in
- Clear vocabulary — полный сброс
- Private mode — выключает auto-vocabulary на сессию

### Открытые вопросы по vocab

1. **Embedding cost vs latency** — в реальном времени embed нового термина или batch?
2. **Cold start** — что делать в первые часы пока auto-vocab не заполнен?
3. **Cross-workspace conflicts** — два workspace с разными значениями одного термина?
4. **Decay strategy** — когда удалять давно не виденные термины?
5. **Delivery** — реализуем сами или поверх готовых решений (sqlite-vec, MLX)?

---

## Архитектура pipeline

```
audio
  ↓
realtime transcribe (backend-хаб /api/transcribe/stream/v2, провайдер
  на сервере) ИЛИ BYOK direct (Your key → провайдер напрямую)
  ИЛИ Local (FluidAudio Parakeet Core ML на устройстве)
  ↓
intent / context router
  ↓                    ↓
optional context pack  voice action on selection
  - active app         (если хоткей selection)
  - selected text
  - URL вкладки
  - screenshot (gated)
  - vocabulary
  - artifacts (anchored)
  ↓                    ↓
compose / cleanup      (backend; модель не фиксируется в спеке)
  ↓
paste / replace
  ↓
correction & learning loop
```

**STT-провайдеры (whytap-уровень, выбор на сервере per-user + language-fallback):**
Soniox (`stt-rt-v4`), Deepgram (`nova-3`), OpenAI (`gpt-4o-transcribe`),
ElevenLabs (`scribe_v2_realtime`). BYOK добавляет OpenAI-Realtime-совместимый
self-hosted endpoint. Это realtime streaming, не batch.

**Local STT (Pro):** FluidAudio Parakeet TDT v3 (`int8` encoder, Core ML).
Модель скачивается из Settings → Models в app-owned
`Application Support/Sidekey/LocalTranscriptionModels`, держится в памяти
после load/download до удаления модели или выхода из приложения. Local Drop
bypass'ит cleanup-LLM и `/api/process`, поэтому после скачивания модели
может работать offline; результат проходит только локальный filler-filter и
paste/history хвост.

**Screenshot gating (не всегда):**
- Включаем если: deictic words ("вот это", "там", "этот тикет") / high-context app (Slack, Linear, Notion, GitHub, Cursor) / low confidence по терминам / "screen context always" в настройках
- Выключаем если: privacy-denylisted app / sensitive surface на экране / простая диктовка длинного текста

---

## Learning from user edits — три слоя

| Слой | Что делает | Trust level |
|------|-----------|-------------|
| **Explicit correction** | "Запомни: локейт → Lokate", "В Slack делай короче" → memory rule | Высокий |
| **Local diff after last insert** | Только opt-in. Сравниваем то что вставили с тем что осталось через окно времени. Diff → vocabulary candidate. Не читаем весь документ, не логируем поле. | Средний |
| **Reviewable learning inbox** | "Я заметил 4 повторяющиеся правки. Запомнить?" — пользователь подтверждает | Высокий |

**Не делаем:** скрытый keylogger, "мы всё анализируем в фоне".

---

## Privacy as product

Это не юридический текст, а часть UX:

- Per-app privacy denylist — "никогда не скриншотить эти приложения"
- "Never store audio" option
- Encrypted local SQLite для Voice Clipboard
- One-click delete history
- Visible log: что отправлено, куда, зачем
- BYOK («Your key») — STT и LLM напрямую у провайдера ключом пользователя, ключ в Keychain
- Local («Local model») — STT, диаризация и LLM на устройстве, без сети после скачивания весов

> Доступ к Slack/Notion/GitHub и т.п. живёт на стороне CLI пользователя
> (его MCP-серверы), не у нас — мы scopes и индексацию не держим.

---

## Meeting Notes

Auto-detect когда пользователь на голосовой встрече (Zoom, Meet, Teams, FaceTime, Discord, Slack huddle и т.п.) и предложить записать структурированную заметку. Whytap уже всегда запущен и имеет JWT — нативное место для этой фичи (vs. Granola/tl;dv как отдельные продукты с собственной авторизацией).

**Signal:** mic-in-use AND speech-in-system-audio (CoreAudio process-tap). Отсекает Whytap-like dictation (нет двусторонней речи) и музыку/видео (нет mic). VAD через FluidAudio (Silero на ANE, macOS 14.2+).

**UX:** nudge «Take notes / Skip» под Dynamic Island с decision window (ignore = decline). После accept — recorder, чанковый upload. Окно «Meetings» (Notion-like editable markdown, BlockNote в WKWebView) открывается из Dynamic Island.

**Backend (`sidekey-meetings-backend`, отдельный Docker контейнер):**
- `POST /meetings/<id>/chunks/<idx>` — resumable upload ~30s WAV
- `POST /meetings/<id>/finalize` — trigger pipeline (concat → Soniox async diarize → LLM summary → markdown)
- `GET /meetings`, `GET /meetings/<id>` — list/view
- `PUT /meetings/<id>/note` — user-edited markdown с 409 conflict detection
- `POST /meetings/<id>/retry` — idempotent retry на failed pipeline

**Privacy invariant:** raw audio удаляется на бэкенде сразу после транскрипции. Transcript + markdown хранятся навсегда. Always-on detector работает только на metadata (mic boolean + system-audio VAD через CoreAudio process-tap) — не записываем content до accept'а.

Подробности — [docs/archive/specs/meetings.md](archive/specs/meetings.md), план реализации — [docs/archive/plans/meetings.md](archive/plans/meetings.md).

---

## Что отложено / не делаем

- **Hover UI** — не приоритет M1. UX живёт в хоткеях, выделениях, последних вставках. Settings — потом.
- **Transcription history "архив всего"** — заменяется Voice Clipboard (последние 20-50, инструмент восстановления и повтора).
- **Серверный agent / managed-коннекторы / серверная память** — выпилены пивотом. «Мозг» = локальный CLI пользователя (Connect Claude / Codex); инструменты и память — на его стороне.
- **Windows версия** — пока только stub-каркас (`windows/`), готового приложения нет. macOS-only до validation.
- **Командное использование** — вырастет из Pro, не отдельный продукт на старте.
- **Полная векторизация Slack/Notion** — не нужна. Артефакты — только при anchor.

---

## Boundaries

### Always
- Хоткей всегда активен
- Наши ключи — только в backend, не в клиенте (BYOK — ключ пользователя в Keychain, direct)
- Pill всегда поверх всех окон, не блокирует ввод
- Скриншоты только активного окна, не весь экран
- ISO-639-1 language hint в STT (улучшает accuracy/latency)

### Never
- Никаких кликов / движений мыши на глазах у пользователя
- Pay-as-you-go для конечных пользователей
- Скриншот без явного триггера или high-context приложения
- Серверный agent / проксирование агента через наш backend (агент = CLI пользователя)
- Хранение audio дольше необходимого (сразу после транскрипции — удаляем)

### Ask
- Конкретная тарифная модель — отдельное исследование
- Backend стек (Cloudflare Workers, Vercel, Fly, custom?)
- Per-recipient style memory — где хранить (локально / облако)?
- Eval suite — какие модельные проверки нужны для p95 latency и correction rate
- Voice Actions on Selection — отдельный хоткей или тот же что и диктовка?

---

## Открытые вопросы

1. **Voice Actions on Selection — хоткей.** Тот же `Right Option+/` (контекст: есть выделение → action mode, нет → dictation), или отдельный?
2. **Backend stack.** Что будем использовать для proxy?
3. **Pricing — конкретные числа.** Нужно market research.
4. **Eval suite.** Какие синтетические и реальные тесты для качества.
5. **Глубина интеграции с CLI-агентом.** Как далеко идём в Connect Claude / Codex (permission-bridge, контекст из экрана), оставаясь вне data/credential-path пользователя.
6. **Streaming vs batch.** Когда переходим на realtime для voice edit preview.

---

## Ближайший шаг

После approval спецификации — план разработки M1 ([writing-plans](docs/plans/) с stages и validation gates).

Самый правильный первый stage M1: **Voice Actions on Selection** + **Edit last insert** + **Voice Clipboard**. Это даст вау быстрее чем любая другая фича.
