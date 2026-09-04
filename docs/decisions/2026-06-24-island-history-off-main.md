# Hover-History cards load off the main thread

## Контекст

Whytap «залагал» без явной причины. Профилирование живого prod-процесса
(1.13.5) через `sample` показало: главный поток непрерывно крутит SwiftUI-рендер
острова, и `body` hover-панели Истории на каждом проходе **синхронно** читает
SQLite с диска:

```
IslandDropModeHoverPanel.body
  → historyCards(historyMode)              (IslandView.swift)
  → HistoryStripFeed.clipboardCards()
  → SQLiteHistoryStore.latestClipboardEntries  (queue.sync)
  → sqlite3_step → pread (диск) + base64-декод BLOB'ов
```

В паре с играющей музыкой (эквалайзер ре-рендерил остров ~30 раз/сек) это давало
~30 синхронных дисковых SQLite-чтений в секунду на главном потоке → фризы UI
(в одном из профилей ~45% времени main thread в рендере).

## Решение

Убрать `historyCards()` из `body`. Загрузка карточек идёт OFF-main через
`IslandHistoryCards.load` (`Task.detached`) по `.task(id:)` при входе в панель
Истории и смене вкладки; результат кэшируется в `@State historyCardsCache`,
а `body` читает только кэш. Тип `historyCards` стал `async`.
`SQLiteHistoryStore` уже `@unchecked Sendable`; `HistoryStripFeed` и
`HistoryStripCard` помечены `Sendable` для безопасной передачи с фонового таска.

## Почему

SwiftUI `body` вычисляется часто и должен быть чистым и быстрым — синхронный
дисковый I/O в нём антипаттерн. `Task.detached` уводит `queue.sync` к SQLite на
фоновый поток, главный поток свободен во время чтения; присвоение `@State`
возвращается на main.

## Что протестировали

- Два `sample`-профиля live prod-процесса подтвердили SQLite-стек внутри `body`.
- Юнит-тест `IslandHistoryCards.load`: выполняется off-main
  (`Thread.isMainThread == false`), пробрасывает mode, возвращает карты фида.
- Полный `swift test` зелёный.

## Отвергли

- Снизить частоту вычисления `body` — не убирает дисковый I/O из рендер-цикла.
- Кэш с синхронной первой загрузкой — вернул бы тот же блокирующий вызов.
- Реалтайм-подписка на изменения стора, пока панель открыта — избыточно для
  транзиентной hover-панели; грузим на открытие и смену вкладки (панель
  пересоздаётся на каждый hover, так что данные свежие при каждом открытии).

---
2026-06-24 · ветка `claude/dazzling-dhawan-67728c` → main (squash)
