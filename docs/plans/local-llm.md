# Plan: Локальная LLM (ROO-257)

## Plan status
Status: `ready-for-execution`
Reason: спека утверждена Andrey; план отревьюен (agent) и поправлен; все hard-гейты пройдены; диаризация-развилка решена (Option B: «Я» + диаризация удалённых).

## Source spec
- Spec: утверждена в рабочем чате (Andrey), 2026-06-26.
- Scope: on-device LLM по аналогии с локальным STT. PRO-юзер выбирает LLM-уровень **Local**, один раз качает модель — дальше (1) smart-режим (drop cleanup) и (2) митинги работают локально, без сервера и без расхода минут, офлайн. Митинги — полностью на устройстве, **с локальной диаризацией** (микрофон = «Я», системный звук диаризуется на удалённых спикеров).
- Движок: `ml-explore/mlx-swift` + `ml-explore/mlx-swift-lm` (MLXLLM/MLXLMCommon). Модель: `mlx-community/Qwen3-4B-Instruct-2507-4bit`. Диаризация: FluidAudio (уже зависимость).
- Ограничение: Apple Silicon only; гейт PRO; локальные пути не считаются в usage.

## Current state context (evidence-based)
- **Зеркало STT-стора:** `Sources/Sidekey/Streaming/Local/LocalTranscriptionModelStore.swift` (download/cache в `Application Support`, `LocalTranscriptionModelStatus`, progress, delete); `Sources/Sidekey/Streaming/Local/LocalTranscriptionSession.swift` (FluidAudio Parakeet manager).
- **Уровни/гейтинг:** `LLMIsolationLevel { whytap, yourKey, custom }` в `Sources/Sidekey/Streaming/BYOK/SelfKeyPreferences.swift` (НЕ содержит `.local` — добавляем в Stage 2); STT-сторона `TranscriptionIsolationLevel { whytap, yourKey, local }` уже имеет `.local`. PRO-гейт `gatedLevel` в `Sources/Sidekey/Streaming/BYOK/TranscriptionSessionFactory.swift`; флаги `localAllowed`/`byokAllowed` и tier в `Sources/Sidekey/Usage/UsageCache.swift`.
- **Smart-роутинг:** `Sources/Sidekey/Streaming/BYOK/DirectLLMRouteResolver.swift` → `Sources/Sidekey/PostProcessor.swift`; LLM-клиент `Sources/Sidekey/Streaming/BYOK/OpenRouterLLMClient.swift`; серверный cleanup `/api/process` в `Sources/Sidekey/BackendClient.swift`.
- **Митинги:** `Sources/Sidekey/Meetings/MeetingBYOKProcessor.swift` (`shouldProcessDirectly()` = `transcriptionLevel==.yourKey && llmLevel != .whytap`; кладёт один сегмент `speaker:nil`; `noteSystemPrompt` без спикеров); `Sources/Sidekey/Meetings/MeetingsCoordinator.swift`; `Sources/Sidekey/Meetings/MeetingRecorder.swift` (mic + system **смешиваются** в моно `(m+s)*0.5` в `ChunkWriter`; источники раздельны ДО микса — `micQueue`/`systemQueue`); модель `TranscriptSegment { speaker: String?, start, end, text }` в `Sources/Sidekey/Meetings/MeetingsFeature.swift`; рендер `**Speaker 1 [mm:ss]:**` в `Sources/Sidekey/Meetings/TranscriptMarkdownFormatter.swift`; аплоад `Sources/Sidekey/Meetings/MeetingsBackendClient.swift`.
- **UI:** `Sources/Sidekey/Settings/SettingsModelsView.swift` (LLM-секция), `Sources/Sidekey/Settings/SettingsModelsViewModel.swift`.
- **Зависимость:** FluidAudio запинён `.upToNextMinor(from: "0.14.6")` в `Package.swift` — **строгий minor-пин намеренный** (стабильность ANE/Silero). Бамп — только с эскалацией.
- **Дисциплина тестов:** baseline сломан (ISO8601) → прогон `swift test --skip LinearEventNormalizerTests`, сверять **прирост** падений, а не абсолют. `swift build`/`swift test` — только foreground (фоновый билд убивает агента). CI гоняет только lint — локальный прогон обязателен.

## Spec coverage map
| Требование | Stage | Validation signal |
|---|---|---|
| On-device движок + модель + инференс | 1 | связный текст из локальной модели |
| `LLMIsolationLevel.local` + PRO-гейт + Settings UI | 2 | выбор/скачивание/статус в Settings |
| Smart-режим локально, минуя `/api/process`, без минут | 3 | drop cleanup офлайн, нет вызова бэка |
| Локальная диаризация (FluidAudio) | 4 | спикер-тёрны из аудио-буфера |
| Локальная транскрипция аудио митинга (раздельные дорожки) | 5a | ASR-сегменты по mic и system отдельно |
| Митинг на устройстве: «Я»+удалённые, саммари, bypass | 5b | заметки со «Я»/«Speaker N», нет вызовов сервера |
| Apple-Silicon-гейт + офлайн/ошибки messaging + docs | 6 | Local скрыт на Intel; внятные сообщения; docs/инварианты |

## Cross-cutting concerns
| Concern | План |
|---|---|
| Privacy (инв. #2/#3) | локальные пути не шлют аудио/текст на сервер; контент не логируется → Stages 1,3,5b |
| Cost / usage | ноль серверной стоимости; минуты/секунды не считаются → Stages 3,5b |
| Failure modes | модель битая/нет → пере-скачать; OOM инференса → ошибка+сообщение; офлайн → messaging → Stages 1,6 |
| Security | загрузка моделей по HTTPS с HuggingFace (integrity HF) → Stages 1,4 |
| Concurrency / память | сериализация STT/диаризатор/LLM + eviction перед загрузкой LLM → Stage 5b (гейт) |
| Documentation | CLAUDE.md + decision-doc + кросс-репо `workspace.c4`/`/pr-review` guard → Stage 6 |
| Apple-Silicon-гейт | скрыть/дизейблить Local на Intel → Stage 6 |
| Testing | юнит на каждый модуль; реальный инференс/диаризация — dev-manual (модели 2.3GB не в CI) |

## Stages

### Stage 1 — Движок + model store + инференс (foundation)
- **Behavioral delta:** приложение качает локальную LLM-модель и гоняет on-device инференс → связный текст.
- **Scope.** In: SPM-деп `ml-explore/mlx-swift` + `ml-explore/mlx-swift-lm` (MLXLLM/MLXLMCommon); `LocalLLMModelStore` (модель `mlx-community/Qwen3-4B-Instruct-2507-4bit`; download HF Hub → `Application Support/<app>/LocalLLMModels/qwen3-4b-instruct-2507-4bit/`; `LocalLLMModelStatus { checking, notDownloaded, downloading(Double), ready, failed(String) }`; progress; delete — зеркало `LocalTranscriptionModelStore`); `LocalLLMSession` с `func complete(system: String, user: String) async throws -> String` поверх MLXLLM (load manager лениво, кэш). Out: UI, роутинг, митинги, диаризация.
- **Dependencies:** none.
- **Affected modules:** `Sources/Sidekey/LLM/Local/LocalLLMModelStore.swift` (new), `Sources/Sidekey/LLM/Local/LocalLLMSession.swift` (new), `Package.swift`.
- **Artifacts:** новые файлы, обновлённый `Package.swift`/`Package.resolved`, `Tests/SidekeyTests/LLM/LocalLLMModelStoreTests.swift`.
- **Validation gate:**
  - `swift build` зелёный (MLX резолвится и линкуется).
  - Юнит-тесты (написать ДО кода): `LocalLLMModelStoreTests` — переходы статуса (`notDownloaded→downloading→ready`), путь кэша под App Support, `delete()` чистит кэш и возвращает `notDownloaded`. Команда: `swift test --skip LinearEventNormalizerTests --filter LocalLLMModelStoreTests` → все зелёные.
  - Реальный инференс (env-gated integration-тест + dev-manual, т.к. модель 2.3GB не для CI): загрузить модель и `complete(system: "", user: "Привет, как дела?")` → ответ **непустой И связный** (осмысленный ответ на запрос, не мусор — ловим сломанный токенайзер/шаблон здесь). Команда документируется в тесте/README-комменте.
  - Регрессия: `swift test --skip LinearEventNormalizerTests --filter Local` — STT-тесты не сломаны; число падений не выросло против base SHA.
- **Validator:** агент (build + юнит); разработчик/Andrey (реальный инференс).
- **Failure strategy:** модуль изолирован — ревертнуть PR/коммит, фича нигде ещё не подключена.
- **Observability:** `os_log` старт/финиш инференса + длительность; **никогда** не логировать промпт/ответ (инв. #3).

### Stage 2 — `.local` LLM-уровень + PRO-гейт + Settings UI
- **Behavioral delta:** PRO-юзер в Settings → Models → LLM выбирает «Local», качает модель, видит статус; free — не может (форсится в whytap).
- **Scope.** In: кейс `.local` в `LLMIsolationLevel`; гейт `gatedLLMLevel` (free → `.whytap`) + флаг `localLLMAllowed` (PRO); вкладка «Local» в LLM-секции Settings (карточка Qwen3-4B-Instruct, Download/Delete, прогресс, статус — зеркало локального STT-UI); строки офлайн/не-скачано. Out: фактический роутинг cleanup/митингов (Stages 3/5).
- **Dependencies:** Stage 1 (`blocking-required`).
- **Affected modules:** `SelfKeyPreferences.swift`, `TranscriptionSessionFactory.swift` (или новый LLM-гейт), `UsageCache.swift`, `SettingsModelsView.swift`, `SettingsModelsViewModel.swift`.
- **Artifacts:** изменённые вью/VM/prefs, `Tests/SidekeyTests/Settings/SettingsModelsViewModelTests.swift` (или дополнение).
- **Validation gate:**
  - Юнит: `.local` доступен при PRO; `gatedLLMLevel(.local)` для free → `.whytap`; персист выбора. `swift test --skip LinearEventNormalizerTests --filter SettingsModelsViewModel` зелёные; `swift build` зелёный.
  - **User handoff (UI):** PRO открывает Settings → Models → LLM → видит вкладку Local + карточку Qwen3-4B + Download; скачивание → прогресс → ready; free видит PRO-гейт-баннер. Чек-лист.
  - Регрессия: вкладка локального STT и whytap/OpenRouter/custom LLM целы.
- **Validator:** агент (логика) + **Andrey (UI)** — frontend = user handoff.
- **Failure strategy:** скрыть вкладку Local за флагом / ревертнуть.
- **Observability:** n/a (UI).

### Stage 3 — Smart-режим (drop cleanup) локально
- **Behavioral delta:** при выбранной Local-LLM cleanup диктовки идёт on-device, офлайн, без `/api/process`, без минут.
- **Scope.** In: ветка `.local` в `DirectLLMRouteResolver` (PRO-гейт); `PostProcessor` гонит cleanup через `LocalLLMSession` при `llmLevel==.local`; bypass `BackendClient.process`; не инкрементить usage. Out: митинги.
- **Dependencies:** Stage 1, Stage 2 (`blocking-required`).
- **Affected modules:** `DirectLLMRouteResolver.swift`, `PostProcessor.swift`.
- **Artifacts:** изменённые файлы, `Tests/SidekeyTests/.../PostProcessorLocalTests.swift`, `DirectLLMRouteResolverTests` (дополнение).
- **Validation gate:**
  - Юнит: `PostProcessor` при `llmLevel==.local` зовёт `LocalLLMSession` и **не** зовёт `BackendClient.process` (инжект-spy); `DirectLLMRouteResolver` отдаёт local-маршрут для PRO и nil/whytap для free. `swift test --skip LinearEventNormalizerTests --filter "PostProcessor,DirectLLMRoute"` зелёные.
  - Manual: Local+smart, Drop → чистый текст; при выключенном Wi-Fi работает; в сети нет запроса `/api/process`; минуты в `UsageCache` не растут.
  - Регрессия: whytap/yourKey/custom cleanup-пути не изменены.
- **Validator:** агент + Andrey (drop-флоу).
- **Failure strategy:** при `.local` фолбэк на whytap-cleanup (фича-гейт).
- **Observability:** `os_log` маршрут cleanup (local/remote), без контента.

### Stage 4 — Локальная диаризация (FluidAudio)
- **Behavioral delta:** приложение диаризует аудио-буфер в спикер-тёрны on-device.
- **Scope.** In: **pre-flight гейт (первый шаг):** проверить, что запинённый FluidAudio `0.14.6` экспортирует `DiarizerManager` (диаризация). **Если ДА** — продолжать. **Если НЕТ** — СТОП, эскалация Andrey (строгий minor-пин намеренный, не бампать односторонне). Затем: `LocalDiarizer.diarize(samples:) -> [SpeakerTurn { speaker: String, start: Double, end: Double }]` (модель `FluidInference/speaker-diarization-coreml` → App Support, паттерн model-store из Stage 1); offline-batch пайплайн. Out: интеграция в митинги (Stage 5). NB: `SpeakerTurn` (без text) и `TranscriptSegment` (с text) — **намеренно разные типы**, не объединять.
- **Dependencies:** Stage 1 (`blocking-soft` — переиспользует паттерн model-store).
- **Affected modules:** `Sources/Sidekey/LLM/Diarization/LocalDiarizer.swift` (new), возможно `Package.swift` (только после эскалации).
- **Artifacts:** новый модуль, `Tests/SidekeyTests/LLM/LocalDiarizerTests.swift`, малый 2-голосый WAV-фикстур.
- **Validation gate:**
  - Pre-flight: бинарно — `DiarizerManager` доступен в `0.14.6` (да/нет, при «нет» — эскалация, стадия блокируется).
  - Юнит: `diarize` на 2-голосом фикстуре → ≥2 разных метки, непересекающиеся тёрны. `swift test --skip LinearEventNormalizerTests --filter LocalDiarizerTests` зелёные; `swift build` зелёный; модель качается в App Support.
  - Dev-manual: прогон на реальном 2-голосом сэмпле, sanity тёрнов.
- **Validator:** агент + разработчик.
- **Failure strategy:** ревертнуть модуль (нигде не подключён до Stage 5).
- **Observability:** `os_log` число спикеров/тёрнов (без аудио/текста).

### Stage 5a — Локальная транскрипция аудио митинга (раздельные дорожки)
- **Behavioral delta:** записанный митинг локально транскрибируется Parakeet'ом, причём mic и system — **раздельно** (для последующего «Я» vs удалённые).
- **Scope.** In: локальный капчур митинга сохраняет mic и system как **раздельные** 16кГц-моно буферы (пре-микс остаётся ТОЛЬКО для серверного/BYOK-аплоада — он не меняется); `MeetingLocalTranscriber` — batch-Parakeet (тот же FluidAudio manager, что в `LocalTranscriptionSession`, но по записанным сэмплам) → ASR-сегменты `{text, start, end}` отдельно по mic-дорожке и по system-дорожке. Out: диаризация, alignment, саммари, активация (Stage 5b).
- **Dependencies:** Stage 1 (`blocking-soft` — паттерн загрузки Parakeet manager). NB: это **новый** путь — текущие митинги стримятся на сервер/BYOK, batch-ASR по файлу пишется с нуля.
- **Affected modules:** `Sources/Sidekey/Meetings/MeetingLocalTranscriber.swift` (new), `MeetingRecorder.swift` (раздельные буферы для локального пути), `MeetingsCoordinator.swift` (выбор локального капчура).
- **Artifacts:** новые файлы, `Tests/SidekeyTests/Meetings/MeetingLocalTranscriberTests.swift`, фикстуры mic/system WAV.
- **Validation gate:**
  - Юнит: `MeetingLocalTranscriber` на фикстурах mic+system → непустые ASR-сегменты с таймкодами по КАЖДОЙ дорожке раздельно. `swift test --skip LinearEventNormalizerTests --filter MeetingLocalTranscriber` зелёные; `swift build` зелёный.
  - Регрессия: серверный + BYOK капчур/аплоад митингов (пре-микс) не изменены — их тесты зелёные.
- **Validator:** агент + разработчик (sanity на реальной записи).
- **Failure strategy:** локальный капчур за условием активации (Stage 5b) — инертен до 5b; ревертнуть.
- **Observability:** `os_log` длительности транскрипции по дорожкам, без контента.

### Stage 5b — Митинг полностью на устройстве: «Я» + удалённые + саммари
- **Behavioral delta:** при Local STT+LLM записанный митинг превращается в заметки со спикерами (микрофон = «Я», системный звук диаризован на «Speaker N») и локальным саммари; сервер не вызывается, секунды не считаются.
- **Scope.** In: `MeetingLocalProcessor` (**новый** файл, не трогаем `MeetingBYOKProcessor`); активация при `transcriptionLevel==.local && llmLevel==.local` (PRO) через `MeetingsCoordinator`; пайплайн: mic ASR-сегменты → спикер «Me»; `LocalDiarizer` по system-дорожке → тёрны → назначить system ASR-сегментам «Speaker N»; **alignment**: слить mic+system сегменты по `start` → `[TranscriptSegment]` со `speaker`; локальное саммари через `LocalLLMSession` со **speaker-aware** промптом (использует «кто сказал»); **map-reduce** саммари при превышении контекста (чанк транскрипта → частичные саммари → финальная сводка); сохранить note+transcript в `MeetingsStore`; bypass `MeetingsBackendClient` upload/finalize; секунды-usage не трогать; **eviction**: выгрузить Parakeet/диаризатор перед загрузкой LLM (сериализация моделей на ANE/память). Out: стриминговая диаризация; больше одной локальной модели.
- **Dependencies:** Stage 1, Stage 4, Stage 5a (`blocking-required`), Stage 2 (`blocking-soft`).
- **Affected modules:** `Sources/Sidekey/Meetings/MeetingLocalProcessor.swift` (new), `Sources/Sidekey/Meetings/MeetingTranscriptAlignment.swift` (new), `MeetingsCoordinator.swift`, model-store (eviction API).
- **Artifacts:** новые файлы, `Tests/SidekeyTests/Meetings/MeetingTranscriptAlignmentTests.swift`, `MeetingLocalProcessorTests.swift`.
- **Validation gate:**
  - Юнит: alignment — (mic-сегменты + system ASR + диаризация-тёрны) → `[TranscriptSegment]` с верным спикером («Me» для mic, «Speaker N» для system), сортировка по времени (фикстуры). `MeetingLocalProcessor` активируется только при обоих `.local` (PRO) и **не** зовёт `MeetingsBackendClient` upload/finalize (spy). Eviction: тест, что model-store выгружает STT/диаризатор перед загрузкой LLM (или наоборот). `swift test --skip LinearEventNormalizerTests --filter "MeetingTranscriptAlignment,MeetingLocalProcessor"` зелёные.
  - e2e manual: запись 2-голосого митинга офлайн с Local STT+LLM → окно заметок: саммари + транскрипт со «**Me [mm:ss]:**» и «**Speaker 1 [mm:ss]:**»; нет вызовов сервера (network-инспекция); секунды митингов в usage не растут.
  - Память manual: длинный (≥10 мин) митинг под мониторингом памяти — нет OOM, eviction срабатывает.
  - Регрессия: серверный и BYOK митинг-пути целы.
- **Validator:** агент + Andrey (e2e + память).
- **Failure strategy:** условие активации выключено → фолбэк на серверный путь; ревертнуть.
- **Observability:** `os_log` стадии (transcribe/diarize/align/summarize) + длительности + peak memory, без контента.

### Stage 6 — Apple-Silicon-гейт + messaging + docs (integration/polish)
- **Behavioral delta:** на неподдерживаемом железе Local недоступен с пояснением; единые офлайн/не-скачано сообщения; документация и инварианты обновлены.
- **Scope.** In: скрыть/задизейблить Local (LLM + диаризация) на не-Apple-Silicon с подсказкой; единый messaging офлайн+не-скачано для drop и митингов; обновить `CLAUDE.md` (Архитектура + инвариант #2 про local-пути); `docs/decisions/2026-06-26-local-llm.md` (WHY: MLX+Qwen3, FluidAudio-диаризация, «Я»+удалённые, no-usage); **кросс-репо:** `workspace.c4` + `/pr-review` guard в репо `architecture` (products/sidekey) — требует сам инвариант #2 (отдельный PR в репо architecture). Out: новая функциональность.
- **Dependencies:** Stage 2, 3, 5b (`blocking-required`).
- **Affected modules:** Settings-вью, messaging-утиль, `CLAUDE.md`, `docs/decisions/...`; (репо `architecture`: `workspace.c4`, guard).
- **Artifacts:** изменённые вью, docs, decision-doc; отдельный PR в `architecture`.
- **Validation gate:**
  - Юнит: на не-Apple-Silicon (guard/флаг) Local скрыт/дизейблен; строки messaging присутствуют. `swift build` + relevant filter зелёные.
  - Manual: офлайн+не-скачано → внятное сообщение; офлайн+скачано → работает; (если есть Intel-мак) Local дизейблен с пояснением.
  - Docs: `CLAUDE.md` + decision-doc обновлены (`[docs: CLAUDE.md, docs/decisions/2026-06-26-local-llm.md]`); `architecture`-PR открыт.
- **Validator:** агент + Andrey.
- **Failure strategy:** ревертнуть.
- **Observability:** n/a.

## Execution sequencing
| Stage | Тип зависимости | Параллельно с | Примечание |
|---|---|---|---|
| 1 | foundation | — | первый, блокирует всё |
| 2 | blocking-required: 1 | 4 | UI + уровень |
| 3 | blocking-required: 1,2 | 4 | drop cleanup |
| 4 | blocking-soft: 1 | 2,3 | начинается с pre-flight гейта FluidAudio |
| 5a | blocking-soft: 1 | 2,3 (после Stage 1) | новый batch-ASR путь, раздельные дорожки |
| 5b | blocking-required: 1,4,5a; soft: 2 | — | сборка митинга на устройстве |
| 6 | blocking-required: 2,3,5b | — | гейт+messaging+docs |

Реалистичный порядок: **1** → (**2**, **4**, **5a** параллельно) → **3** (после 2) → **5b** (после 4+5a) → **6**.
Параллельные стадии — в **отдельных worktree** от tip Stage 1, мёрж в feature-ветку cherry-pick'ом (одни и те же файлы не трогают одновременно: 2=Settings/prefs, 3=PostProcessor, 4=Diarization, 5a=Meetings-capture — пересечение только `MeetingsCoordinator.swift` между 5a/5b → они последовательны).

## User handoffs
| Stage | Что валидирует Andrey | Чек-лист |
|---|---|---|
| 2 | Settings Local-вкладка | PRO: видит/качает/ready; free: PRO-гейт |
| 3 | drop cleanup локально | офлайн чистит, нет `/api/process`, минуты не растут |
| 5b | митинг e2e + память | заметки «Me»/«Speaker N», нет сервера, нет OOM на длинном |
| 6 | messaging/гейт | офлайн-сообщения, Local на Intel дизейблен |

## Specialist review
- `pr-review` на каждый stage-PR/feature-PR.
- Privacy/security (инв. #2/#3) — особое внимание ревьюера на Stages 3, 5b.

## Open questions / blockers
| Вопрос | Влияние | Блокирует |
|---|---|---|
| FluidAudio `0.14.6` экспортирует `DiarizerManager`? | при «нет» — нужен бамп пина (намеренно строгий) → эскалация | Stage 4 (pre-flight гейт) |
| Раздельный mic/system капчур для локального пути без регресса серверного | качество «Я» vs удалённые | Stage 5a |

Ни один не блокирует старт Stage 1.

## Out of scope (→ потом)
Стриминговая диаризация; несколько локальных моделей на выбор; пользовательские системные промпты; диаризация по моно-миксу (отвергнута в пользу раздельных дорожек).

## Risks
| Риск | Митигация | Stage |
|---|---|---|
| MLX только Apple Silicon | гейт + messaging | 6 |
| Память 8GB: STT+диаризатор+LLM в митинге | сериализация + eviction (гейт) | 5b |
| Длинный митинг > контекста 4B | map-reduce саммари | 5b |
| FluidAudio diarization недоступна в `0.14.6` | pre-flight гейт + эскалация (не бампать молча) | 4 |
| Регресс серверного капчура при раздельных дорожках | пре-микс для аплоада не трогаем; отдельная локальная ветка | 5a |

## Handoff for execution
- Status: `ready-for-execution`. Все hard-гейты пройдены.
- PR-границы: feature-ветка `max/roo-257-lokalnaya-llm`; Andrey валидирует локально перед PR в `develop`.
- Исполнение: основная сессия спавнит dev-агента (`dev-foundation` + `swiftui-expert`) per stage в worktree + reviewer-агент на гейте. Параллельные стадии — в отдельных worktree, мёрж cherry-pick'ом.
- ROO-258 («валидация local build») — отдельный финальный валидационный проход поверх Stage 6.
