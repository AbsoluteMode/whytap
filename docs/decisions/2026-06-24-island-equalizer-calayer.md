# Music equalizer animates on CoreAnimation, not a SwiftUI TimelineView

## Контекст

Пока играет музыка, `IslandMusicEqualizerView` гонял
`TimelineView(.animation, minimumInterval: 1/30)` — 30 кадров/сек. Каждый тик
менял `@State`, что заставляло SwiftUI пересчитывать тело и **ре-лэйаутить весь
hosting-view острова на главном потоке каждый кадр**. Профиль `sample` + `top`
показали ~16% CPU постоянно, пока трек активен (даже без взаимодействия).

Эквалайзер — декоративный, низкоприоритетный слот правой полосы (см.
`IslandRightBandPriority`): его перебивает почти любой содержательный ивент, и
он виден лишь в «idle + музыка». Референс boring.notch (`AudioSpectrum`) в той же
роли не лагает.

## Решение

Переписать `IslandMusicEqualizerView` на `NSViewRepresentable` поверх
`IslandEqualizerBarsView: NSView` с барами-`CAShapeLayer`. Анимация —
`CAKeyframeAnimation` по `transform.scale.y`, выставляемая `Timer` раз в
~0.42 с; кадры между тиками интерполирует CoreAnimation на render-server, вне
главного потока. Асимметрия attack/decay (быстро вверх, медленно вниз — VU-cue)
сохранена через keyTimes `[0, 0.22, 1]` + timingFunctions `[easeOut, easeIn]`.
Покадровая `IslandMusicEqualizerModel` удалена; чистая форма (center-weighted
targets, normalized→scale mapping) вынесена в `enum IslandMusicEqualizer` и
покрыта юнит-тестами. Публичный API `IslandMusicEqualizerView(isPlaying:)` и
визуал (5 баров, размеры, floors, opacity) сохранены — `IslandMusicWingView`
не менялся.

## Почему

`TimelineView(.animation)` держит display-link активным и тянет main-thread
re-layout каждый кадр. CoreAnimation (`CAShapeLayer` + keyframe) интерполирует
на render-server — главный поток будят лишь раз в макро-цикл (~0.42 с). Это ровно
подход boring.notch (`NSView` + `CAShapeLayer` + `CABasicAnimation` + редкий
`Timer`), который доказанно не лагает. Условный рендер `if showsMusic` снимает
view с дерева при перебивании, `dismantleNSView`/`deinit` гасят таймер — вне
экрана работы ноль.

## Что протестировали

- `sample` live prod подтвердил re-layout острова от тика эквалайзера.
- Юнит-тесты на `centerBoost`, `randomTargets`, `barScaleY`.
- Полный `swift test` зелёный; визуально проверено в dev-сборке (подтверждено).

## Отвергли

- Снизить fps 30→15 — полумера: не убирает main-thread re-layout, деградирует
  плавность.
- Симметричный `autoreverses` как у boring.notch — решили сохранить
  асимметричный VU-envelope (явный выбор).
- Оставить как есть — постоянные ~16% CPU при музыке неприемлемы (батарея/нагрев).

---
2026-06-24 · ветка `claude/dazzling-dhawan-67728c` → main (squash)
