# Эпоха 04. Предсказуемый откат терминов

> Для исполнителя: `executing-plans`; сначала 00-PLAN.md и завершённая эпоха 03.

**Цель:** откат действует на последнюю содержательную операцию нужного языка и сообщает, когда откатывать нечего.

**Архитектура:** продолжить использовать `prompt_snapshots` schema 10. Снимать состояние один раз на язык перед транзакцией; без изменений runtime-ownership, metrics и durable replacement policy.

**Стек:** Swift 6, JSONObject, DictionaryCoordinator, существующий atomic commit/prompt synchronizer.

**Спецификация:** C04; все вложенные команды словаря, влияющие на термины.

## Файлы

- Изменить `Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift`.
- Создать `Packages/CNSDictionary/Sources/CNSDictionary/TermUndoPolicy.swift`.
- Дополнить `Packages/CNSDictionary/Tests/CNSDictionaryTests/DictionaryCoordinatorTests.swift`; создать `TermUndoPolicyTests.swift` рядом.
- Изменить `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift`, `TermsPanel.swift`, `SuggestionsPanel.swift` только для доступности/ошибок/выбора языка.
- Дополнить `Packages/CNSUI/Tests/CNSUITests/UIPanelsTests.swift`, `MenuStructureTests.swift`.
- Изменить шесть локалей.

## A. Снимок операции, включая пустое состояние

Содержательная операция: manual add, edit, delete, reactivate, импорт текста, принятие одного/набора кандидатов, auto-add набора. Не создавать undo для duplicate/no-op/ошибки записи, изменения метрик, счётчиков использования, режима auto-update или одного отказа от кандидата.

Предлагаемая точка интеграции в DictionaryCoordinator:

```swift
private func commitTermMutation(
    _ candidate: Config,
    languages: Set<String>,
    invalidations: DictionaryInvalidations
) throws {
    var candidate = candidate
    TermUndoPolicy.capturePreviousTerms(
        from: snapshot,
        into: &candidate,
        languages: languages
    )
    try commit(candidate, promptLanguages: languages, invalidations: invalidations)
}
```

`capturePreviousTerms(from:into:languages:)` сравнивает массивы user_terms и записывает прежний массив только для реально изменившихся языков. Не перезаписывает другие prompt_snapshots. Вызов один раз перед commit, а не внутри `addCandidate`.

- [ ] Добавить красные тесты: пустой словарь → add → revert возвращает пустой; два термина → delete → revert восстанавливает удалённый; пакет из трёх предложений → один revert убирает все три.
- [ ] Перевести перечисленные операции на commitTermMutation. Для multi-language транзакции снимок каждого затронутого языка берётся из исходного snapshot до всех добавлений.
- [ ] Убрать `!previous.isEmpty` в guard revert; различать отсутствующий ключ и `.array([])`. Продолжить нормализацию legacy string-элементов без потери unknown metadata.
- [ ] Сам revert вызывает обычный commit и меняет предыдущий/current массивы местами. Повторный откат возвращает отменённое состояние; в UI пояснить, что доступен один переключаемый шаг, а не история undo/redo.
- [ ] Не изменять `manual_replacements`, `approved_auto_replacements`, `rejected_replacements`, dataset/history, режимы и языки. Принятие предложения отменяется в user_terms; не возрождать ранее обработанное предложение в pending_suggestions неявно.
- [ ] Для терминов, существующих и до, и после отката, сохранить более новые `use_count`/`last_seen` по canonical identity. Вернуть source/inactive/content из выбранного снимка. Удалённым и возвращённым терминам оставить сохранённые метаданные снимка.
- [ ] Ошибка atomic config/prompt write оставляет snapshot, undo и исходные файлы неизменными. Использовать существующий rollback commit, не вводить второй независимый writer.

Минимальный тест с существующим fixture в DictionaryCoordinatorTests:

```swift
func testAddingFirstTermCanRevertToEmptyDictionary() throws {
    let paths = makePaths()
    let coordinator = makeCoordinator(config: makeConfig(), paths: paths)
    XCTAssertTrue(coordinator.addManualTerm("SwiftUI", language: "en"))
    try coordinator.revert(language: "en")
    XCTAssertEqual(UserTerms.activeTerms(coordinator.snapshot, lang: "en"), [])
}
```

Использовать существующую политику cleanup временного fixture. До исправления тест падает на noSnapshot; после — проверяет результат и повторное чтение config.

## B. Меню и панель объясняют границы отката

- [ ] Добавить `DictionaryCoordinator.canRevert(language: String) -> Bool`, учитывающий пустой снимок как валидный.
- [ ] «Откатить термины…» открывает небольшой выбор языка с доступным снимком и кнопками «Откатить»/«Отмена». Предвыбор — основной язык, если снимок есть. Не выполнять молча откат только primary.
- [ ] Если снимков нет, пункт отключён; в TermsPanel соответствующая кнопка также отключена. Для ситуации, когда снимок исчез после открытия диалога, показать «Нет сохранённого состояния для отката».
- [ ] В TermsPanel режим фильтра «Все языки» не означает откат всех языков без выбора. Открывать тот же chooser. При несохранённом редактировании эпоха 03 должна показать конфликт или сохранить ввод, а не очистить его.
- [ ] Режим suggest/auto/disabled сохранить. «Просмотреть предложения» при auto явно сообщает «В автоматическом режиме новые термины добавляются сразу»; операция анализа остаётся существующей, но не выдаёт автодобавление за список на одобрение.
- [ ] Ошибки `setPromptUpdateMode` и `runPromptAnalysis(onDemand:)` показывать через локализованный failure state. Сейчас catch только пишет log; failed analysis не должен выглядеть как успешный пустой список. Галочка режима остаётся на последнем сохранённом значении. Добавить fake write/analysis failures и проверку повторной попытки.
- [ ] Сохранить pending selection, массовое принятие/отклонение и durable tombstones в replacements.

Матрица тестов: add/edit/delete/reactivate/import/accept one/accept many/auto batch; en+ru пакет и независимый откат; empty snapshot; legacy strings; no-op; failed write; usage обновлён после edit; undo после метрик; отмена chooser; stale noSnapshot; replacement tombstone побайтно/семантически сохранён.

## Проверки

```bash
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSDictionary
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSUI
source venv/bin/activate && swift test --disable-index-store --package-path ClickNSpeak
```

- [ ] Коммит: `fix: make dictionary undo cover term transactions`.
- [ ] Проверить изолированный config после перезапуска процесса: доступный снимок сохраняется, не возникает новая обязательная миграция.

**Готово:** каждый вид содержательной операции имеет working regression; один пакет — один снимок на язык; пустой словарь восстанавливается; UI не скрывает ошибки; ownership/invalidation tests зелёные.
