# Эпоха 03 — Runtime, ключи, язык и native lifecycle

> Для исполнителя: использовать `executing-plans`; необходимы контракты activity/shutdown из эпохи 02 и snapshot ownership из эпохи 01.

**Цель:** закрыть R08–R10 и проверить обходы shared GPU gate/восстановление аудио.

**Архитектура:** дорогая подготовка кандидата может выполняться заранее; публикация STT/editor/config производится под одной reservation сессии. Пока commit содержит await, новые intents только ставятся в очередь, а не отменяют полузавершённую публикацию.

**Стек:** ClickNSpeak, CNSSession, CNSTranscription, CNSEditors, CNSCore, CNSAudio.

**Спецификация:** [00-REVIEW-AND-PLAN.md](00-REVIEW-AND-PLAN.md), R08–R10, долг 1–2. Глобальные ограничения обязательны.

## Задача 1 — Исключительная и согласованная активация runtime

**Файлы:** `ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift`, `RuntimeServiceFactory.swift`; `Packages/CNSTranscription/Sources/CNSTranscription/TranscriberRouter.swift`; `Packages/CNSEditors/Sources/CNSEditors/AiEditorRouter.swift`; tests `AppRuntimeCoordinatorTests.swift`, `RuntimeRouterTests.swift`, `AiEditorRouterTests.swift`.

**Интерфейсы:** расширить `RuntimeSessionCoordinating` методами `beginRuntimeMutation() -> Bool`, `endRuntimeMutation()` из эпохи 02. В AppRuntimeCoordinator добавить commit phase, в которой generation не отменяет публикацию между установками routers. Shutdown ждёт завершения этой фазы. Latest desired intent применяется следующим.

- [ ] Перенести `preparationCannotCommitIntoRecording` из RuntimeAuditProbes. Для полной интеграции удержать реальный SessionController в recording/file/popup, затем освободить factory; descriptor не меняется до завершения activity.
- [ ] Добавить barriers до STT install и между STT/editor installs. В середине подать новый intent, dictionary update и shutdown отдельно. Нельзя наблюдать пару «новый STT + прежний editor» из новой сессии; previous runtime не уничтожается до гарантированного снятия всех uses.
- [ ] После подготовки повторно дождаться idle и синхронно взять reservation:

```swift
while session?.beginRuntimeMutation() != true {
    try ensureCurrent(generation)
    try await Task.sleep(for: .milliseconds(20))
}
defer { session?.endRuntimeMutation() }
try ensureCurrent(generation)
```

- [ ] После reservation объединить свежий dictionary snapshot с desired runtime полями, сохранить config; затем завершить обе публикации без supersede cancellation между ними. Новые intents сохранять как pending, запускать после commit. Не использовать для критической части `try ensureCurrent` после первого install с выходом без отката.
- [ ] Только после обеих установок менять `activeConfig`, `activeRuntime`, session config и available state. Проверить app shutdown в этой фазе, failed save до install и отказ candidate prepare. Если используется rollback, сохранить обе прежние services до окончательного commit, не полагаться на background retirement прежнего router entry.
- [ ] Данные session descriptor, allowedLanguages, prompt и editor selection снимать в начале записи/draft и file-job. Меню может менять desired config, но текущая операция использует неизменный снимок.
- [ ] Удалять нулевые inFlight entries после endUse, проверять prepare/tokenCount/reload ownership при retirement. Не допускать stop сервиса во время его активного вызова.
- [ ] Green executable/routers/session; коммит `fix: serialize runtime activation with session ownership`.

## Задача 2 — Реальная revalidation credentials/model prerequisites

**Файлы:** AppRuntimeCoordinator, AppDelegate, RuntimeServiceFactory, `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift`; tests AppRuntimeCoordinatorTests.

**Интерфейс:** добавить `enum RuntimeRevalidationReason { case credentials(provider: String); case model(id: String); case retry }` и `revalidateDesiredConfiguration(reason:)`. Секрет не является частью reason, selection или telemetry. Внутренние force-флаги определяют, какие services должны готовиться заново даже при равной selection.

- [ ] Перенести `revalidationRebuildsActiveClient`. Дополнительно: активный Gemini editor без cloud STT; общий Gemini key для STT/editor; OpenAI key не пересоздаёт несвязанный local Qwen; удаление ключа; изменение во время записи; superseded credential generation.
- [ ] В fast path учитывать forced preparation:

```swift
let needsTranscriber = forceTranscriber || previousSelection?.sttBackend != desired.sttBackend
    || previousSelection?.sttModelID != desired.sttModelID
let needsEditor = forceEditor || previousSelection?.editorEnabled != desired.editorEnabled
    || previousSelection?.editorBackend != desired.editorBackend
    || previousSelection?.editorModelID != desired.editorModelID
```

- [ ] Если ключ изменён, новый клиент получает актуальный Keychain/env value. После удаления не продолжать скрыто обращаться старым ключом: завершить текущую activity согласно cancellation policy, затем деактивировать соответствующий cloud компонент с понятным recovery. Local STT может остаться рабочим.
- [ ] При model revalidation готовить только затронутый runtime; initial missing-model recovery должен продолжать работать. Тесты не обращаются к Keychain, используются fake credential generations.
- [ ] Green app/editor/transcriber suites; коммит `fix: rebuild affected clients after credential changes`.

## Задача 3 — Транзакция языка и prompt

**Файлы:** MenuBarController, AppLaunchCoordinator, AppRuntimeCoordinator, DictionaryCoordinator, `Packages/CNSUI/Sources/CNSUI/LanguagePicker.swift`, SessionController; локали при новых сообщениях; tests MenuStructure/MenuState/AppRuntimeCoordinator/DictionaryCoordinator.

**Интерфейс:** создать общий чистый reducer `LanguageSettings` в `Packages/CNSCore/Sources/CNSCore/LanguageSettings.swift`: `selectPrimary(_ language: String, in config: Config) -> Config`, `toggleAdditional(_ language: String, in config: Config) -> Config`, `setAutoDetect(_ enabled: Bool, in config: Config) -> Config`. Дедупликация через LanguageCode, без unordered Set как выходного списка.

- [ ] Перенести `languageChangeRebuildsPrompt`. Добавить `auto → explicit primary` со значением auto=false; выключение/включение дополнительного языка обновляет prompt; uk/ua нормализация; выбранный primary исключён из дополнительных.
- [ ] Чистый reducer делает согласованный config:

```swift
var updated = config
updated.raw["primary_language"] = .string(LanguageCode.normalize(language))
updated.raw["language_auto_detect"] = .bool(false)
updated.raw["additional_languages"] = .array(
    LanguageCode.dedupeList(updated.additionalLanguages, primary: updated.primaryLanguage).map(JSONValue.string)
)
updated.raw["initial_prompt"] = .string(InitialPromptBuilder().build(config: updated.raw))
return updated
```

- [ ] Через владельца config атомарно записать языки/prompt и синхронизировать активные `.txt`. Menu handlers передают intents/reduced config; они не записывают файлы самостоятельно. Watcher не должен принять собственную запись как ручное изменение.
- [ ] Применять языковые настройки на следующем draft/file-job; текущая сессия использует snapshot из задачи 1. Тест смены языка между первым и финальным chunk проверяет единый request context.
- [ ] Локализацию обновлять согласованно: menu и вновь открываемые панели/session strings получают новый I18n, либо сохранить текущую UI locale и явно сообщить необходимость restart. Предпочтительно обновлять через отдельный UI locale snapshot, не путать язык распознавания с состоянием старого открытого draft. Зафиксировать выбранное поведение в тесте первого launch с выбором другого языка.
- [ ] Green Core/Dictionary/UI/Session/app; коммит `fix: apply language and prompt changes coherently`.

## Задача 4 — Все операции local inference под одним lifecycle-контрактом

**Файлы:** `WhisperCppTranscriber.swift`, `GuardedTranscriber.swift`, `LocalAiEditor.swift`, `InferenceExecutionGate.swift`, SessionController, RuntimeServiceFactory; tests InferenceExecutionGate/LocalAiEditor/GuardedTranscriber/OverdueWatchdog.

**Интерфейс:** shared gate покрывает loading, prepare/warmup, decode/generate и освобождение GPU ресурсов. Не брать второй lease рекурсивно: внутри engine разделить публичные acquire-методы и приватные методы, требующие уже взятый lease.

- [ ] Написать barrier-тесты с fake local generator: refine вернул timeout, underlying operation ещё выполняется; одновременно вызваны preWarm, prepare другого runtime и stop. Максимум одна GPU-операция; lease освобождается только при фактическом выходе работы.
- [ ] `warmupIfIdle` использует effective idle из эпохи 02 и отклоняется при file-job/reconfiguration. При начале записи queued synthetic work отменяется/откладывается, реальный chunk не стоит за ненужным prepare.
- [ ] Для синтетического прогрева достаточно попытки `tryAcquire`; если busy — `.skipped`, а не ложное success. Возвращать typed результат prewarm и передавать его в healthMonitor вместо жёсткого `success: true`.
- [ ] При local memory pressure подключить одно throttled notification через UserNotificationService; cloud редактор не пропускать по состоянию локальной памяти. Сохранить raw draft при любом отказе редактора.
- [ ] Fault injection: collaborator игнорирует cancel/abort навсегда. Session прекращает принимать новые операции и сохраняет draft, shutdown/recovery возвращает bounded outcome. Кооперативный callback не выдавать за возможность убить зависший C/Metal вызов.
- [ ] По результатам fault injection зафиксировать в этой эпохе решение: допустим ли понятный recovery/restart приложения, или для требуемой гарантии восстановления нужен отдельный inference helper process. Если принят helper, отдельный implementation plan должен определить IPC, parent-death watchdog, data ownership и тест kill/restart; до его реализации соответствующий release gate остаётся blocked, а не «closed by actor».
- [ ] Green mock suites; затем существующие opt-in real-model gates на явных тестовых путях. Коммит `fix: coordinate local inference lifecycle and recovery`.

## Задача 5 — Смена аудиоустройства и наблюдаемая ошибка capture

**Файлы:** `Packages/CNSAudio/Sources/CNSAudio/AudioRecorder.swift`, `StreamCloseWatchdog.swift`, CNSCore SessionProtocols, SessionController; создать `Packages/CNSAudio/Tests/CNSAudioTests/AudioRecorderLifecycleTests.swift`.

**Интерфейс:** выделить injectable audio-engine adapter для start/removeTap/stop/format/configuration-change; ошибки отсутствующего input/converter должны быть типизированы и передаваться в session, а не превращаться в молчаливый `return` tap.

- [ ] Fake format sampleRate=0/channels=0 и converter failure: start возвращает controlled error, tap не устанавливается. Добавить start→configuration changed→stop, repeated stop и late tap из прежней generation.
- [ ] До установки tap проверять валидные input dimensions и создание converter. На configuration change остановить приём этой generation, выполнить quiescence/drain, сохранить partial draft с предупреждением; повторный start использует новую graph.
- [ ] Не выполнять тяжёлую пересборку graph в audio callback; tap ограничен конвертацией/кольцевым буфером и короткими синхронизациями. StreamCloseWatchdog должен охватывать потенциально зависающие этапы teardown, а не только последнюю `engine.stop`.
- [ ] После mock gate выполнить ручной disconnect/reconnect/sleep/wake по согласованной hardware matrix на тестовой записи. Реальный проход не подменять fake green.
- [ ] Green CNSAudio/Session; коммит `fix: recover recording after audio device changes`.

## Выход эпохи

- [ ] Runtime не меняется посередине draft/file-job, ключи обновляют реальные клиенты, языки соответствуют effective prompt.
- [ ] Все пять исходных runtime probes стали проходящими постоянными регрессиями вместе с epoch-01 тестами.
- [ ] Mock lifecycle проверки завершены; реальный GPU/hardware статус записан отдельно. Общий Swift gate проходит.
