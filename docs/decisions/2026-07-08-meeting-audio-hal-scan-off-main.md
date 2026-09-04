# CoreAudio HAL-сканы митинг-детектора уходят с main thread; надж без 60 Гц таймера

## Контекст

Жалоба: при появлении митинг-наджа (Take notes / Skip) клики по кнопкам лагают
— «встреча детектится, но не даёт нажать на опцию». Ранее похожий симптом
лечили в #341 (мёртвые зоны mouse-routing острова), но надж лагал и после.

Диагностика показала, что hit-testing и доставка кликов ни при чём:

- Стенд с точной копией `MeetingNudgeView` на панели конфигурации
  `MeetingPillPanel` (borderless, nonactivating, never-key, `.screenSaver`):
  SwiftUI `Button` получает синтетический HID-клик с первого раза. Дропа
  клика мостом AppKit→SwiftUI (как было у кнопок `IslandPanel`) здесь нет.
- Корень — фризы main thread, привязанные к старту митинга:
  1. `MeetingContextActiveProbe` каждые 2с выполнял
     `AudioProcessProbe().bundleIDsCurrentlyRecording()` через
     `MainActor.run` — ~50 процессов × 2 синхронных Mach-IPC к coreaudiod.
     Замерено на спокойной системе: 6–25 мс на скан. В момент старта
     митинга coreaudiod занят (Zoom/браузер открывает устройства, Bluetooth
     переключается на HFP) — эти IPC стоят за глобальным локом coreaudiod
     сотни мс и дольше. Ровно в окно жизни наджа main получает
     повторяющиеся стопоры: mouseDown/mouseUp ждут в очереди, hover-спринг
     замирает, клик «не нажимается» (фриз между down и up отменяет Button).
  2. Второй путь того же дефекта: `MeetingDetector.scheduleMicOnlyTrigger`
     поллит `FrontmostAppDetecting.isInMeetingContext()` каждые 2с при
     активном микрофоне — тот же HAL-скан на MainActor детектора.
  3. Сам надж тикал `Timer.publish(every: 1/60)` — пере-évaluation body
     каждые 16 мс всю жизнь наджа; замерено ~6% CPU main (M4) против ~2% у
     редкого тика. Не корень, но лишняя нагрузка ровно там же.

Отдельно подтверждён смежный дефект recording-фазы (не в этом PR): macOS
записала `cpu_resource.diag` по прод-клиенту 1.17.0 — 87% CPU 104с, 77%
сэмплов в layout двух NSHostingView из-за непрерывных SwiftUI-анимаций
(`KeyedAnimatableArray`, `BlobShape` орба). Это класс #430 («постоянные
анимации — только CALayer»), лечится отдельно.

## Решение

1. `AudioProcessProbe` перестал быть `@MainActor` — HAL-вызовы
   потокобезопасны, изоляция была артефактом, из-за которого сканы
   затаскивали на main.
2. `MeetingContextActiveProbe`: скан вызывается прямо в detached
   (utility) poll-таске; для тестов введён injected `scanner`.
3. `FrontmostAppDetecting.isInMeetingContext` стал `async` и уводит скан
   в `Task.detached(priority: .utility)`; для тестов введён injected
   `scan`. На MainActor остаётся только дешёвый матчинг по allow-list'ам.
4. `MeetingNudgeView`: 60 Гц `Timer.publish` заменён одним one-shot
   `.task`-таймаутом до дедлайна — периодической работы в надже больше
   нет вообще (countdown-кольцо и так живёт в right band острова со своим
   10 Гц `TimelineView`).
5. (Второй PR, тот же корень.) `MicCaptureSource`: блокирующая
   engine/HAL-половина (`engine.inputNode`, чтение форматов девайса,
   `installTap`, `engine.start()`/`stop()`/`reset()`) вынесена за seam
   `MicEngineOperating` (прод-реализация `AVAudioEngineMicOperator`) и
   выполняется на выделенной serial-очереди `engineQueue`;
   `@MainActor`-методы `start()`/`stop()` остаются оркестраторами и
   подвисают на await, освобождая main. Это лечит фриз сразу после клика
   Take notes (старт движка при максимально занятом coreaudiod), фриз на
   Stop и фризы route-change-рестарта (Bluetooth-переключения посреди
   звонка). Заодно закрыта гонка stop-во-время-start: `isCaptureRequested`
   выставляется до первого подвеса, обе точки после await его
   перепроверяют — «капчер, стартовавший одновременно со stop», сносится,
   а не живёт брошенным (инвариант в тесте: startCapture == stopCapture).

## Почему

- Клик обрабатывается тем же main runloop, что и layout: любой синхронный
  IPC на main в турбулентный для coreaudiod момент = видимый лаг кнопок.
  Убирание скана с main лечит корень, а не симптом (hit-зоны, hotspot'ы и
  прочий mouse-routing здесь были ни при чём — проверено стендом).
- Периодический 60 Гц тик ради проверки «не истёк ли дедлайн» — чистый
  расход: ничего в надже не рендерит остаток времени.

## Что протестировали

- TDD: два новых теста (`testPollScannerRunsOffMainThread`,
  `testFrontmostMeetingContextScanRunsOffMainThread`) наблюдают поток
  вызова сканера через injected seam. Оба падали до фикса
  (`Optional(true) != Optional(false)` — скан на main) и зелёные после.
- Стенд A/B на копии наджа: 60 Гц Timer ≈ 6% CPU main vs ≈ 1–2% без него.
- HAL-бенч на живой системе: скан 6–25 мс (49 аудио-процессов) в покое —
  подтверждение цены одного тика ещё до митинговой турбулентности.
- Полный `swift test` зелёный.

## Отвергли

- **sendEvent-хотспоты для кнопок наджа** (паттерн IslandPanel) — стенд
  показал, что доставка кликов на этой панели работает; чинить нечего.
- **Ускорение/пауза poll-цикла на время наджа** — прятало бы симптом,
  оставляя фризы у второго пути (детектор) и любых будущих вызывателей.
- **TimelineView 1–10 Гц в надже** — рабочий вариант (проверен стендом),
  но one-shot `.task` ещё проще: нулевая периодика вместо редкой.
- **Уведение `AVAudioEngine.start()` с main в ОДНОМ PR с HAL-сканами** —
  сначала отложили из-за риска аудио-регрессий (цепочка recorder'а
  MainActor-аффинна), сделано отдельным вторым PR тем же днём (п.5
  Решения); live-проверка с Bluetooth-гарнитурой — на реальном митинге.

2026-07-08 · PR: см. ветку claude/cool-gould-d395cf
