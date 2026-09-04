# Spec: NowPlaying sync (DI music wing + attached player strip)

## Что строим
Sidekey читает текущий трек из **Apple Music / Spotify** (через AppleScript) и показывает в Dynamic Island двумя поверхностями:
1. **Правое крыло (компакт)** — пока трек активен, музыка **чисто заменяет AFK-подсказки** в правом банде: мини-обложка + тонкий progress (elapsed/duration) + анимированный waveform (под play-state, без аудио-тапа).
2. **Прикреплённая строка-плеер** — структурная часть острова, рисуется **всегда, пока трек активен** (даже если правый банд занят agent/meeting/update; **не overlay, а реальный ряд**, без ховера): обложка + тайтл с marquee + исполнитель + prev / playpause / next.

## Почему так
- **Источник = AppleScript (Music+Spotify):** `MediaRemote` закрыт на macOS 15.4+ (мёртв для текущей базы), adhoc-подпись ломается на restricted entitlement. AppleScript notarization-safe, прецедент в репо (`FrontmostAppDetector`).
- **Waveform = анимированный:** без TCC AudioCapture и без конфликта с тапом Meeting Notes; влезает в 70pt.
- **Архитектура зеркалит Meeting Notes** (Source → Controller → Coordinator → AppState → UI).

## Scope v1
**In:**
- AppleScript-source: read title/artist/album/artwork/position/duration/playState; команды previous/playpause/next. Активный плеер: тот, что `playing`; tie-break — последний активный.
- **Крыло** (приоритет ровно над AFK-подсказками, под всеми слотами `agent>meeting>update>drop-status>music>hints`): thumbnail (~16–18pt) + progress-капля + анимированный waveform. Чистая замена подсказок.
- **Строка** always-on пока трек активен (играет ИЛИ пауза), **независима от приоритета банда**, рисуется даже когда банд занят: обложка + marquee-тайтл + исполнитель + 3 transport-кнопки. Структурный ряд острова (остров подрастает вниз), не floating.
- Держим на паузе (waveform замирает, кнопка → Play, progress стоит).
- **Settings-тумблер**: новый таб `music` → `SettingsNowPlayingView` (default-on toggle «Show Now Playing in Dynamic Island» + строка о поддерживаемых плеерах + статус/CTA Automation-доступа). Бэкенд — `NowPlayingConfig` (UserDefaults, instance-scoped для тестов).

**Out (v1):**
- MediaRemote / произвольные плееры (браузер/веб-аудио) — только Music+Spotify.
- Реальный аудио-реактивный waveform (системный тап).
- Scrub/seek по progress (только отображение), громкость, like, shuffle/repeat, очередь.
- Любые правки hover-панели — её **не трогаем**, строка туда не идёт.

## Happy path
1. Юзер запускает трек в Music/Spotify.
2. `NowPlayingController` (поллинг ~1s, пока активен плеер) собирает `NowPlayingSnapshot`.
3. Первое чтение → macOS Automation-промпт для приложения; после грантa данные текут.
4. `AppState` публикует snapshot → крыло заменяет подсказки (thumb+progress+wave, если банд не занят слотом выше); строка под островом всегда показывает art+marquee+transport.
5. Клик playpause/next/prev в строке → AppleScript-команда → следующий поллинг отражает новое состояние.
6. Пауза → waveform замирает, кнопка Play, поверхности остаются.
7. Трек кончился / плеер закрыт / нет активного → snapshot очищается (дебаунс) → подсказки возвращаются, строка исчезает, остров в компакт.

## Архитектура
`Sources/Sidekey/NowPlaying/` (параллельно `Meetings/`):
- `NowPlayingSnapshot` — immutable (app, title, artist, album, artwork: NSImage?, elapsed, duration, isPlaying, ts).
- `NowPlayingSource` protocol + `AppleScriptNowPlayingSource` — NSAppleScript read + transport; выбор активного плеера. **Off-main + timeout** (синхронный NSAppleScript нельзя на main — ханг).
- `NowPlayingController` (@MainActor ObservableObject, по образцу `MeetingPillController`) — пауза-aware поллинг, маппинг source→snapshot, push в AppState, методы prev/playPause/next.
- `NowPlayingConfig` — UserDefaults флаг (instance-scoped для тестов).
- `NowPlayingCoordinator` install в `AppDelegate` (рядом с `installMeetingsCoordinator`), strong-owned, weak-mirror на AppState.

UI:
- AppState: `@Published nowPlaying: NowPlayingSnapshot?` + локальный анимированный `musicWaveformLevels` + update/clear (зеркало meetingRecording).
- Крыло: `IslandRightBandPriority.showsMusic = musicActive && !agent && !meetingCountdown && !meetingRecording && !update && !dropModeStatus`, OR в `hasPriorityRightState` (подсказки уступают). Новый `IslandMusicWingView` в ZStack `IslandWrapRow`; проброс через `IslandCompactRow`.
- Строка: `IslandMusicStripView` в `islandStack` **под компактным pill-рядом**, gated только `musicActive` (НЕ `isHoverExpanded`, НЕ приоритет банда). Кликабельность без ховера — **новая безусловная hit-зона `musicStripActive`** в `IslandPanel.acceptsEvent`/`mouseActiveFrames`/`refreshMouseEventRouting` по образцу `agentActive` (НЕ `setHoverBandHeight` — та читается только при ховере). Hover-панель появляется ниже строки, её код не меняем.
- Settings: новый кейс в `SettingsWindowTab` + `SettingsNowPlayingView` в `detailPane` switch.
- Permissions: Automation lazy; `NSAppleEventsUsageDescription` уже есть; denied → лог + CTA в `SettingsNowPlayingView`. Нового TCC-бакета нет.

## Сценарии
- Both Music+Spotify → берём `playing`; оба playing → последний активный; только пауза → paused.
- Нет обложки → плейсхолдер-глиф. Длинный тайтл → marquee; короткий → статика.
- AppleScript error/timeout → как «нет активного», очистка с дебаунсом, без спама промптами.
- Automation denied → нет данных, без краша.
- Feature-flag off → ничего не рисуется, поллинг не стартует.

## Boundaries
- **Always:** только Music+Spotify через AppleScript; анимированный waveform; крыло — чистая замена подсказок (приоритет над ними); строка always-on пока трек активен (вкл. паузу), независима от приоритета банда; тумблер в Settings.
- **Never:** MediaRemote/private frameworks; системный аудио-тап для музыки; метаданные трека в prod-логи; seek/scrub в v1; правки hover-панели.
- **Ask (на импле):** точная геометрия строки vs резервирование window-frame при конфликте хит-теста; marquee-константы (дефолт ~30pt/s, end-pause 2s, gap 32pt); ширина/высота строки и thumbnail-размеры под house-style.

## Open questions
Блокеров нет. Визуальные константы — дефолты + проверка глазами на user-гейтах (Stages 2–3).

## Approved
Andrey, 2026-06-14 (this session). Source=AppleScript(Music+Spotify), waveform=animated, strip=always-on independent of hover, keep-on-pause.
