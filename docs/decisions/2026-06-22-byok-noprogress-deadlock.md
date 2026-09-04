# Session no-progress hard resolve + BYOK deadlock (Task 4)

## Контекст

Drop resilient delivery (план C). Турн, который завис в середине записи и
которого пользователь **никогда не останавливает** (не отпустил клавишу, либо
stop-событие потерялось), раньше не резолвился вообще: `run()` бесконечно ждал
stop. 75-секундный turn-watchdog только логировал, не резолвил. Это та самая
дыра «2 из 46 турнов исчезли без терминала» из диагностики.

Решение: добавить **hard no-progress resolve** в обе стрим-сессии — если аудио
шло, но партиал не приходил `noProgressResolveSeconds` (дефолт 12с) И юзер не
остановил, остановить движок и резолвить `.degraded`, чтобы DeliveryResolver
(Task 3) спас турн батчем.

## Решение

Soniox: hard resolve дёргает `resolve(with:)` напрямую; soft-degrade ветка
больше **не делает `return`**, чтобы hard resolve оставался достижим в том же
polling-таске.

BYOK (`DirectProviderStreamingSession`): тот же фикс, адаптированный под
event-loop модель (резолв через конец event-стрима + after-loop).

## Почему

Ключевая **асимметрия**, на которой легко споткнуться:

- В Soniox гард hard-resolve НЕ проверяет `!degraded` — поэтому достаточно
  снять `return` из soft-degrade, и hard resolve срабатывает после того, как
  soft уже выставил `degraded`.
- В BYOK было ДВА барьера сразу: (1) soft-degrade делал `return` (убивал
  polling-таск), и (2) гард hard-resolve содержал `!self.degraded`. Даже сняв
  `return`, hard resolve не сработал бы из-за `!degraded`. А after-loop встаёт
  на `await audioTask?.value`, который завершается только при остановке движка
  (на `stop()`). Без stop и без достижимого hard-resolve → движок никогда не
  останавливается → **вечный deadlock**, `run()` не возвращается.

Фикс BYOK: снять `return` из soft-degrade И убрать `!self.degraded` из гарда
hard-resolve — зеркало Soniox. Теперь hard resolve — универсальная сеть и для
stall-degrade, и для transport-degrade (оба раньше тоже висли бы при
«никогда-не-stop»).

## Что протестировали

- Soniox degraded: 5 тестов зелёные (вкл. `testNoProgressResolvesDetachedWithoutStop`).
- BYOK degraded: зеркальный `testNoProgressResolvesWithoutStop` **ни разу не
  гонялся** в WIP-коммите (Soniox-фильтр его не захватывал). Red-прогон под
  `perl alarm 45s` → EXIT=142 (SIGALRM): тест собрался и завис — deadlock
  подтверждён эмпирически. После фикса: 8 тестов зелёные, 5.5с (без зависания).
- Регрессий нет: оба класса вместе 13 тестов, 0 провалов.

## Доп. находка ревью: приоритет cancel над degrade (BYOK)

Независимое ревью (Codex) нашло второй, **предсуществующий** баг в том же
after-loop BYOK. `cancel()` (Escape) выставляет `cancelled=true`, но НЕ трогает
`degraded`; after-loop проверял `if degraded` ПЕРЕД `.cancelled`. Сценарий:
турн стормозил (soft/transport degrade → `degraded=true`) → юзер жмёт Escape →
`run()` возвращал `.degraded` → DeliveryResolver батчем **вставлял отменённый
текст**. Soniox иммунен (его `cancel()` дёргает `resolve(with: .cancelled)` под
exactly-once гардом — первый резолв побеждает); BYOK резолвит по тому, какая
ветка after-loop сработала, поэтому порядок надо задавать явно.

Фикс: cancel проверяется ДО ветки `degraded` и ПОВТОРНО после
`await audioTask?.value` (cancel может прилететь во время ожидания).
Red доказан тестом `testCancelAfterDegradeResolvesCancelledNotDegraded`
(вернул `.degraded` вместо `.cancelled`), green после фикса.

Прочие наблюдения ревью (не баги сейчас): upstream закрывается несколько раз
(soft/hard/teardown) — все конкретные адаптеры идемпотентны на close(), но
протокол `BYOKUpstreamSession` этого не гарантирует (хрупко при добавлении
нового адаптера — кандидат на контрактный комментарий/тест).

## Отвергли

- Останавливать движок прямо в soft-degrade — теряется хвост аудио (смысл
  soft-degrade именно «продолжать захват до stop»); hard resolve на бОльшем
  пороге — правильное место для force-stop.
- Чистить `degraded` внутри `cancel()` — отвергли в пользу явного приоритета в
  after-loop: cancel/degrade выставляются из разных мест (Escape vs stall/
  transport), приоритет читается там, где принимается решение о возврате.
- Салвэйдж сырого партиала как основной путь — отложено (UX-осторожность,
  полный/батч приоритетнее); см. spec.

---
2026-06-22 · ветка claude/youthful-leakey-95a4af · spec/план:
docs/superpowers/{specs,plans}/2026-06-21-drop-delivery-resolver*.md
