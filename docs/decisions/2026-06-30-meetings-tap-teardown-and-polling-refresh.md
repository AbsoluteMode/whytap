# Meetings: tap teardown на Stop + симметрия refresh для polling-встреч

## Контекст

Инцидент (2026-06-30, прод 1.15.3): пользователь записал встречу. Встреча
записалась корректно (чанки на диске 11:03–11:09, в SQLite, notes пришли
качественные), но наблюдались два симптома:

1. **Notes не появились в окне Notes**, пока пользователь не перезапустил
   приложение. Данные всё время были в локальном store — не всплывали в UI.
2. **Системный чип macOS «ваш системный звук перехватывается whytap» висел**
   после окончания встречи. Наш индикатор записи в Dynamic Island (правое
   крыло) пропадал корректно, но OS-уровневый чип оставался — гас только
   после перезапуска приложения (убийство процесса освобождало tap).

Загрузка чанков была задержана бэкендом (HTTP 503 ~11:19, attempts 8–9),
finalize/notes доехали через polling в 11:21 — то есть встреча прошла
**polling-путём** (backend), не fully-local.

## Решение

- **Симптом 2 (tap/чип) — definitive фикс:** вернуть `await systemSource.stop()`
  в `MeetingRecorder.stop()` (после `micSource.stop()`).
- **Симптом 1 (notes не видны) — defensive фикс + диагностика:** polling-ready
  путь (`startPollingAfterFinalize`) теперь вызывает прямой
  `refreshOpenWindowIfNeeded()` симметрично fully-local пути; в
  `MeetingListModel.apply()` добавлен диагностический `os_log("meeting list
  applied (count:)")`.

## Почему

- **Симптом 2 — регрессия 1.12.6 → 1.15.x.** `systemSource` (shared
  `SystemAudioVADProbe` поверх `CoreAudioSystemAudioSource`) использовался в
  `MeetingRecorder` только для `audioBufferStream()` (старт); строка
  `await systemSource.stop()` потерялась (вероятно при рефакторе
  separate-tracks, +175 строк в recorder). Без неё цепочка
  `recorder.stop() → systemSource.stop() → CoreAudioSystemAudioSource.stop()
  → stopAndDestroy → AudioHardwareDestroyProcessTap` не выполнялась — process
  tap жил до следующей записи (rebuild) или смерти процесса. macOS, видя живой
  tap (TCC `AudioCapture`), держал системный чип перехвата. Это не косметика:
  процесс реально продолжал перехватывать системный звук после встречи
  (приватность). Возврат строки уничтожает tap на Stop → чип гаснет сразу.

- **Симптом 1 — root cause НЕ доказан, фикс defensive.** Цепочка
  `polling-ready → yield(.newMeetingAvailable) → event-consumer →
  refreshOpenWindowIfNeeded → refreshSidebar → model.refresh → store.list →
  apply` по коду целая; consumer подписан один раз (single-consumer
  AsyncStream, без кражи iterator). Найдена реальная **асимметрия**: fully-local
  путь делал `yield` И прямой `refreshSidebar()`, а polling-путь — только
  `yield` (полагался только на consumer). Это единственная структурная
  разница, и именно polling-путём пришла пострадавшая встреча. Точную причину
  («consumer не доставил» vs «refresh-гонка») без device-логов доказать
  нельзя, поэтому: убрали асимметрию (polling тоже refresh’ит напрямую) и
  добавили лог `apply(count:)`, который вместе с `store list returned (count:)`
  даёт end-to-end трассу на следующем повторе.

## Что протестировали / отвергли по ходу диагностики

- **`log show` как источник истины — ОТВЕРГНУТ.** Он молча теряет события
  завершившегося процесса (доказано: после перезапуска приложения он перестал
  отдавать recorder-события 11:27, которые были захвачены в live-логе). Истина
  — on-disk факты (mtime чанков) и live-захваченные логи.
- **Гипотеза «потерянная встреча 10:30 / детектор молчал» — ОТВЕРГНУТА.**
  Была основана на `log show` (показывал тишину Meetings 10:25–11:20). На самом
  деле встреча записалась (чанки на диске). Соответствующий фикс
  (`LaunchReadiness` + early-start детектора вне permission-гейта) **откатан** —
  чинил неподтверждённую проблему.
- **Гипотеза «окно Notes открыто/закрыто» — ОТВЕРГНУТА** (Максим + Codex
  second-opinion). `_meetingsWindowController` не обнуляется; refresh
  перезапрашивает store.
- **Codex second-opinion:** симптомы 1 и 2 независимы (high confidence); для
  симптома 1 предложил гонку в `MeetingListView.refresh()` (cancel vs apply) —
  оценена как реальная, но слабая (последний Task выживает, `sections`
  `@Published`), medium-low.
- **Тесты:** регресс-тест `test_stop_tears_down_both_mic_and_system_audio_sources`
  (RED→GREEN); полный suite 3625 тестов, 0 failures.

## Отвергнутые альтернативы

- `LaunchReadiness` + early-start детектора (Q1) — откатан, root cause не доказан.
- Убрать прямой refresh из fully-local пути (симметрия «вниз») — рискованнее,
  оставили рабочий путь, подтянули polling «вверх».
- Device-тест перед релизом — пропущен по решению Максима («сразу
  пользовательский билд, если повторится — посмотрим потом» по новым логам).

---
Дата: 2026-06-30 · PR: TBD
