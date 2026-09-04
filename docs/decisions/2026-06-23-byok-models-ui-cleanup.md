# BYOK Models UI: drop OpenAI + remove illusory one-option model dropdowns

**Дата:** 2026-06-23
**Где:** `Sources/Sidekey/Settings/SelfKeyPreferences.swift`, `SettingsModelsView.swift`.

## Контекст

Две правки по запросу Максима в Settings → Models → «Your key» (BYOK):
1. **OpenAI оставался в BYOK-пикёре**, хотя из наших ключей (whytap-хаб) мы его убрали (#252: OpenAI Realtime `turn_detection:None` не стримит партиалы → длинный холд стопорится → батч). Непоследовательно: убрали из наших ключей, но разрешили вставлять свой OpenAI-ключ для того же тупика.
2. **Иллюзия выбора модели:** BYOK `modelField` всегда рисовал `MacPopup` (dropdown) даже когда у провайдера одна модель (Deepgram=`nova-3`, Soniox=`stt-rt-v4`, ElevenLabs=`scribe_v2_realtime`). Dropdown с единственным пунктом — фейковый выбор.

## Решение

1. **OpenAI убран из BYOK.** `BYOKProvider.selectable = allCases.filter { $0 != .openAI }`; пикёр (`SettingsModelsView` ForEach) идёт по `selectable`. Кейс `.openAI` оставлен (декод легаси). Миграция на уровне геттера `SelfKeyPreferences.selectedProvider`: дефолт и любое легаси `.openAI` → `.soniox` → OpenAI уходит и из UI, и из рантайма (BYOK-транскрибация читает тот же геттер). Дефолтный BYOK-провайдер сменился `.openAI` → `.soniox`.
2. **Dropdown только при реальном выборе.** `modelField`: `selfHosted` → free-text `MacField`; `models.count > 1` → `MacPopup`; иначе → одна модель текстом. После удаления OpenAI ни у одного BYOK-провайдера нет >1 модели → dropdown'а нет ни у кого (корректно).

## Почему

- **Консистентность + честность.** Если OpenAI realtime не годится для наших ключей, он не годится и для своих (тот же direct-адаптер, та же не-стримящая природа). Не предлагаем тупиковый вариант.
- **Миграция в геттере, не в viewModel** — один источник истины: и UI, и рантайм-путь (`TranscriptionSessionFactory` читает `prefs.selectedProvider`) получают soniox; нет рассинхрона UI↔runtime. whytap-сторона уже гейтила dropdown `count > 1` — BYOK приведён к тому же.
- **`.soniox` как дефолт/таргет миграции** — совпадает с whytap-дефолтом, фиксированная модель, не требует baseURL (в отличие от `.selfHosted`).

## Что протестировали

- `SelfKeyPreferencesTests`: дефолт = soniox; легаси `.openAI` → soniox; `selectable` исключает openAI, но кейс остаётся для декода.
- `SettingsModelsViewModelTests`: дефолт-провайдер/модель = soniox/stt-rt-v4.
- `TranscriptionSessionFactoryTests`: перебор BYOK-провайдеров без openAI (он мигрирует); Pro-yourKey строит direct-сессию на soniox.
- `swift test`: вся свита зелёная.

## Отвергли

- **Удалить кейс `.openAI` целиком** — сломало бы декод легаси сохранённого значения; оставили кейс, убрали из `selectable` + мигрируем.
- **Ломать рантайм легаси-юзера молча в null-провайдер** — миграция в `.soniox` (а не, скажем, `.selfHosted`, которому нужен baseURL) минимизирует поломку; затронут ~только тестовый OpenAI-BYOK (Максим), он переконфигурит.
- **Прятать dropdown по списку имён провайдеров** — гейт `count > 1` принципиальнее (dropdown ⇔ реальный выбор; авто-вернётся, если у провайдера появится 2-я модель).

---
PR: TBD · ветка `chore/byok-models-ui-cleanup`
