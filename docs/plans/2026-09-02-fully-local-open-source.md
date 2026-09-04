# Whytap: полностью локальный open-source инструмент

Дата: 2026-09-02. Статус: черновик плана, ждёт решений (раздел «Решения»).

## Контекст

Решение 2026-06-14 (open client под FSL + закрытый backend + подписка)
отменяется. Новая цель: Whytap = полностью локальный, бесплатный, открытый
инструмент. Никаких paid-возможностей, никаких серверов Whytap в runtime.
«Мозг» уже локальный (Claude Code / Codex CLI юзера, ROO-пивот 2 июня);
STT и LLM уже имеют локальные пути (FluidAudio Parakeet, MLX Qwen3) и BYOK.
Остаётся выпилить облачный слой Whytap и гейты, которые его продавали.

## Инвентаризация (снимок main 1.18.10, build 1443)

Исходники: 522 Swift-файла, ~111.8k строк. Тесты: 444 файла.

| Класс | Объём | Что это |
|---|---|---|
| Cloud-only, удаляется целиком | 60 файлов, ~11k строк | BackendClient, Auth (кроме KeychainStore/TokenStore), Usage, Analytics, Diagnostics, Networking, hub-стриминг (Soniox* + WhytapHubAdapter), MeetingsBackendClient + UploadQueue + MeetingTelemetryPayload, PreferencesAPIClient + UserPreferences* + VocabularyCache + SettingsUsage*, UpdateBeacon, relay-части Notifications |
| Mixed, хирургия | ~14 директорий, ~57k строк | AppDelegate (5978 строк, главная поверхность), Meetings, DynamicIsland, Onboarding, Settings, Streaming, Notifications, PostProcessor, Updates, Privacy, GoogleSearch, Enterprise |
| Purely local, не трогаем | ~45k строк | Agent, AgentDaemon, LLM, Streaming/Local + Streaming/BYOK, History, Hotkeys, Case, NowPlaying, VolumeDuck, Filler, WindowChrome, Permissions, Pasteboard, Display |

Тесты: ~121 удаляются вместе с кодом, ~48 переписываются (убрать
`tokenStore:` / `hasBackendClient:` / `whytapJWT:` / `tier:` из конструкторов,
снять tier-ассерты), ~275 не трогаются. Четыре контракт-теста падают
гарантированно: PackagingRebrandTests, ProductLineEntryContractTests,
UsageContractTests, SettingsWindowTabTests. `StubURLProtocol` живёт внутри
BackendClientTests.swift и используется 18 файлами: вынести в
Tests/SidekeyTests/Support/ ДО любого удаления, иначе тест-таргет не
компилируется.

Эндпоинты Whytap, которые исчезают: /auth/* (register, login, exchange,
desktop/refresh, logout, me), /api/transcribe (+ /stream, /stream/v2),
/api/process, /api/events, /api/heartbeat, /api/onboarding-event,
/api/user/preferences, /api/user/usage, /meetings/* (create, chunks, finalize,
telemetry, list, get, note, usage, import), /api/linear/*, /api/github/*,
/api/slack/* (мёртвый код), updates.whytap.ai/prod/latest.json (beacon).

Два скрытых блокера, найденных при инвентаризации:
1. Tier-гейт важнее сети. `TranscriptionSessionFactory.gatedLevel`,
   `DirectLLMRouteResolver`, `MeetingsCoordinator.isFullyLocalMeetingEnabled`,
   `MeetingBYOKProcessor`, `SettingsModelsViewModel` требуют
   `UsageCache.tier == .pro`, а tier поднимается ТОЛЬКО ответом
   `/api/user/usage`. Удалить Usage без правки гейтов = все локальные пути
   выключены навсегда.
2. BYOK сегодня не офлайн: `AppDelegate.makeStreamingSession` требует
   `streamingHandshakeJWT()` для `.yourKey`, JWT пропускается только для
   `.local && tier == .pro`.

## Что остаётся после выпила (продуктовая карта)

- Drop: hold Space -> STT -> paste. STT: Local (Parakeet, Apple Silicon) или
  Your key (OpenAI Realtime / Deepgram / Soniox / ElevenLabs / self-hosted
  OpenAI-compatible). Cleanup: Local LLM (MLX, Apple Silicon), OpenRouter
  ключом юзера, Custom OpenAI-compatible endpoint (Ollama / LM Studio / vLLM),
  либо без LLM (Filler-стриппинг).
- Agent: R-Cmd -> локальный Claude Code / Codex. Уже локально.
- Meeting Notes: fully-local (Parakeet + FluidAudio диаризация + MLX саммари,
  Apple Silicon) или BYOK-процессор (любой Mac). Viewer BlockNote локальный.
- Google search R-Alt: локальный NSWorkspace.open, STT по тому же фабричному
  пути.
- Dynamic Island, hotkeys, History (SQLite), NowPlaying, VolumeDuck, Case vault.
- Sparkle-обновления: механика host-agnostic, фид переезжает на GitHub
  Releases.
- Intel Mac: локальных моделей нет (MLX + Core ML = Apple Silicon only) ->
  только BYOK/custom endpoint. Это причина сохранить BYOK.

Удаляется полностью: OAuth/JWT/login, tiers/usage/quota/free-pill/pricing
screen, Whytap-hub STT, /api/process, cloud meetings upload/summary/polling,
телеметрия (EventTracker 33 вызова в 12 файлах, heartbeat, onboarding
reporter, crash reporter, Langfuse share-data opt-in), server-synced
preferences/vocabulary (становятся локальными), GitHub-нотификации (только
relay через Whytap GitHub App, прямого клиента нет), update beacon.

## Решения, которые нужны (с рекомендацией)

1. Репозиторий и история.
   - A. Новый публичный репо со свежим initial commit (приватный остаётся
     архивом). + чисто, ничего из истории не утечёт (в истории: user-email
     стороннего человека, Team ID, полный инвентарь Doppler-секретов в
     infra/, внутренние decision-docs). - публично теряется git blame.
   - B. Переключить видимость текущего репо после filter-repo. + история.
     - переписывание 596 коммитов, все внутренние доки в истории остаются,
     риск пропустить.
   Рекомендация: A.
2. Лицензия.
   - MIT. + максимум адопшена, совпадает с Sparkle/MLX, проще всего.
     - proprietary-форки разрешены.
   - Apache-2.0. + патентный грант, явная trademark-оговорка. - чуть
     тяжелее для контрибьюторов, редкость среди Mac-утилит.
   - GPL-3.0. + форки обязаны оставаться открытыми. - отпугивает часть
     контрибьюторов/корпоративных юзеров.
   Рекомендация: MIT, если цель = адопшен; GPL-3.0, если важно, чтобы никто
   не закрыл. FSL/CLA больше не нужны.
3. Copyright holder: Максим лично (без договора отчуждения, проще) vs
   Rootwise LLC (нужен договор отчуждения + решение участника, см. память
   OSS-стратегии). Рекомендация: лично, «Maxim Butorin and Whytap
   contributors».
4. Notifications (Slack/Telegram/Linear/GitHub, 56 файлов, ~8.8k строк, 61
   тест). GitHub умирает в любом случае. Slack и Linear connect требуют OAuth
   client ID нашего приложения (плейсхолдеры в Info.plist), Telegram = чисто
   bot-token.
   - A. Вырезать подсистему целиком. + минус ~9k строн и вся OAuth-регистрация,
     фокус на Drop/Agent/Meetings. - теряем готовые Telegram/Slack polling.
   - B. Оставить direct-подмножество (Telegram, Slack polling, Linear polling).
     + фичи живут. - надо поддерживать Slack/Linear OAuth-приложения, форкеры
     должны заводить свои.
   Рекомендация: A для первого OSS-релиза, вернуть как отдельный модуль
   потом, если будет спрос.
5. B2B-линия (SidekeyB2B target + Enterprise/, 933 строки; пилот ICOM).
   - A. Удалить target и Enterprise/, «OpenAI-compatible endpoint» уже есть
     в consumer BYOK (`LLMIsolationLevel.custom`, `BYOKProvider.selfHosted`).
   - B. Оставить как есть. - тащит CorporateMeetingPortalClient на
     meetingsBackendURL, второй бинарь, контракт-тесты.
   Рекомендация: A, если пилот ICOM не продолжается на этой кодовой базе.
6. Подпись и доставка. Developer ID сейчас у друга (память). Варианты:
   локальный user-release.sh как сейчас, артефакты в GitHub Releases +
   appcast там же (рекомендация); либо unsigned-сборки (плохой UX,
   Gatekeeper). Apple Developer ($99/год) остаётся единственной постоянной
   статьёй расходов.
7. Windows-стаб (60 файлов) и landing/landing-src/nginx/infra: вынести в
   отдельные репо / удалить из клиентского. Рекомендация: landing в свой
   репо, infra и nginx в приватный infra-репо, windows удалить (README
   говорит «бинаря нет»).
8. Название и bundle id: оставить Whytap + com.rootwise.sidekey (модуль
   Sidekey переименовывать не будем, слишком большой churn). Форкерам
   параметризуем TEAM_ID / BUNDLE_ID / appcast / EdDSA-ключ.

## План по фазам (каждая = отдельный PR, `swift test` зелёный)

0. Подготовка. Вынести `StubURLProtocol` в Tests/Support. Добавить
   guard-тест `CloudRemovalTests` по образцу ScreenRecordingRemovalTests
   (перечисляет Sources/Sidekey и запрещает `BuildConfig.backendURL`,
   `Authorization: Bearer` к Whytap, `EventTracker`, `UsageCache`, ...);
   список запретов растёт по фазам.
1. Гейты. Удалить Usage/, параметр `tier:` из фабрик/резолверов, Usage-таб,
   IslandFreeTierLimitsPill, OnboardingTiersScreen, `consumerBilling` из
   ProductModule, precheck-и в AppDelegate/MeetingsCoordinator, 402-ветки.
   После этой фазы Local/BYOK доступны без сервера. Hardware-гейт
   `LocalModelSupport.isAppleSilicon` остаётся.
2. Auth. Удалить Auth/ (кроме KeychainStore/TokenStore/FileTokenStore),
   auth-часть BackendClient, WebAuthCoordinator, URL-scheme обработку
   `sidekey://oauth`, шаги `.auth`/`.authSuccess` онбординга, Account-таб
   (screenshot-protection toggle переезжает в Other), logout-плумбинг из
   AgentController. `OnboardingRouter` без `needsAuth`; старт = permissions.
   `makeStreamingSession` без JWT-handshake.
3. STT. Удалить hub (Soniox*, WhytapHubAdapter, SonioxStreamingURL,
   `/api/transcribe` batch). `TranscriptionIsolationLevel`: убрать `.whytap`,
   дефолт = `.local` на Apple Silicon, `.yourKey` на Intel (с онбордингом
   «введи ключ или скачай модель»). Resilient-delivery: batch-recover через
   локальный Parakeet (PCM уже держим) вместо `/api/transcribe`; для BYOK
   batch-путь провайдера или rung3-партиал.
4. LLM cleanup. Удалить `/api/process`, `LLMIsolationLevel.whytap`;
   PostProcessor: local / yourKey / custom / none.
5. Meetings. Удалить MeetingsBackendClient, UploadQueue, telemetry payload,
   polling, `waiting_to_reconnect`-серверные статусы; оставить
   MeetingLocalProcessor + MeetingBYOKProcessor + MeetingsStore. Health-
   телеметрия записи остаётся только в локальном логе или удаляется.
6. Телеметрия и приватность. Удалить EventTracker + 33 вызова, Analytics/,
   Diagnostics/ (MetricKit-репортер), UserErrorReporter, Privacy share-data
   (AppLanguage остаётся), heartbeat-хвост в UpdateController.
7. Preferences. PreferencesAPIClient/UserPreferences*/VocabularyCache ->
   локальный store (UserDefaults/SQLite). Capability-флаги (Agent/Meetings/
   Google opt-in) остаются как локальные prefs.
8. Notifications и B2B: по решениям 4 и 5.
9. Updates. Фид -> GitHub Releases (appcast.xml как release-asset или
   GitHub Pages), удалить UpdateBeacon, параметризовать TEAM_ID / BUNDLE_ID /
   APPCAST_URL / sparkle-public-ed-key (в репо только .example, чтобы форк не
   мог верифицировать и ставить наши релизы поверх своих сборок).
10. Гигиена и файлы репо. LICENSE, NOTICE/THIRD_PARTY_LICENSES (MLX metallib,
    BlockNote-бандл, MediaRemoteAdapter, шрифты OFL, оговорка про логотипы в
    Resources/UsefulLinkIcons), TRADEMARK.md, SECURITY.md (security@whytap.ai),
    CONTRIBUTING.md, CODE_OF_CONDUCT.md, issue/PR-шаблоны, .gitignore (*.dmg,
    .env*, *.p8/*.p12/*.pem/*.key, node_modules, dist). Скраб: email стороннего
    юзера в docs/decisions/2026-07-02-meeting-health-telemetry.md и
    docs/superpowers/specs/2026-07-02-meeting-telemetry-design.md, личные
    email в тестах/OnboardingPreview, `icom` -> `acme`, полные linear.app-URL,
    Team ID в scripts/docs, B2B-баннер в README. README на английском,
    CLAUDE.md переписать под новую архитектуру, docs/archive и
    docs/superpowers пересмотреть.
11. Публикация и миграция. Новый репо, первый релиз 2.0.0. Существующие
    юзеры 1.18.x логинятся через auth.whytap.ai и обновляются с
    updates.whytap.ai: релиз 2.0.0 выкатывается через СТАРЫЙ фид (иначе они
    его не увидят), сам 2.0.0 уже несёт новый SUFeedURL. Backend (sidekey-
    backend, auth-backend, meetings-backend, Langfuse) выключается только
    после того, как старый фид отдал 2.0.0 достаточно долго; при первом
    запуске 2.0.0 подчищаем Keychain-записи auth.*. Backend-репо: архивировать
    (открывать не обязательно, в runtime их нет).

## Риски

- AppDelegate 5978 строк: auth-гейт, wiring listener-ов, streaming factory,
  meetings install. Каждая фаза его трогает; мержить последовательно, без
  параллельных PR в AppDelegate.
- Intel-юзеры без ключа остаются без STT. Онбординг должен это честно
  сказать.
- Юр-документы (Terms/Privacy/Refund под Paddle) и лендинг устаревают:
  Privacy упрощается до «серверов нет», Terms/Refund не нужны.
- Sparkle EdDSA-ключ и Developer ID: переезд на свой Apple Developer
  (Rootwise LLC или личный) ломает TCC/Keychain у существующих юзеров при
  смене Team ID; решать до 2.0.0 или отдельным релизом с предупреждением.

## Ссылки

Аудит-отчёты (backend-map, paid-gates, publish-hygiene, test-coupling)
получены 2026-09-02 в сессии планирования; ключевые file:line перенесены в
этот план. Память: project_whytap_oss_business_strategy (старая стратегия,
пивот отмечен там же).
