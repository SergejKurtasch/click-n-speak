# Эпоха 01 — Сохранность данных и владение конфигурацией

> Для исполнителя: использовать `executing-plans`; выполнять задачи последовательно и отмечать флажки. Не выполнять остальные эпохи в рамках этого файла.

**Цель:** закрыть R01/R02, ограничить стоимость анализа длинных подтверждений и сохранить изменения словаря при асинхронных операциях.

**Архитектура:** DictionaryCoordinator остаётся владельцем словарных изменений. Runtime получает уведомления об актуальных данных без обратного объявления их сохранёнными. Ошибка чтения существующего config блокирует создание любых пишущих сервисов.

**Стек:** CNSCore, CNSDictionary, ClickNSpeak, Swift Testing/XCTest.

**Спецификация:** [00-REVIEW-AND-PLAN.md](00-REVIEW-AND-PLAN.md), R01/R02, технический долг 3–4. Все глобальные ограничения оттуда обязательны.

## Задача 1 — Не заменять повреждённый config дефолтом

**Файлы:** изменить `Packages/CNSCore/Sources/CNSCore/Config.swift`, `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`; при необходимости создать `ClickNSpeak/Sources/ClickNSpeak/ConfigRecoveryCoordinator.swift`; тесты — `Packages/CNSCore/Tests/CNSCoreTests/CoreServicesTests.swift`, `ClickNSpeak/Tests/ClickNSpeakTests/AppDelegateStartupTests.swift`; сообщения — все файлы `locales/*.json`.

**Интерфейс:** добавить `public static func loadValidated(from url: URL) throws -> Config`. Отсутствующий файл возвращает мигрированный default; существующий unreadable/invalid/non-object JSON вызывает ошибку. Старый `load` оставить для совместимости тестовых утилит, но production startup и menu reload перевести на checked API.

- [ ] Перенести `startupPreservesCorruptConfig` из `scripts/review_swift_20260907/RuntimeAuditProbes.swift` в startup tests. Проверять реальную launch-последовательность после изменения API, а не вручную создавать координатор с дефолтом в обход нового load guard.
- [ ] Добавить cases: missing → defaults; malformed → исходные байты сохранены; root array → ошибка; unreadable → ошибка, отличная от missing; migration v1–v10 сохраняет unknown fields и replacement decisions. Тест ошибка→bootstrap должен проверять отсутствие history/index/prompt writes.
- [ ] Выполнить red: `source venv/bin/activate && swift test --disable-index-store --package-path ClickNSpeak --filter startupPreservesCorruptConfig`.
- [ ] Реализовать checked loader, например:

```swift
public static func loadValidated(from url: URL) throws -> Config {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return migrated(JSONObject())
    }
    let value = try JSONValue.parse(data: data)
    guard case let .object(object) = value else {
        throw LoadError.decode("Configuration root must be an object")
    }
    return migrated(object)
}
```

- [ ] В AppDelegate выполнять checked load **до** `prepareDictionaryConfiguration`, startPromptWatching, timers и activateInitial. В catch показать восстановительный UI: открыть исходник, выбрать существующую резервную копию, повторить чтение. До явного восстановления исходник не переписывать. Не логировать JSON/content ошибки парсера.
- [ ] Сначала проверить выбранную backup и её миграцию в памяти; только после пользовательского выбора сохранять атомарно и возобновлять startup. Создание нового default поверх повреждённого файла допускается лишь отдельным действием после сохранения исходных байтов в backup.
- [ ] Выполнить green обоих targets и `source venv/bin/activate && python -m pytest -q tests/parity`. Зафиксировать `fix: preserve invalid configuration during startup`.

**Приёмка:** broken config остаётся byte-for-byte прежним после попытки запуска; приложение не теряет rejected replacements, не притворяется новым пустым профилем и остаётся способным показать ошибку.

## Задача 2 — Разделить изменение snapshot и подтверждение записи

**Файлы:** `DictionaryCoordinator.swift`, `AppRuntimeCoordinator.swift`, `AppDelegate.swift`; тесты `DictionaryCoordinatorTests.swift`, `AppRuntimeCoordinatorTests.swift`, `AppDelegateStartupTests.swift` в их существующих targets.

**Интерфейсы:** добавить `AppRuntimeCoordinator.updateDictionarySnapshot(_ config: Config)` для уведомления о данных; он не вызывает `onConfigActivated`, не сохраняет файл и не отменяет выбранный pending backend. `DictionaryCoordinator.adoptConfiguration` использовать только для действительно сохранённой внешней конфигурации. Публикация history/metrics без `.config` не должна проходить по маршруту принятия полной config.

- [ ] Перенести `dirtyUsageSurvivesCoordinatorRoundTrip` и сохранить в нём callback wiring, эквивалентный production. Ожидаемые значения: use_count 0→1, fresh last_seen, inactive снят, после flush/reload значения совпадают.
- [ ] Добавить interleaving: смена backend ожидает idle, завершается запись history/usage предыдущей сессии — desired backend должен сохраниться. Ещё: применение menu setting не откатывает новый термин; отказ записи оставляет dirty=true; повторный flush сохраняет ровно актуальный snapshot.
- [ ] Выполнить red: `source venv/bin/activate && swift test --disable-index-store --package-path ClickNSpeak --filter dirtyUsageSurvivesCoordinatorRoundTrip`.
- [ ] Заменить безусловный app callback на маршрутизацию по invalidations:

```swift
dictionaryCoordinator.onSnapshotChanged = { [weak self] updated, invalidations in
    guard let self else { return }
    if invalidations.contains(.config) {
        self.runtimeCoordinator?.updateDictionarySnapshot(updated)
        self.updateDesiredMenuConfig(updated)
    }
    if invalidations.contains(.history) {
        self.menuController?.refreshHistory(reset: true)
    }
}
```

- [ ] В `updateDictionarySnapshot` копировать dictionary-owned поля в active/desired snapshots с сохранением pending runtime selection. Явный набор полей: `user_terms`, `initial_prompt`, `prompt_snapshots`, `pending_suggestions`, `skipped_terms`, `prompt_update_mode`, `last_analysis_phrase_count`, `last_decay_run_ts`, `last_metrics_snapshot_ts`, `last_metrics_notification_ts`, `manual_replacements`, `approved_auto_replacements`, `rejected_replacements`, `replacement_policy_initialized`. Добавлять изменяемые пороги анализа/notify settings через тот же контракт, не неявной заменой всего config.
- [ ] Не присваивать `dirty = false` при возврате собственного snapshot. Сбрасывать dirty исключительно после успешной записи соответствующей версии. Для menu commit сначала объединять самые свежие dictionary данные и только затем сохранять; история/usage callback не должны менять generation runtime.
- [ ] Сохранить тест, что shutdown flush после recordConfirmation действительно завершён, используя await/drain, который будет добавлен в эпохе 02. В этой эпохе проверить явный await confirmation→flush.
- [ ] Выполнить green Dictionary + executable и зафиксировать `fix: preserve dirty dictionary updates across runtime callbacks`.

**Приёмка:** usage живёт после restart; публикация истории не отменяет смену модели и не превращает unsaved данные в persisted. На одну транзакцию остаётся один владелец записи.

## Задача 3 — Ограничить анализ и отвергать устаревшие результаты

**Файлы:** `Packages/CNSDictionary/Sources/CNSDictionary/CorrectionAnalyzer.swift`, `DictionaryCoordinator.swift`, `Metrics.swift`; тесты `CorrectionAnalyzerTests.swift`, `DictionaryCoordinatorTests.swift`.

**Интерфейсы:** внутренний revision `UInt64` в DictionaryCoordinator, увеличиваемый при изменении терминов, языков, skipped/mode. `runPromptAnalysis` снимает revision перед await и повторно проверяет candidates на текущих terms/skipped/mode перед commit. Запись metrics history направить в существующий `DictionaryPersistenceWorker`, добавив `appendMetrics(_ metrics: JSONObject, now: Date) throws -> [JSONObject]` с типом результата, согласованным с текущим `Metrics.loadHistory`.

- [ ] Добавить тест: suspend analyze → reject candidate → finish analyze; candidate не появляется снова. Повторить со сменой primary/additional и `suggest → disabled`.
- [ ] Добавить тест с длинной парой: 10 000 одинаковых tokens и одно изменение в середине. Проверять корректную пару и bounded workspace алгоритма; не привязывать тест к точным миллисекундам конкретного Mac.
- [ ] До DP обрезать общий prefix/suffix; вычислять diff для оставшегося окна. Для большого окна использовать алгоритм с линейной памятью либо строгий лимит числа ячеек с отказом **только от обучения этой пары**, сохраняя подтверждённый текст/history/dataset. Начальный лимит — 1 000 000 ячеек; telemetry outcome `analysis_limit` без слов пользователя.

```swift
let cellCount = (remainingSource.count + 1).multipliedReportingOverflow(
    by: remainingTarget.count + 1
)
guard !cellCount.overflow, cellCount.partialValue <= 1_000_000 else {
    return []
}
```

- [ ] Для полного совпадения не выделять матрицу; для отказа не создавать отрицательные/пустые replacement observations. На длинных unrelated текстах учесть оба обхода raw/final и editor/final.
- [ ] Metrics append и correction writes сериализовать одним worker; тест двух одновременных запросов Statistics/maintenance не должен терять строку и нарушать timestamp policy.
- [ ] Проверки: `source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSDictionary`; затем общий `bash scripts/swift_verify.sh` из активированного venv. Коммит `fix: bound dictionary analysis and reject stale candidates`.

## Выход эпохи

- [ ] R01/R02 закрыты регрессиями, существующие compatibility fixtures проходят.
- [ ] Ни один новый сценарий не трогает production data и не ослабляет replacement tombstones.
- [ ] Полный Swift gate и Python parity проходят; результаты записаны в чат. Обновить только фактически изменившиеся архитектурные инварианты в AGENTS.md после коммита.
