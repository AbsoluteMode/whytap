# Whytap — Спецификация продукта

> **Статус 2026-10-18.** Whytap — бесплатный open-source инструмент (MIT),
> только BYOK. Аккаунтов, тарифов и телеметрии нет: STT и LLM работают напрямую
> у провайдера ключом пользователя или на его OpenAI-compatible endpoint;
> локальные модели убраны 2026-10-18
> (`.project-docs/decisions/2026-10-18-remove-local-models.md`). Агент —
> встроенный Whytap Agent с моделью пользователя через OpenRouter, OpenAI или Anthropic.
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

- To-do — компактный локальный список в hover: ввод + Enter, нажатие завершает/возвращает задачу, завершённые уходят вниз до закрытия, затем доступны в History с датой и временем завершения. Длинный текст раскрывается нативной подсказкой при наведении; черновик сохраняется при закрытии. Calendar открывается внутри Hover на текущем дне. Повестка, полные подробности события, выбор видимых календарей и кнопка Connect остаются внутри Hover; повторное открытие возвращает сегодня. Connect и Settings → Integrations сразу запускают общий сценарий подключения Apple, Google, Outlook/Teams и Zoom Calendar Service: без промежуточной формы, имени аккаунта и Advanced setup. Браузер или системный запрос открываются только для разрешения доступа провайдеру; аккаунта Whytap нет. Внешние события доступны для чтения. Публичные Google/Zoom подключения остаются недоступны до проверки; живая авторизация проверяется отдельно. См. [Planner](planner.md).

- macOS 14.2+, Swift + AppKit + SwiftUI; surface — Dynamic Island (status-bar item нет)
- Voice flow: hold Space (удержание пробела в редактируемом поле; Escape — отмена) → запись → realtime STT: «Your key» (Soniox / Deepgram / ElevenLabs / self-hosted OpenAI-compatible, напрямую ключом пользователя из Keychain) → cleanup (OpenRouter ключом пользователя / custom OpenAI-compatible endpoint / без LLM) → Cmd+V
- Agent flow: Right Cmd tap/hold → Whytap Agent → выбранная пользователем модель OpenRouter, OpenAI или Anthropic, рендер в окне
- Meeting Notes: always-on детектор → запись (mic + system audio) → BYOK-процессор (Soniox размечает спикеров, саммари — LLM пользователя) → notes window
- App-aware форматирование (Notion/Linear/Slack/Telegram → markdown, остальное → plain)
- Без аккаунта, без серверов Whytap, без телеметрии
- Sparkle auto-update (download-on-action, pill в Dynamic Island), фид — GitHub Releases
- Bundle `com.rootwise.sidekey`
- Репозиторий: [AbsoluteMode/whytap](https://github.com/AbsoluteMode/whytap)
- Hover: выбранные пользователем инструменты рядами по три, только иконка и название без мелких подписей состояния; у Record во время записи загорается красная иконка, индикатор записи в правом крыле сохраняется. Состояния доступны VoiceOver. Поиск по всему каталогу запускает редкий инструмент (например Output Lang), не добавляя его в постоянные кнопки.
- Display — яркость (hover, из каталога и поиска): белый ползунок подсветки экрана с островом, свитч Extra (постоянный EDR-буст поверх текущей яркости через таблицу дисплея, как у Vivid, только на дисплеях с запасом яркости; первое ручное уменьшение ползунком Whytap или перехваченной клавишей яркости только выключает Extra, сохраняя подсветку и положение ползунка на весь жест или удержание; следующее действие уменьшает яркость; внешние изменения macOS, включая автояркость, затемнение на батарее и при бездействии, сохраняют Extra; обычные системные клавиши и регуляторы без перехвата также сохраняют Extra, поскольку чтение уровня не различает ручное и автоматическое действие; изменения отслеживаются раз в полсекунды и при закрытой панели, повышение яркости не включает Extra; выключает также свитч, перегрев, смена дисплея или потеря им EDR, другое приложение, меняющее таблицу дисплея (например Vivid), и выход) без индикатора заряда и оценки времени работы от батареи. Свитчи Extra и Brightness keys есть и в Settings → Toolbox → Display. Brightness keys (по умолчанию выключены): клавиши яркости Mac показывают полоску в острове вместо системного индикатора, два нажатия «ярче» на максимуме включают Extra. Всё локально; сохраняется только переключатель клавиш.

---

Whytap — новое имя Whytap. Bundle ID, Keychain и пути локальных данных
сохранены для совместимости с существующими установками.

Notify: карточки слева от острова, постоянная история с цветом и логотипом
события. Встроенный источник Meeting notes включён по умолчанию для новых и
существующих пользователей: после успешной обработки встречи появляется маленькая
иконка Whytap. Нажатие на уведомление или запись в истории открывает именно эту
встречу. Settings → Notifications позволяет отключить источник или выбрать Large;
выбор сохраняется после перезапуска. Ошибка обработки не вызывает уведомление
о готовности, старые уведомления при запуске не повторяются.
Пользовательский агент настраивает локальные скрипты-источники; Whytap
запускает их на время работы приложения. Settings → Notifications показывает
подключённые источники и позволяет отключать и включать каждый отдельно,
сохраняя настройку и историю. Меню выбора во всём приложении используют компактную
кнопку с одной стрелкой вниз; в Notifications меню и выключатель выровнены по
центру строки, подпись Notification type перенесена в соседний вопросик с
подсказкой при наведении и пояснением по нажатию. Large — карточка слева;
Small — иконка без текста поверх всего правого крыла (хинты, встречи, музыка).
Маленькая иконка слегка потряхивается и исчезает через 5 секунд по умолчанию;
наведение приостанавливает таймер, увеличивает иконку и показывает крестик рядом.
Нажатие открывает ссылку события, крестик закрывает его; история сохраняется.
Серия Small собирается в стопку со счётчиком: до трёх иконок видны, при наведении
они слегка разъезжаются, каждая открывает свою ссылку. Новое событие начинает
таймер стопки заново; по истечении времени исчезает вся стопка. Large сохраняет
порядок очереди и разделяет серии. История хранит 500 последних событий.
На Notify в hover и поиске горит красная точка до открытия истории; она сохраняется
после исчезновения иконок и перезапуска. Monitor не подсвечивается. Clear All
показывается без иконки и сразу очищает историю и текущие уведомления без
подтверждения; источники остаются подключены.
При Reduce Motion нет тряски и увеличения. [Контракт](customization/notifications.md).

## Case для ИИ

Case — зашифрованное хранилище ключей по проектам (General + свои) с Touch ID.
Зарегистрированные ИИ-приложения (Claude Code, Codex, Cursor, встроенный агент)
видят только имена проектов и ключей и описания; `whytap case run` запускает
команду, передавая значения только в её окружении, а вывод маскируется. Режимы
Accept (запрос под островом: Y — разрешить, N/Escape — отклонить, A — временный Bypass)
и Bypass на приложение и проект. Только поле минут принимает одни цифры: буквы
и смешанная вставка отклоняются до появления в поле. При вводе минут клавиши
ответа отключены; при появлении запроса число не выделяется автоматически.
Доступ можно ограничить выбранными проектами или разрешить все текущие и новые.
В запросе Accept временный Bypass — отдельная кнопка рядом с полем числа минут
(1–240, по умолчанию 15), без стрелок. Внизу только «Deny» и «Allow».
Наведение на команду показывает её полностью; ввод минут временно отключает
клавиши ответа. Агент может напрямую искать нужный ключ через `case_list_keys(query:)`
по имени, описанию и проекту, затем использовать существующий `case run --only KEY`. Значения
не попадают в аргументы, MCP-ответы, конфиги и логи. Защита — от случайных утечек
в переписку, а не от ИИ, который нарочно достаёт значение.
Решение: [decisions/2026-10-19-case-secrets-broker.md](decisions/2026-10-19-case-secrets-broker.md).

Case открывается в панели высотой 320 pt. Подключённые приложения показаны
иконками без лампочки и подписей; клик открывает права именно этого приложения.
Постоянная кнопка Connect предлагает встроенный Whytap Agent, найденные на Mac Claude Code
и Cursor с логотипами, без Codex и без выбора произвольной программы. Затем открываются два блока:
режим Accept/Bypass с пояснениями внутри вариантов и область проектов.
Сохранение подключает агента через Touch ID, обозначенный на кнопке; подробности
доступны в её подсказке. Ранее сохранённые подключения других агентов остаются. При наведении и фокусе логотип Codex
подсвечивается синим, Claude — оранжевым, Cursor — белым свечением.
Поиск ищет имена и описания проектов и ключей, включая пустые проекты и General.
Совпадение проекта показывает все его ключи, совпадение ключа — только найденные
ключи. Добавление — отдельной формой через «+ Key in <проект>», в том числе
найденном через поиск; Enter в поиске ключ не создаёт. Кнопка назад белая,
пояснение режимов короткое. Интеграции с Doppler в Case нет.

Вложенные меню островка остаются открытыми при уходе курсора. Выход — назад,
кликом снаружи или Escape. Во время Touch ID и работы с нативным меню или
выбором файла случайное закрытие приостановлено. Основная сетка инструментов
по-прежнему закрывается при уходе курсора; краткий показ яркости по аппаратной
клавише сохраняет таймер. Системные приоритеты островка сохраняются.

## Integrations

Settings → Integrations содержит отдельные подключения Google Calendar,
Outlook Calendar, Apple Calendar и Zoom Calendar с описанием прав именно этой
функции. Google и Zoom показывают статус незавершённой проверки/публикации;
новый вход через общую регистрацию Whytap доступен после одобрения провайдера.
Connect сразу открывает вход провайдера или системный запрос, без отдельной формы настройки. Уже подключённые аккаунты можно отключить. Вход сериализован между Settings и
Hover; пока он идёт, восстановление копии и перезапуск для обновления отложены.

Settings → Integrations: подключение GitHub через существующий CLI login или
access token; проверка приватного Exodia-Backup. Само подключение не отправляет
пользовательские данные.

## Backup

Settings → Backup показывает короткий статус синхронизации,
ссылку на копии в GitHub Releases и основные действия; если подключения нет, ведёт в Integrations.
Короткое пояснение описывает восстановление ключей, паролей и настроек,
локальное шифрование и хранение в приватном репозитории: GitHub не может читать секреты.

**Back up** сохраняет все поддерживаемые данные и ключи, шифрует их, проверяет
загрузку и выдаёт код. **Restore backup** принимает код и готовит полное
восстановление последней завершённой копии, подходящей к этому коду, по времени
сохранения данных. Новый Mac сначала восстанавливает уже существующий бэкап.
Нет выбора разделов, настроек,
обратной вставки кода и подтверждений. Применение — после обычного перезапуска,
с сохранением предыдущих данных. Восстановленные jobs и подключения остаются
на паузе до явного включения. Созданный GitHub-бекап автоматически синхронизируется
после изменений, включая ранее созданные копии. Проверка — раз в минуту,
сверка хешей согласованного снимка — минимум раз в час при запущенном
и свободном приложении, даже без изменений метаданных. Совпавший хеш не
создаёт копию. Изменения сначала сохраняются локально в зашифрованном виде;
попытки — не чаще раза в две минуты и при отсутствии активной работы.
«Backup synced» означает проверенную загрузку без обнаруженных изменений
или ожидающих копий и показанный пользователю recovery-код; ожидание, загрузка,
пауза и ошибка показаны отдельно. Пока первый код не был показан, остаётся
«Save your recovery code»; повторный показ требует пароль Mac или Touch ID.
При сбое сети свежий локальный снимок заменяет устаревший неотправленный
автоматический снимок; начатая отправка и проверенные копии сохраняются.
Сеть не блокирует сохранение новых артефактов. Журнал Costs входит в бэкап;
восстановление сохраняет уникальные расходы этого Mac без дублей запросов
и ухудшения известных цен. Старые архивы без Costs не меняют этот журнал. Помеченные `CACHEDIR.TAG` кеши зависимостей
исключены; скрипты и рабочие данные вне них сохраняются.
Существующие папки назначения и локальная история сохраняются внутри механизма. [Инструкция](backup.md).

## Roadmap

Далее сохранён исторический roadmap. Упоминания Whytap, старых CLI и облачной
архитектуры описывают прежние решения; актуальный агент описан в
[README](../README.md). Раздел Projects и подстановка проектных знаний
[удалены](../.project-docs/decisions/2026-10-19-remove-projects.md).

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
| **Tool hotkeys** | Settings → Hotkeys binds named catalog functions, including unpinned tools. Reordering tiles preserves bindings; users can record or remove each optional shortcut. Saved legacy position shortcuts migrate once. |
| **Customizable hotkeys** | Пользователь может переназначить любой хоткей: диктовка, edit, ask mode. Дефолт `Right Option + /`, `Right Option + .` и т.п. |
| Screenshot gating | Скриншот не всегда — только когда есть deictic words ("вот это", "там"), high-context app или low confidence по терминам |
| Native macOS distribution | Открытые исходники и готовые community-сборки без Apple Developer. Обновления через Sparkle с нашей Ed25519-подписью; перезапуск откладывается при активной записи, диктовке или работе агента. Кастомные source-сборки обновляются отдельно. |
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

**Режим Drop фиксируется в начале записи.** Fast вставляет транскрипт с
фильтром слов-паразитов и не обращается к AI-обработке текста. Smart делает один
запрос выбранной модели текста: она возвращает исправленное сообщение либо
служебный ответ «без изменений», если существенной пользы от правок нет.
В последнем случае вставляется сохранённый транскрипт без интерпретации Markdown;
служебный ответ во вставку не попадает. Замена синонимов, порядок слов и мелкая
стилистика сами по себе не требуют редактуры. Настоящие ошибки и структура
длинного сообщения по-прежнему исправляются. Отдельная модель Jev/Decision и её
строка в настройках удалены. Выбранная модель текста, её провайдер и ключи
сохраняются; режим записи и STT-провайдер остаются Smart. Выбранный язык перевода
всегда требует полного текста на нужном языке. Если обработка недоступна, завершилась ошибкой или
вернула пустой текст, островок показывает ошибку Smart и Retry; сырой текст
автоматически не вставляется. Транскрипт остаётся в памяти до успешного Retry,
новой записи или выхода. Retry сохраняет исходные режим и приложение-цель;
смена режима относится к следующей записи. Правило действует и для batch
recovery, и для восстановления по частичному транскрипту.

Редактор Smart делает минимальные полезные исправления, убирает явные запинки
и случайные дубли, сохраняя исходные формулировки, порядок мыслей,
самостоятельные факты, причины, условия, запреты, адресатов и степень
уверенности. Предложение не становится решением, вложенная просьба написать
кому-то остаётся просьбой. При самопоправке заменяется только исправляемая
часть. Длинные сообщения разделяются пустыми строками на смысловые абзацы;
три и более параллельных требования можно оформить простым списком.
Краткость не имеет заданного процента: если сокращение теряет смысловую
деталь, она сохраняется. Настроенный выходной язык действует и для такой
редактуры. Промпт проверен под GPT-6 Sol, выбор модели остаётся в API & Models.

Smart выбирает правила оформления по распознанному приложению и полю ввода:
CommonMark для Markdown-редакторов и AI-композеров, варианты GitHub/GitLab
для распознанных веб-композеров и Markdown Discord. В IDE разметка включается
только для Markdown-документа; неизвестные приложения, поисковые и однострочные
поля остаются обычным текстом. Для Slack и Telegram разметка преобразуется
локально в форматированный текст буфера обмена с обычным текстовым fallback.
Точные пути, URL и код защищены от локального удаления слов-паразитов.
Распознавание приложения само по себе не запускает дополнительную редактуру;
Fast и успешный пропуск редактора через Decision сохраняются. Подробности и
границы поддержки: [правила назначения](../.project-docs/decisions/2026-10-21-smart-destination-formatting.md).

Окно Settings автоматически следует светлой и тёмной теме macOS, включая смену
темы при открытом окне. Связанные настройки собраны в группы в стиле iOS;
переключатели со стеклянным бегунком поддерживают нажатие, перетаскивание и
клавиатуру, учитывают Reduce Motion и Reduce Transparency. Решения: [DESIGN.md](DESIGN.md).

**Настройки API & Models (Settings → API & Models):** четыре внутренних раздела
API keys, Models, Costs и API hints в одной панели. При открытии выбран Models.
Функции визуально разделены. Ненастроенная функция отмечена оранжевым контуром
с мягким статичным свечением вместо `Not set` и предупреждающего значка;
конкретные ошибки и действия для их исправления остаются текстом.
*API keys* — прямоугольные чипы провайдеров без цветных индикаторов (статус
ключа — «Key works», «Limited key», «Key not accepted» и т. п. — во всплывающем
окне чипа) и «Add key»: Soniox, Deepgram, ElevenLabs, OpenRouter,
Anthropic и OpenAI (для LLM) и свои OpenAI-compatible серверы. Ключи
лежат в Keychain, на экран не возвращаются; проверка ключа — бесплатный запрос
к провайдеру. *Models* — компактная строка одинаковой высоты на функцию: название,
краткая сводка выбранных моделей и стрелка раскрытия. Нажатие открывает настройки
прямо под строкой; одновременно раскрыта одна функция. Внутри — меню
«Provider · model-id» на каждый маршрут и Speech/Text у парных маршрутов.
The model picker opens a searchable popover: all query terms match in any
order across model ID/provider, ignoring case and separators (`qwen 27` and
`qwen27` find `qwen/qwen3.8-27b`). Up/Down and Return select; Escape clears then
closes. Opening the picker automatically refreshes stale or failed catalogs;
cached results remain available offline. There are no Refresh models or Other
model ID actions. Search and refresh keep the current route until an explicit
verified pick. API keys shows all providers as square tiles; clicking a tile
opens its inline form with only Save and Remove. Validation stays automatic;
the only result message is a brief Key accepted / Key not accepted notice. Failed or unreachable checks preserve the
previous key and keep the form open. OpenAI and Anthropic are available to all
LLM routes with their own provider keys.
Model results show the provider's date when known: Anthropic `Released`, OpenAI
`Created`, OpenRouter `Added to OpenRouter`, Deepgram `Updated` (newest model
version). Soniox and ElevenLabs show `Released` for exact stable IDs with
verified official launch dates in the built-in registry; unknown IDs/aliases
inherit no date. Unknown or invalid dates have no
placeholder. Nonempty search orders equal-relevance matches by newest date,
unknown dates last, preserving provider groups and stable ties. Empty search
keeps catalog order.
Подписей real-time, recorded и LLM with tools в списке нет. Функции: Drop Fast,
Drop Smart (распознавание + Decision + очистка текста), Meetings (расшифровка + заметки),
Agent, Agent voice, Voice search, Translation и Subtitles (Speech + отдельная LLM). Ошибки и
действия для их исправления видны и в свёрнутом состоянии. Над карточкой — тихая пометка «N features have no model ·
Show»: Show раскрывает первую нужную функцию, прокручивает к ней и на пару секунд
подсвечивает нужные строки. Переходы из ошибок функций тоже раскрывают нужную
группу. В меню модели — только ID модели (короткая
пометка вроде «with speakers» в той же строке); неподходящие модели не
показываются. У Deepgram в меню только модели, обновлённые за последние 12
месяцев (дата — по самой новой `version` в каталоге), плюс вшитые и выбранная;
каталог при этом полный, маршрут на старой модели работает. У строки на OpenRouter есть второе меню — провайдер: Auto
(выбирает OpenRouter, для диктовки — по скорости) или один провайдер модели,
закреплённый без подмены (`provider.order` + `allow_fallbacks: false`, так же
для агента в конфиге OpenCode). У каждого провайдера — медианная задержка до
первого токена и скорость (ток/с) за 30 минут из
`GET /models/{id}/endpoints` с ключом OpenRouter; без цифр — прочерк. Новая
модель начинается с Auto. Модель каждой фичи читается при каждом вызове;
Whytap сам не меняет ни модель, ни провайдера. Статус показывается в строке
только при проблеме (Not verified, Deprecated alias, Removed by provider, Not
supported yet, Key problem, Not set). Каталоги моделей подтягиваются у
провайдера и кэшируются на сутки; новая модель вне вшитого реестра проходит
синтетическую пробу при выборе и по Check now. Первый запуск новой сборки
переносит прежние выборы в маршруты фич и не трогает старые ключи
UserDefaults. Спека — [docs/specs/api-and-models.md](specs/api-and-models.md),
решение —
[2026-10-19-api-and-models](../.project-docs/decisions/2026-10-19-api-and-models.md).

**Costs:** период выбирается рядом с заголовком: сегодня, последние семь дней,
текущий месяц или свои даты включительно. В таблице — только использованные
функции за этот период и итог. Наведение, нажатие или фокус клавиатуры на функции
показывает модели, фактически использованные в этом периоде, и их расходы.
Один столбец Price показывает сумму с единицей: доллары или credits; если были
оба вида расхода, в ячейке и Total остаются две суммы. Каждый вход в Costs
начинается с This month. Даты From/To открывают календарь и используют тот же
нейтральный фон, что и период; после выбора даты календарь закрывается, выделенного
сегмента текста не остаётся. Месяц выбирается отдельным меню, год — списком
или вводом числа; просмотр месяца/года не меняет период до выбора дня. Будущие
дни недоступны, Today выбирает сегодня, Done/Escape закрывают календарь.
Фокус виден на отдельных элементах вместо рамки вокруг всей сетки. Нижняя постоянная подпись убрана; пояснения к
оценке и неизвестным расходам доступны в подробностях/подсказке.
Доллары и кредиты ElevenLabs не складываются; бесплатные и купленные кредиты не
пересчитываются в доллары. Данные о стоимости из ответа провайдера показываются как списание;
Soniox запрашивает точную цену через usage logs по ID конкретного запроса и модели.
Пока цена не появилась или API недоступен, остаётся почасовая оценка с ≈.
Точная цена заменяет оценку в той же записи без повторного списания; старые
запросы без ID остаются оценочными. Для ElevenLabs расход фичи считается как
записанные аудиоминуты × сохранённая ставка конкретной модели в кредитах/минуту
и помечается ≈. Ставка берётся из успешной статистики кредитов/минут, сохраняется
локально и остаётся доступной при сбоях API; для новой модели без ставки число
не выдумывается. Записанные оценки не пересчитываются при обновлении ставки.
Подробности модели различают отсутствие длительности аудио и отсутствие ставки.
Попытки без записанной длительности остаются с неизвестной стоимостью; для них
не запрашивается ставка, которая всё равно не позволит вычислить расход.
Отдельного блока общих списаний ElevenLabs нет. Расчёт OpenCode помечен ≈.
Refresh повторяет чтение цен; при ошибке API известные оценки остаются видны.
Частичный итог отмечен +, подробности объясняют пропуск. История начинается
с обновления; синтетические проверки моделей в неё не входят. Журнал локальный,
без ключей, текстов, аудио или ответов. Решение —
[2026-10-20-feature-costs](../.project-docs/decisions/2026-10-20-feature-costs.md).

**STT-провайдеры (Your key, выбор пользователя в Settings → API & Models для
каждой фичи):** Soniox (`stt-rt-v5`, по умолчанию), Deepgram (`nova-3`),
ElevenLabs (`scribe_v2_realtime`) или self-hosted endpoint с протоколом OpenAI
Realtime (модель вводит пользователь, по умолчанию `gpt-4o-transcribe`). Сам
OpenAI не предлагается: сохранённый выбор OpenAI читается как Soniox. Drop —
realtime streaming, не batch; заметки встреч с Soniox идут через file API
(`stt-async-v5`).

**Input language** — отдельный от Smart Output language выбор. Явный язык
передаётся STT-провайдеру: Soniox получает мягкие hints с добавлением английского,
Deepgram — `language`, ElevenLabs — `language_code`, self-hosted — поле
`language` совместимого протокола. Deepgram Auto использует `language=multi`:
для `nova-3` это английский, испанский, французский, немецкий, хинди, русский,
португальский, японский, итальянский и нидерландский. Остальные поддерживаемые
языки выбираются явно. Язык ввода общий для всех голосовых фич и выбирается в
островке и в настройках митингов; строка Deepgram в Settings → API & Models
показывает предупреждение, если её модель не подходит к текущему языку.
Неподдерживаемый язык известной Nova-модели и Auto неизвестной сохранённой
модели останавливаются до передачи аудио; Drop открывает API & Models на
строке своей фичи. Сохранённые язык, модель и провайдер сами не меняются.
Realtime и batch используют одну
[политику языков Deepgram](../.project-docs/decisions/2026-10-19-deepgram-language-policy.md).

**Local STT** (FluidAudio Parakeet TDT v3) убран 2026-10-18 вместе с MLX
Qwen и локальной диаризацией. Сохранённый выбор Local не переключается на
провайдера сам: Drop открывает Settings → API & Models, пока пользователь не
выберет провайдера.

**Batch-распознавание** — только запасной путь: деградировавший поток, Retry
после «Couldn't deliver», fallback рекордера и batch-голос агента. Весь take
уходит провайдеру той фичи, что вела Drop (Fast или Smart; для голоса агента —
Agent voice), с его ключом из Keychain и recorded-моделью из вшитого реестра:
Soniox file API (`stt-async-v5`), Deepgram pre-recorded, ElevenLabs
speech-to-text (`scribe_v2`), self-hosted `/v1/audio/transcriptions` на хосте
своего сервера. Без маршрута фичи, ключа или recorded-модели batch недоступен;
другой провайдер не подставляется.

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

> Доступ к Slack/Notion/GitHub и т.п. живёт на стороне CLI пользователя
> (его MCP-серверы), не у нас — мы scopes и индексацию не держим.

---

## Meeting Notes

The Meetings entry opens an overview with the five newest meetings and History.
History retains the complete date-grouped list. Opening a note preserves its
origin for Back; choosing Meetings again or following a direct note link uses
the overview. Both lists retain processing states and confirmed deletion.
Load failures offer Retry without discarding the last loaded list. The overview
can grow with future Meeting Assistant sections; no preset controls ship yet.

**Current continuation behavior (2026-10-20):** Each completed call starts BYOK
processing immediately. After auto-end, Reconnect is available for three minutes;
Notes / Reconnect / Skip and the 20-second decision timeout remain. Reconnect
records a separate part and, when it ends, supplements the same meeting under
Updating… while keeping the earlier note readable. Only new audio is processed;
new summary findings and a transcript boundary are appended. Manual Stop is
final, and neither Skip nor timeout starts recording. Recovery is idempotent,
manual edits are preserved, and speaker labels remain scoped to each part.
Open notes and transcripts refresh automatically in both Notes surfaces. Active
drafts defer that refresh until Cancel or successful persistence after Done;
merely submitting a debounced save does not reload older stored text.
See [the continuation decision](../.project-docs/decisions/2026-10-20-meeting-continuations.md).
The backend design below is historical; current processing uses the user's BYOK
routes and the native notes viewer.

**Live-assistant test preparation (2026-10-19):** Internal opt-in capture uses
the local `sidekey.meetings.liveTestCapture` flag when Meeting Notes uses Soniox.
The user requested no test-mode controls or test-files row in Settings.
It adds a separate live diarization stream, stores private source tracks and
timing locally, and preserves ordinary notes processing. Since 2026-10-22 only
source dev builds (9999 / `-dev`) capture; packaged builds ignore the flag and
remove earlier captures at launch. No automatic
suggestions are enabled. Real-call source attribution and latency remain
acceptance tests. See [testing instructions](meeting-assistant-testing.md).

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

## Toolbox

Область выбранных инструментов закреплена над каталогом. Выбранные плитки
прокручиваются по горизонтали; Add и Settings всегда видны. Add принимает
перетаскивание и по клику предлагает выбор. Уже добавленные инструменты доступны
для выбора и перетаскивания; добавить или убрать инструмент можно из его панели
и контекстного меню. Каталог и содержимое инструментов прокручиваются отдельно.
Встроенные панели: Translate, Subtitles, History, Monitor, Record и существующие
редакторы. Остальные инструменты показывают явную кнопку действия. Выбор плитки
не запускает запись и не выполняет действие автоматически.

## Переводчик и субтитры

Translate и Subtitles доступны через поиск инструментов и каталог Toolbox;
у каждого настраивается именованная горячая клавиша. В Toolbox работают прямо
в правой панели; из острова открывают общее плавающее окно: текстовый перевод с автонаправлением RU↔EN или явным языком и перевод
системного звука в субтитры с оригиналом. Текстовый режим — две компактные строки:
ввод и результат, запуск по Enter, закрытие по Escape. Язык и вторичные действия
доступны в контекстном меню; сохранённый язык не меняется.
Translation использует свою LLM;
Subtitles объединяет выбор Speech (`subtitlesAudio`) и собственной LLM
(`subtitlesTranslation`). Новые маршруты изначально Not set. При обновлении
настроенных субтитров прежний общий LLM копируется один раз; дальше модели
выбираются независимо и не подменяют друг друга.
Очереди ограничены; отставание останавливает захват с ошибкой. Закрытие окна,
Cancel и сон завершают захват и запросы; Stop ждёт финальные фразы. Записи и
автоматической истории нет. Подробности и ограничения: [translation.md](translation.md).


## Скриншоты

Screenshot через поиск инструментов/Toolbox открывает захват области. Двойной
клик больше не выбирает дисплей целиком: сохраняется только явно выделенная
область. Enter без выделения ничего не копирует, верхняя строка инструкций
удалена. Видимый Hover Whytap сохраняется до фиксации пикселей и входит в кадр;
перед захватом островок не закрывается и не пробуждается. Основная панель сразу показывает все инструменты и
команды без «…»: стрелка, фигура, перо, текст, Blur, нумерация,
Copy text, отправка, отмена/повтор, Download,
Copy & exit ↩ и закрытие. Цвет, толщина и другие параметры выбранного инструмента
вынесены в отдельную соседнюю панель; на узком дисплее основная панель переносит
кнопки на дополнительные ряды. Blur по умолчанию скрывает **текст и числа**,
включая отдельные цифры, локальным Vision; есть режим всей области.
Результат остаётся видимым для проверки. Провайдеры/ключи не нужны;
автоматического сохранения и загрузки нет. Подробнее: [screenshots.md](screenshots.md).
Copy & exit и Enter копируют и закрывают редактор; ⌘Z/⇧⌘Z отменяют/повторяют
правки снимка, а внутри текстового поля сохраняется обычная отмена ввода.
Download сохраняет PNG прямо в «Загрузки», показывает фактическое имя и не
перезаписывает файлы. Захват сохраняет полное разрешение Retina; уменьшение
при экспорте не применяется. Отдельный Select/crop, Highlighter, Spotlight,
Pin above windows и Output size удалены; первичное выделение области
остаётся перетаскиванием. Повторный хоткей
открытия сохраняет текущий редактор; уведомление без изменения конфигурации
дисплеев его не закрывает.
Copy text распознаёт текст и числа в выбранном отредактированном фрагменте
локальным Vision, копирует обычный текст и закрывает редактор. Blur и
размещённые надписи учитываются; при пустом результате или ошибке редактор
остаётся открытым. Escape отменяет распознавание без позднего копирования.
Действие также можно назначить на стрелку; сохранённые назначения не меняются.

## Управление приложением через агента

Локальный MCP-плагин Whytap читает состояние сборки и активности, маршруты
моделей и меняет ограниченный набор настроек: Drop Fast/Smart, входной и
выходной языки, автоскрытие островка. Каждая запись проверяет ожидаемое
текущее значение и проходит через хранилища приложения; неудачная проверка
модели сохраняет прежний маршрут. Ключи, пользовательский контент, права,
запись и выполнение команд этим интерфейсом не открываются. Подключение
плагина и установка поддерживающей сборки проверяются отдельно. Контракт:
[управление приложением](customization/app-control.md).

Тот же плагин подключает существующий Case MCP: поиск доступных проектов и
имён ключей с описаниями, без значений. Использование ключа остаётся через
`whytap case run` в терминале агента. Подключение плагина не меняет регистрацию
агента, доступные проекты и подтверждения Case.

## Ссылки whytap://

`whytap://tool/<id>` и `whytap://settings/<id>` открывают место функции в
приложении — например, из ответа на вопрос о Whytap. `<id>` — сохранённый
идентификатор плитки (`HoverTool`) или вкладки настроек (`SettingsWindowTab`).
Ссылка только показывает: инлайн-плитки открываются в острове, вкладки и
плитки-переходы — в настройках с подсветкой. To-do открывает компактную панель
островка; Calendar открывает текущий день в Hover, окна Translate/Subtitles открываются без запуска. Drop Mode,
Record и Screenshot открывают свою панель в Settings -> Toolbox с явной кнопкой;
Case открывает Toolbox без запроса Touch ID; Quit только подсвечивает строку
Quit. Незнакомый id (ссылка на функцию из более новой версии) лишь показывает
остров; чужие схемы, лишние сегменты и `..` игнорируются.

`whytap://hotkey/<id плитки>?keys=option+shift+s` предлагает назначить хоткей
плитке. Whytap спрашивает в своём окне («Cancel» по умолчанию, «Assign»
включается через секунду) и меняет хоткей только после клика. Комбинация
обязана содержать ⌃ или ⌥; Quit по ссылке не назначается; занятая комбинация
показывает, кому она принадлежит, и ничего не меняет. Ссылки никогда не читают
данные и не меняют, куда они уходят.

### Native agent and Tavily (2026-10-22)

Встроенный агент вызывает модель напрямую, без запуска OpenCode и MCP bootstrap.
Рабочая папка — `Application Support/whytap/agent`, отдельно от исходников.
AGENTS.md хранит память; контекст ограничен шестью парами / 12 000 символами и
15 минутами. В нём сохраняются текст ответа и названия/адреса возвращённых
карточек для уточнений про прежние цены, страницы и файлы. Текст рядом с
карточкой сохраняется при пустом завершающем сообщении модели; непустой
финальный ответ имеет приоритет. История хранит текст вместе с карточками.
Слишком длинный последний обмен сокращается с сохранением начала и конца
вопроса и ответа, чтобы следующий вопрос получал хотя бы этот контекст.
Продолжения с инструментами сохраняют идентификаторы и подписанные блоки
рассуждений, а аргументы передают строкой JSON. Известные категории ошибок
провайдера показываются безопасным текстом без сырых ответов сервиса;
автоматических повторов и смены выбранного провайдера нет.
Скриншоты и сырые результаты инструментов в новый файл диалога не пишутся.
Settings → API & Models → API keys содержит ключ Tavily в Keychain и проверку /usage
без платного поиска. Поиск отправляет только запрос и возвращает до пяти результатов.
Существующее разрешение редактирования/команд сохраняется; approve и bypass —
следующий этап. См. [решение](../.project-docs/decisions/2026-10-22-native-agent.md).


### Meeting Assistant Beta

A configured assistant exposes a hover magic icon to the right of the recording
timer, translucent when off and softly glowing while listening. Listening starts
off for every meeting, including after relaunch or wake. Configuring both model
routes and a ready Space only makes the feature available. A wand click explicitly
enables listening for this meeting; stopping, ending a meeting or changing Space
never enables it again. The panel and API & Models group mark the feature Beta.
A recognized meeting-context end sustained for 15 seconds stops listening;
manual sessions without recognized context need the wand to stop. Context detection
is a mic-activity heuristic, not a unique call identity.

The approved native right-hand module offers a ready Space picker, plain input,
up to five current questions, twenty answered roots and six removable screenshot
attachments. Replies contain a conclusion, structured points and two follow-ups;
conversation survives collapse. Closing answers does not stop listening. The
module shows connection status instead of a Listen button. Explicitly enabled listening extracts questions
from bounded system-audio transcription without retaining audio or starting Notes.
Speech and answer models have separate initially unset routes in API & Models.
Coding agents prepare Spaces; the user selects them. Runtime repository access
is read-only and constrained to declared scopes. Database adapters are not yet
connected. See [pilot usage and Space contract](meeting-assistant.md).
