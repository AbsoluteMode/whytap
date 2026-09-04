# Sparkle: download-on-action вместо silent pre-download

## Контекст

Прод-баг: пользователям предлагали обновиться до **1.9.1**, когда актуальна
**1.9.3**. Причина — `automaticallyDownloadsUpdates = true`: Sparkle тихо
скачивал версию и держал её как «готовую к установке»; если пользователь не
перезапускал приложение, более свежие релизы **не перекачивались** — Sparkle
залипал на скачанной старой. Появлялась цепочка «поставь 1.9.1 → рестарт →
качает 1.9.2 → …». У Sparkle **нет публичного API** отбросить скачанный pending
и взять последний (`checkForUpdatesInBackground` не перебивает скачанное;
`checkForUpdates` показывает install *именно* скачанной; `resetUpdateCycle` лишь
перепланирует таймер).

## Решение

**Download-on-action** через кастомный `SPUUserDriver` (`IslandUpdateUserDriver`),
весь UI — в Dynamic Island, без окон Sparkle:

- `automaticallyDownloadsUpdates = FALSE` — заранее ничего не качаем.
- Scheduled-проверка (ежечасно + прод-beacon при релизе) находит апдейт →
  Sparkle вызывает `showUpdateFound` (driver держит install-`reply`, **не**
  качает) + `didFindValidUpdate` → pill **«Update»** (слово, не версия).
- Клик ↓ → `PendingUpdate.startDownload` → `UpdateController.downloadAction` →
  `driver.invokeDownload()` → `reply(.install)` → Sparkle качает → island-прогресс
  → `.readyToInstall` → Restart → install.

## Почему

1. **Не качать заранее = застревание исключено в корне.** Нет скачанного
   pending → нечему залипать. Каждая scheduled-проверка/beacon заменяет и pill, и
   удерживаемый `reply` на самую свежую версию.
2. **`invokeDownload()` (held reply), а НЕ повторный `checkForUpdates()`.**
   С `automaticallyDownloadsUpdates = false` scheduled-проверка уже вызвала
   `showUpdateFound` и ЖДЁТ `reply`; download стартует только дёрнув
   `reply(.install)`. Повторный `checkForUpdates()` в этот момент — no-op
   (`sessionInProgress`). Поэтому «спросить latest в момент клика» реализуется
   как «дёрнуть удержанный reply от последней scheduled-проверки»: предлагаемая
   версия актуальна на момент последней проверки (≤1ч + beacon-триггер при
   релизе), а не re-fetch ровно в клик. Это убирает исходный баг (дни застревания
   → ≤1ч), оставаясь в рамках Sparkle-модели.
3. **Кастомный `SPUUserDriver`, а не gentle-reminders с окном Sparkle.** Максим
   хотел остров-native опыт без modal/окон. Кастомный driver переводит все 16
   required-коллбэков в примитивный `DriverStage`, который `UpdateController`
   маршрутит в `PendingUpdate.Stage` — driver не знает про UI/AppState (testable).

## Что протестировали

- **Re-read appcast на клик (`checkForUpdates()` в download-closure)** — отвергли:
  no-op при `sessionInProgress` (scheduled `showUpdateFound` уже держит reply); не
  запускает download. Заменили на `invokeDownload()` (PR-ревью выявило, что иначе
  клик не качает — `invokeDownload` оставался бы dead).
- **v1 gentle-reminders «как есть» (клик → `checkForUpdates()` → стандартное окно
  Sparkle)** — отвергли: Максим выбрал v2 (остров, без окон).
- TDD: 45 тестов — driver-коллбэки (10), UpdateController discovery/download/stage
  (17), pill `.available`/affordances (18) + priority-gate hover.

## Отвергли

- **Форс-перекачка последней при обнаружении новее pending** — у Sparkle нет API
  отбросить скачанное; зависело бы от чистки internal-кеша.
- **Проактивная авто-установка при wake/idle** — меняет UX (авто-перезапуск без
  спроса), и всё равно отстаёт при нескольких релизах подряд.
- **Отдельный backend endpoint `/api/latest-version`** — appcast
  (`updates.whytap.ai`) уже источник истины; вторая точка правды не нужна.

---
2026-06-17 · ветка `fix/update-download-on-action` · спека
`docs/superpowers/specs/2026-06-17-update-download-on-action-design.md`
