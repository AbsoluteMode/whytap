# Онбординг Stage 3: Skills master-detail + try-Drop inline-контролы

## Контекст

Capability opt-in gating, Stage 3 — заменить шаг `.tryAgent` страницей «Skills»
(Agent / Meetings / Google, по умолчанию OFF, явный opt-in). Прошли итерацию
по экранам вместе с Максимом; этот документ фиксирует дизайн-решения, которых
нет в коде.

## Решение

1. **Skills — master-detail, не табы.** Слева вертикальный список feature-карт
   (Agent / Meetings / Google), справа detail-панель с описанием выбранной
   фичи и кнопкой Connect. Карта зеленеет при подключении (`Self.green` +
   `checkmark.circle.fill`).
2. **Agent — opt-in через Connect, без live-теста.** Detail Agent встраивает
   реальный `OnboardingAgentConnectPane`; нажатие Connect при выполненных
   проверках поднимает capability через колбэк `onConnected` (новый параметр
   панели + `initiallyConnected` seed для возврата на карту).
3. **Meetings / Google — «how it works» + визуал.** Detail несёт ordered-шаги
   (`howItWorks`) и мок: `meetingsVisual` повторяет реальный nudge «Take notes /
   Skip» под Dynamic Island (split white|black на `UnevenRoundedRectangle`);
   `googleVisual` — selection → R⌥ → Google.
4. **Super-assistant — showcase, не picker.** Убраны selection / checkbox /
   `replaceEditableSlots`; экран пассивный («вот что есть»), панель держит
   дефолты, юзер раскладывает helpers позже в Settings.
5. **try-Drop — inline язык + хоткей.** На странице первого дропа добавлены
   две компактные строки: input-language picker (popover с поиском + флаг,
   пишет `PrivacyPreferences.selectedLanguage`) и rebind Drop-хоткея
   (switcher Hold/Toggle + рекордер). Рекордер — тот же, что в Settings
   (`HotkeyShortcutRecorder` + `HotkeyPreferences.apply`), не bespoke.
6. **Smart-результат заменяет, не дописывает.** `receiveDropTranscript`
   ставит `tryText = normalized` вместо append на новой строке.

## Почему

- **Master-detail vs табы:** три capability требуют развёрнутого объяснения +
  действия. Segmented-бар давал каждой узкую полоску — некуда положить
  how-it-works и визуал. Вертикальные карты + панель дают место, а зелёная
  карта = состояние opt-in с одного взгляда.
- **Connect без live R⌘-демо:** живой голос/текст-прогон в онбординге — лишний
  фрикшен; факт подключения агента (Connect) — достаточный сигнал opt-in.
- **Showcase, не picker:** заставлять раскладывать hover-панель в онбординге
  рано — юзер ещё не может оценить выбор. Пассивная галерея честнее; раскладка
  живёт в Settings.
- **Inline язык + хоткей на try-Drop:** это ровно две вещи, которые юзер хочет
  поправить сразу после первого дропа. Отправлять его в Settings ломает поток.
  Переиспользование Settings-рекордера = один источник истины для логики
  хоткеев (switcher заблокирован на Hold при hold-Space — Space hold-only,
  инвариант #6). `#if !ONBOARDING_PREVIEW` выносит app-only типы
  (`HotkeyPreferences` / `PrivacyPreferences`) из preview-таргета.
- **Replace, не append:** demo-поле проверяет «выходит ли мой голос чисто», а
  не копит транскрипт; свежий take нагляднее стопки строк.

## Что протестировали

- `swift build` чистый, 11 онбординг-тестов зелёные
  (`OnboardingSkillsScreenTests`: master-detail, showcase-not-picker,
  agent-detail-embeds-pane, meetings/google how-it-works).
- Прогон всего онбординга в dev-контуре.
- Симптом «в Smart отрабатывает Fast» во время теста оказался НЕ клиентом:
  staging-бэкенд стоял на `LLM_PROVIDER=vertex_native` и отдавал Vertex 503 на
  `/api/process`. Починено отдельно — staging переключён на `openrouter`
  (клиентский route smart/fast одинаковый, режим лишь гейтит серверную чистку).

## Отвергли

- Segmented-табы для Skills — тесно для объяснений.
- Checkbox/selection на super-assistant — это не picker.
- Live R⌘-демо в Agent-онбординге — фрикшен.
- Bespoke onboarding-контрол хоткея — дублировал бы Settings-логику.

---

Дата: 2026-06-29 · ветка `feature/capability-opt-in-gating` · Stage 3 поверх
плана `docs/superpowers/plans/2026-06-27-capability-gating-stage3-skills-onboarding.md`
