# Release-contract tests under the local-only release flow

## Контекст

Коммит `f811650` удалил `.github/workflows/release.yml` — GitHub Actions
сборка отключена, релизы теперь выпускаются только локально через
`scripts/user-release.sh` → `scripts/build-dmg.sh`. Два contract-теста читали
удалённый workflow и упали:

- `PackagingRebrandTests.test_releaseWorkflowPassesWhytapArtifactNames` —
  проверял, что workflow передаёт `app_bundle_name=Whytap`/`Whytap-Beta` (а не
  `Sidekey`) — инвариант ребрендинга.
- `ReleaseToolchainContractTests.test_releaseWorkflowRunsOnTahoeRunnerWithXcode26`
  — пинил CI-раннер на `macos-26` + `Xcode_26`, чтобы релизный DMG линковался
  против macOS 26 SDK (Liquid Glass материалы).

## Решение

1. **Whytap-naming** — переориентировать тест на `scripts/user-release.sh`
   (`test_userReleaseScriptUsesWhytapArtifactNames`): он теперь владеет
   мэппингом flavor → `APP_BUNDLE_NAME`. Инвариант жив, просто переехал.
2. **Tahoe SDK контракт** — перенести из текстового CI-пина в **preflight-guard
   в `scripts/build-dmg.sh`**: `xcrun --sdk macosx --show-sdk-version` < 26 →
   сборка падает с инструкцией. Тест `test_releaseBuildGuardsAgainstPreTahoeSDK`
   пинит этот guard.

## Почему

- Инвариант имён артефактов (Whytap, не Sidekey) важен для ребрендинга и не
  исчез вместе с CI — он просто сменил владельца. Тест следует за владельцем.
- Защита Tahoe-SDK реальна: однажды релиз, собранный Xcode 16.x (macOS 15 SDK),
  отрендерил легаси-материалы вместо Liquid Glass на свежей установке коллеги.
  CI-раннер это пинил; без CI защиты не осталось нигде. Runtime-guard **сильнее**
  текстового CI-пина: он падает независимо от того, как выбран Xcode, и работает
  на любой машине оператора.

## Что протестировали

- TDD red→green: новый guard-тест сначала падал «нет guard» (не «файл не
  найден»), затем зелёный после добавления guard.
- Логика guard на 7 версиях SDK: `26/26.0/27.0/100.1` → PASS,
  `15.5/16.2`/пусто/мусор → REJECT (fail-closed). Совместимо с `set -euo
  pipefail` (regex-чек `^[0-9]+$` короткозамыкает `||`, не давая `[ -lt ]`
  упасть на нечисле).
- 102 теста зелёные: 10 целевых + 92 соседних класса, читающих `build-dmg.sh`
  (guard-текст ничей `contains`/`assertFalse` не сломал).
- Code review (4 агента, max-effort): guard признан корректным; 3 находки
  (фактическая неточность в `build-and-release.md`, два слишком слабых
  assertion) — починены. Тесты усилены: пиним точное выражение
  `[ "${SDK_MAJOR}" -lt 26 ]` (ловит инверсию) и operator-echo `sudo
  xcode-select … .app` (не WHY-комментарий).

## Отвергли

- **Удалить ReleaseToolchain-тест** — потеряли бы авто-защиту от молчаливой
  регрессии Liquid Glass материалов.
- **Документировать Xcode 26 только в доке** (без enforcement) — защита свелась
  бы к дисциплине оператора, не enforced сборкой.
- **Симметричный guard в `user-release.sh`** — избыточен: он всегда вызывает
  `build-dmg.sh`, а `--upload-only` сборку не делает.
- **SDKROOT-aware проверка SDK уже собранного бинаря** — оверкилл для
  preflight-hint; `lipo`-проверка универсальности (`build-dmg.sh:292`) +
  fail-closed guard достаточны, а `SDKROOT` скрипт нигде не выставляет.

---

2026-06-19 · PR https://github.com/rootwise-team/sidekey/pull/382
