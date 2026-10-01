# Эпоха 07 — перечитывание аудионастроек для следующей записи

> Для исполнителя: применять `executing-plans`; читать 00-PLAN.md и выполнять только эту эпоху. Глобальные ограничения из общего плана обязательны, флажки отмечать по факту.

**Цель:** команда перечитывания действительно применяет поддерживаемые параметры нарезки; текущая запись остаётся на своём снимке настроек.

**Архитектура:** валидируемый RecordingSettings в CNSCore передаётся в AudioCapturing при старте каждой записи. CNSAudio преобразует его в ChunkingConfig внутри новой capture generation. Общий Config проверяется до любого внешнего adoption.

**Стек:** Swift, AVFoundation, существующие fake audio engine и session doubles.

**Спецификация:** [00-PLAN.md](00-PLAN.md), C07; после эпохи 02. Блок A — контракт и валидация, B — подключение записи и reload.

## Исходная проблема

AppDelegate один раз создаёт `ChunkingConfig` и `AudioRecorder`. В recorder это `private let config`; каждое начало берёт старые значения. `SessionController.updateConfig` обновляет session config, но не настройки recorder. Внешний reload при этом может выглядеть успешным.

Четыре поддерживаемых поля: `silence_duration`, `target_speech_duration`, `max_speech_duration`, `min_speech_duration`. Частота 16 kHz, параметры VAD, размеры очередей и audio-device routing этой эпохой не превращаются в пользовательские настройки.

## Файлы

Изменить:

- `Packages/CNSCore/Sources/CNSCore/Config.swift` и `SessionProtocols.swift`.
- `Packages/CNSAudio/Sources/CNSAudio/AudioRecorder.swift` и `AudioChunker.swift`.
- `Packages/CNSSession/Sources/CNSSession/SessionController.swift`.
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift` и `AppRuntimeCoordinator.swift`.
- `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift`.
- `Packages/CNSSession/Tests/CNSSessionTests/SessionDoubles.swift` и `SessionControllerTests.swift`.
- `Packages/CNSAudio/Tests/CNSAudioTests/AudioChunkerTests.swift` и `AudioRecorderLifecycleTests.swift`.
- `ClickNSpeak/Tests/ClickNSpeakTests/AppDelegateStartupTests.swift` и `AppRuntimeCoordinatorTests.swift`.
- `locales/{ru,en,uk,de,es,fr}.json`.

Создать:

- `Packages/CNSCore/Sources/CNSCore/RecordingSettings.swift`.
- `Packages/CNSCore/Tests/CNSCoreTests/RecordingSettingsTests.swift`.
- `ClickNSpeak/Tests/ClickNSpeakTests/ConfigurationReloadTests.swift`.

## Блок A — единый валидируемый снимок

- [ ] Воспроизвести stale settings: два старта recorder, между ними изменение session config; fake фиксирует одинаковые старые пороги. Проверять фактические границы chunker на синтетических speech/silence frames, а не только новое значение поля.
- [ ] Добавить immutable `RecordingSettings: Sendable, Equatable` с четырьмя `Double`: silenceDuration, targetSpeechDuration, maxSpeechDuration, minSpeechDuration; `init(config: Config) throws` и явный initializer четырёх значений с теми же проверками.
- [ ] Отсутствующий ключ получает прежний default 1/4/8/1. Присутствующий ключ неправильного типа, null, нечисловая строка, nonfinite или недопустимая комбинация отклоняется. Не подменять явно ошибочный ввод default-значением.
- [ ] Правило проверки: silence > 0; target > 0; 0 ≤ min ≤ target ≤ max; все значения конечны. Не добавлять произвольный верхний предел, не связанный с текущим алгоритмом. Если реальные поддерживаемые fixtures требуют иной границы, сохранить совместимость и зафиксировать причину тестом.
- [ ] Ошибка `RecordingSettingsError` содержит имя поля или вид нарушенной связи; не содержит весь JSON, prompt, ключи или текст пользователя. Перечислить typed cases для invalidType(field), nonFinite(field), nonPositive(field), invalidOrdering.
- [ ] В `Config.init(validating:)` после миграции выполнять эту валидацию. Поэтому startup, menu reload и backup recovery применяют одинаковую проверку до dictionary bootstrap/restore. `Config.load` остаётся legacy utility, не становится runtime-путём.
- [ ] Проверять settings также на входе программного внешнего adoption, где Config мог быть создан напрямую без `init(validating:)`. В AppDelegate проверка должна предшествовать `DictionaryCoordinator.adoptPersistedConfiguration`.
- [ ] Сохранить неизвестные JSON-поля и schema 10. Ошибка загрузки не переписывает исходный файл и не запускает repair словаря/промпта.

Тесты A: defaults; все четыре изменённых значения; integer JSON как допустимое число; wrong type/null; zero/negative/nonfinite; нарушение min/target/max; валидная пограничная равенство target=max; неверный config с одновременно изменёнными user_terms не меняет словарь/prompt/runtime; неверный backup не становится восстановленным config.

**Граница A:** валидация подключена, нынешний recorder пока использует прежний init config. Проверки Core/App проходят. Коммит: `feat: validate recording settings before config adoption`.

## Блок B — настройки на границе записи

- [ ] Изменить требование `AudioCapturing` в `SessionProtocols.swift` на `start(callbacks: AudioCallbacks, settings: RecordingSettings) async throws`. Все production conformers и test doubles обязаны принять настройки; не добавлять default implementation, которая их молча игнорирует.
- [ ] При необходимости сохранить старую concrete-перегрузку `AudioRecorder.start(callbacks:)` для utility/tests, явно делегирующую новым settings из initializer. Production Session использует только новый контракт.
- [ ] Добавить `ChunkingConfig.init(settings:)`; sampleRate остаётся 16000. Не менять формат AVAudioEngine/ring buffer при каждом reload.
- [ ] В SessionController снять RecordingSettings из принятого session config синхронно при создании recording generation, до первого await отмены prewarm/звука старта. Передать immutable значение в recorder.start.
- [ ] В AudioRecorder назначать `state.chunker = AudioChunker(config: ...)` под существующим stateLock только при создании новой generation. Не менять chunker, callbacks, converter или накопленные samples работающей записи.
- [ ] Повторный hotkey для append создаёт новую recording segment с актуальными настройками; предыдущие сегменты и общий PopupDraft сохраняются. Не переписывать target PID и provenance старых сегментов.
- [ ] Сохранить границу принятия config через AppRuntimeCoordinator. Если внешний reload содержит также смену backend, session получает согласованный config согласно существующей транзакции, а не отдельную раннюю аудио-мутацию.
- [ ] Удалить дублирующее ручное чтение четырёх raw fields из AppDelegate. Для startup использовать тот же RecordingSettings parser.
- [ ] Уточнить результат команды: поддерживаемые параметры записи применятся при следующем старте; интерфейсный язык требует перезапуска. Не обещать live-применение любого произвольного JSON-ключа.
- [ ] Сохранить команды открытия config/log: открыть существующий файл, создать только отсутствующий разрешённый файл, показать ошибку недоступности. Не перезаписывать повреждённый config при попытке его открыть.

Сквозная матрица B:

| Сценарий | Проверка |
|---|---|
| Reload в idle | Следующая запись передаёт все четыре новых значения и меняет ожидаемые границы chunks |
| Reload в recording | Текущие границы прежние; следующая запись новые |
| Reload во время ожидающего старта | Начатая generation сохраняет snapshot, следующая получает обновление |
| Append после reload | Новый сегмент получает новые настройки; старый текст/target сохраняются |
| Reload вместе с backend/model | Нет половинной активации; pending/failed сохраняет прежний рабочий snapshot |
| Невалидный JSON/пороги | Ошибка видна, никакие части внешнего config не adopted |
| Неудачный первый start | Retry использует целостный snapshot; tap и generation не зависают |
| Смена устройства после reload | Работает прежняя защита format snapshot и rebuild следующего старта |

## Проверки и завершение

```bash
source venv/bin/activate
swift test --package-path Packages/CNSCore
swift test --package-path Packages/CNSAudio
swift test --package-path Packages/CNSSession
swift test --package-path Packages/CNSUI
swift test --package-path ClickNSpeak
```

- [ ] Найдены и обновлены все `AudioCapturing` conformers и `recorder.start` calls; компилируется весь затронутый граф пакетов.
- [ ] Новая проверка значений не ломает существующие parity fixtures и config recovery.
- [ ] Нет нового UI-доступа из audio callback и нет мутаций chunker извне capture generation.
- [ ] Коммит B: `fix: apply reloaded audio settings to the next recording`; обновить AGENTS.md.

**Готово, когда:** тесты подтверждают изменение реального chunking следующей записи, а не только обновление config в памяти.
