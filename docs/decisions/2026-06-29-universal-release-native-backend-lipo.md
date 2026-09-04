# Universal release-сборка: нативный backend per-arch + lipo (MLX Metal-фикс)

## Контекст

Релиз 1.15.0 — **первый прод-релиз с MLX** (ROO-257 local LLM, влит в main
после 1.14.0). `scripts/build-dmg.sh` собирал universal-бинарь одним вызовом
`swift build -c release --arch arm64 --arch x86_64`. На этом релизе он стал
падать:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
       use: xcodebuild -downloadComponent MetalToolchain
Build failed
```

Падал на компиляции Metal-кернелов mlx-swift (`scaled_dot_product_attention.metal`,
`steel_attention.metal`, `rope.metal`, `gemv.metal` и др.).

## Решение

`build-dmg.sh` собирает каждую архитектуру **нативным backend'ом SwiftPM**
отдельно, затем склеивает `lipo`:

```bash
swift build --build-system native -c release --arch arm64
swift build --build-system native -c release --arch x86_64
lipo -create .build/arm64-apple-macosx/release/Sidekey \
             .build/x86_64-apple-macosx/release/Sidekey \
             -output build/release-universal/Sidekey
```

## Почему

Один `swift build` с ДВУМЯ `--arch` переключает SwiftPM на **Xcode/xcbuild
backend** (нативный backend не умеет fat-бинари). Xcbuild видит `*.metal` в
таргете `Cmlx` (mlx-swift) и пытается скомпилить их в bundle-ресурс — **хотя
приложение уже шипает прекомпиленный `Resources/mlx.metallib`** (собранный
`scripts/build-metallib.sh` через прямой `xcodebuild`, version-locked к
mlx-swift). Скачанный Metal Toolchain виден `xcrun -f metal`, но xcbuild-backend
его не находит → фатальные ошибки.

Нативный backend (`--build-system native`) `.metal` НЕ компилит — он полагается
на рантайм-металлиб. Поэтому per-arch нативная сборка + `lipo` даёт universal
бинарь, ни разу не заходя в xcbuild. Ресурсы (mlx.metallib, шрифты, флаги)
build-dmg.sh и так копирует из `Resources/`, а не из products-dir, так что смена
products-dir на `build/release-universal/` ничего не теряет.

Корень диагностирован Codex (его MLX-сетап); перепроверено действием —
полный `FLAVOR=prod user-release.sh` собрал, нотаризовал и опубликовал
`Whytap-1.15.0-build1414` на прод-appcast.

## Что протестировали

- `xcodebuild -downloadComponent MetalToolchain` (скачал 17E188, `xcrun -f metal`
  резолвит) — **НЕ помогло**: xcbuild всё равно не использовал тулчейн.
- Чистка `.build/apple` (свежий build-description) — **НЕ помогло**: ошибка не
  кэш, xcbuild активно не находит metal.
- Нативный per-arch + lipo — **зелено**: arm64/x86_64 `Build complete`, `lipo`
  даёт `x86_64 arm64`, полный релиз опубликован.

## Отвергли

- Доустановка Metal Toolchain как фикс — недостаточно (xcbuild его не берёт).
- Заставлять xcbuild найти тулчейн — не вышло (Xcode 26.4.1/17E202 vs тулчейн
  17E188; глубокий toolchain-resolution issue).
- Компилить `.metal` в app-сборке — не нужно: рантайм-металлиб уже прекомпилен.

---

Дата: 2026-06-29 · ветка `chore/release-1.15.0` · диагностика Codex (codex-rescue)
