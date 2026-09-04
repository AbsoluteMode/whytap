# Апдейт: одна кнопка (↓) + ✕ skip-this-version, без «Updating»

## Контекст

#354 (download-on-action) дал флоу в два действия: ↓ скачать → [Restart now]
поставить, вторичное «Later». После теста 1.9.5 на проде владелец (Максим)
попросил: ОДНУ кнопку (↓ = скачать+поставить+перезапустить за клик), крестик =
пропустить **именно эту** версию, и убрать слово «Updating» (в узкой пилюле
~70pt оно ломалось «U»/«pdating»).

## Решение

- **↓ — одно действие:** `UpdateController.applyDriverStage(.readyToInstall)`
  авто-дёргает `driver.invokeInstall()` — без отдельного шага [Restart now].
  Пилюля держит downloading/installing-вид до перезапуска.
- **✕ — skip this version:** новый `IslandUpdateUserDriver.invokeSkip()` →
  `reply(.skip)` (Sparkle помечает билд skipped, будущие версии предлагает).
  Заменяет «Later» (тот лишь прятал на сессию).
- **`.downloading` — только иконка**, без «Updating».
- VERSION → 1.9.6.

## Почему

Инвариант #354 сохранён: `automaticallyDownloadsUpdates = false` не трогаем —
download остаётся **user-initiated** (клик ↓). Поэтому авто-install по
готовности — НЕ сюрприз-рестарт: пользователь сам нажал «обнови». Это не тот
«проактивный авто-install при wake/idle», который #354 отверг (там — БЕЗ клика).
Один клик = осознанное «обнови меня сейчас», что и просил владелец.

✕ = `.skip` (а не session-dismiss): пользователь явно отклоняет конкретный
билд; повторно не дёргаем, но следующие релизы покажем.

## Что протестировали

TDD: `invokeSkip()` → `reply(.skip)`; `applyDriverStage(.readyToInstall)`
авто-install + НЕ публикует user-actionable `.readyToInstall`; пилюля
`.available` показывает skip-affordance (не restart/later); `.downloading`
`primaryLabel` пустой (icon-only). 49 update/pill тестов зелёные; полный сьют
чист, кроме предсуществующего флака `Telegram*ListenerTests`.

## Отвергли

- **Отложенный рестарт «когда удобно»** — это и есть второй клик; владелец
  хочет один.
- **Оставить «Updating» с переносом** — одно слово в ~70pt ломается уродливо
  посреди слова; иконки достаточно.
- **Сохранить #354 как есть** — владелец явно попросил один клик после теста
  1.9.5 на проде.

---
2026-06-17 · ветка `fix/update-one-button-skip`
