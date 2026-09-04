# ROO-256 - local transcription via FluidAudio Parakeet

**Дата:** 2026-06-24
**Где:** `Sources/Sidekey/Streaming/Local`, `SettingsModelsView*`,
`TranscriptionSessionFactory`, `AppDelegate`.

## Контекст

ROO-256 требует один рабочий local transcription model: пользователь скачивает
модель, после этого Drop должен работать на устройстве offline, без серверного
STT, с возможностью полностью удалить модель из UI. Local models остаются
Pro-only по решению ROO-250.

## Решение

Используем уже подключённый `FluidAudio` и его Parakeet TDT v3 ASR:

- `LocalTranscriptionModelStore` скачивает и проверяет Parakeet v3 через
  `AsrModels.download/load/modelsExist`.
- Модель кладётся в app-owned cache:
  `Application Support/Sidekey/LocalTranscriptionModels/parakeet-tdt-0.6b-v3`
  (FluidAudio `Repo.folderName` для Parakeet v3 снимает `-coreml`).
- После `download` или первого `loadManager()` создаётся и кэшируется
  `AsrManager`. Он остаётся в памяти, пока приложение живо или пользователь
  не нажмёт `Delete model`.
- Долгая загрузка принадлежит process-wide `LocalTranscriptionModelStore`, а
  не окну Settings. Если пользователь закрыл Settings, download продолжается;
  при повторном открытии UI читает shared status/progress из store.
- `deleteModel()` вызывает `AsrManager.cleanup()`, сбрасывает cached manager и
  удаляет директорию модели.
- `LocalTranscriptionSession` переиспользует `StreamingAudioEngine`, собирает
  PCM16 turn audio, конвертирует в `[Float]` и вызывает
  `AsrManager.transcribe(...)` локально.
- В `AppDelegate` local route bypass'ит `PostProcessor` (`/api/process` и
  BYOK LLM cleanup). После локального STT результат проходит только локальный
  filler-filter, paste/history хвост и не триггерит usage refresh как metered
  backend-STT.

## Почему FluidAudio / Parakeet

- Уже есть зависимость `FluidAudio` в проекте, поэтому не добавляем новый
  ASR runtime и новый supply-chain surface.
- Parakeet v3 даёт multilingual ASR и Core ML path, подходящий для macOS.
- API уже содержит нужные lifecycle hooks: download, model existence check,
  load, cleanup.
- `int8` encoder снижает footprint для first local model. Если качество или
  latency окажутся недостаточными, можно добавить второй вариант модели позже,
  не меняя UI/lifecycle contract.

## UX contract

- Settings → Models → Local показывает выбранную модель, локальный route и
  buttons `Download model`, `Use Local`, `Delete model`.
- Save Local запрещён, пока модель не скачана.
- При удалении активной local-модели app возвращается на `.whytap`, чтобы Drop
  не остался в сломанном состоянии.
- Free user не может выбрать или сохранить Local; runtime factory всё равно
  fail-safe'ит non-Pro `.local` обратно в `.whytap`.

## Отвергли

- **WhisperKit / whisper.cpp.** Реалистичные варианты, но это новая
  зависимость и новая модельная lifecycle surface. Для первого model pick
  дешевле и безопаснее использовать уже присутствующий FluidAudio.
- **Хранить модель в FluidAudio default location.** Выбрали app-owned
  `Application Support/Sidekey/...`, чтобы UI delete мог гарантированно
  удалить именно Sidekey cache.
- **Оставить `/api/process` после local STT.** Это ломает требование offline
  Drop. Local route сознательно вставляет локальный transcript без cloud
  cleanup.

## Что протестировали

- `LocalTranscriptionModelStoreTests`: app-owned root, staged Parakeet v3
  existence check, long-running download status, delete removes the model
  directory.
- `LocalTranscriptionSessionTests`: PCM16 little-endian conversion and language
  mapping.
- `SettingsModelsViewModelTests`: Local requires downloaded model, downloaded
  model can be saved, delete falls back to Whytap.
- `SettingsModelsViewTests`: Local UI exposes download/delete and no longer says
  "Coming soon".
- `TranscriptionSessionFactoryTests`: Pro `.local` builds
  `LocalTranscriptionSession`; free `.local` still falls back.
- `AppDelegateDropFlowRouteTests`: local streaming result bypasses
  post-processing and metered usage refresh.

---
PR: TBD · ветка `codex/roo-256-transcribe-local`
