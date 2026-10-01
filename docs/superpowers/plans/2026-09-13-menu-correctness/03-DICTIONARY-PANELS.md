# Эпоха 03. Черновики словаря и ошибки статистики

> Для исполнителя: `executing-plans`; прочитать 00-PLAN.md. Схему undo меняет эпоха 04, не эта.

**Цель:** введённые правки не исчезают из-за фоновых публикаций; ошибки статистики видны.

**Архитектура:** черновики принадлежат существующему panel-scoped view model. Refresh объединяет новые данные с черновиком, а сохранение остаётся транзакцией DictionaryCoordinator. Для статистики ввести явное состояние представления.

**Стек:** Swift 6, SwiftUI, AppKit; текущие DictionaryCoordinator и Metrics.

**Спецификация:** C03, пункты 7 «Термины», «Замены», «Статистика».

## Файлы

- Создать `Packages/CNSUI/Sources/CNSUI/TermDraftStore.swift` и `Packages/CNSUI/Tests/CNSUITests/TermDraftStoreTests.swift`.
- Изменить `Packages/CNSUI/Sources/CNSUI/TermsPanel.swift`, `ReplacementsPanel.swift`, `MenuBarController.swift`.
- Изменить `Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift`, его `DictionaryCoordinatorTests.swift` и `Packages/CNSUI/Sources/CNSUI/UIErrorLocalization.swift` для различения duplicate и persistence failure при Add.
- Создать `Packages/CNSUI/Sources/CNSUI/StatisticsPresentationState.swift` и `Packages/CNSUI/Tests/CNSUITests/StatisticsPresentationTests.swift`.
- Дополнить `Packages/CNSUI/Tests/CNSUITests/UIPanelsTests.swift`.
- Изменить `locales/{ru,en,de,uk,es,fr}.json`.

## A. Сохранение черновиков при refresh

Предлагаемый небольшой тип для нового файла:

```swift
struct TermDraft: Equatable {
    let baseline: String
    var text: String
    var remote: String?
    var isDirty: Bool { text != baseline }
    var hasConflict: Bool { isDirty && remote != baseline }
}
```

`TermDraftStore` хранит `[String: TermDraft]` по существующему ID строки и предоставляет `reconcile(_ values: [String: String])`, `setText(_ text: String, for id: String)`, `draft(for id: String) -> TermDraft?`, `acceptRemote(for id: String)`. Отсутствие ключа в свежих values означает удаление строки извне.

- [ ] Добавить регрессию на текущую цепочку: открыть TermsPanel, ввести правку существующего термина, вызвать `MenuBarController.apply` с изменёнными permissions/download/history. Текст правки должен остаться. Использовать внутренний view model/test seam, а не UI-события реальной мыши.
- [ ] Реализовать reconcile: чистые строки принимают новые значения; грязные сохраняют text; удалённая грязная строка остаётся видимой как конфликт; чистая удалённая строка исчезает. Новые строки получают baseline=text=remote.
- [ ] Убрать безусловный `load(resetDrafts: true)` из TermsPanel.refresh и refreshForPresentation. Не очищать newTerm, search/filter или текст при возвращении в окно.
- [ ] На Save сверить baseline с актуальной строкой координатора. При конфликте показать «Термин изменён в другом месте» либо «Термин удалён». Кнопка «Загрузить сохранённое» сбрасывает именно эту строку. Для удалённой строки предложить явное «Добавить как новый»; не воскрешать её автоматически.
- [ ] После успешного сохранения сбросить черновик только сохранённой строки. Не терять изменения других строк при Save/Delete/Add/Revert одной строки.
- [ ] Устранить неоднозначность Add: нынешний `addManualTerm` возвращает false и для duplicate, и для ошибки записи, а панель всегда показывает duplicate. Добавить `addManualTermValidated(_ term: String, language: String) throws -> Bool`: false только для существующего термина/no-op, invalidTerm и persistence errors бросаются. Существующий Bool-wrapper сохранить для совместимости остальных клиентов; панель использует throwing-вариант и UIErrorLocalization. В тесте disk failure не очищает newTerm и не отображается как дубликат.
- [ ] Применить то же правило к fromDrafts/toDrafts ReplacementsPanel: сейчас фоновый load сохраняет их, но успешный perform и refreshForPresentation очищают все. Убрать сброс при повторном открытии, сохранить состояние раскрытых секций и очищать только сохранённую строку. Не менять правила разрешения автоматических замен.
- [ ] Сохранить стабильность selection/caret через неизменные IDs SwiftUI-строк; обновление unrelated metadata не должно пересоздавать редактируемую строку.

Минимальный тест нового store:

```swift
@Test func dirtyTextSurvivesUnchangedRemote() {
    var store = TermDraftStore()
    store.reconcile(["en|swift": "Swift"])
    store.setText("SwiftUI", for: "en|swift")
    store.reconcile(["en|swift": "Swift"])
    #expect(store.draft(for: "en|swift")?.text == "SwiftUI")
    #expect(store.draft(for: "en|swift")?.hasConflict == false)
}
```

Добавить сценарии: remote изменён при dirty; remote удалён при dirty; чистая строка обновлена; Save одной из двух dirty-строк; неудачное сохранение; закрытие и повторное открытие панели; 100 unrelated menu publications. В интеграционных тестах использовать реальные TermsViewModel/DictionaryCoordinator на временном config.

## B. Статистика не маскирует ошибку нулями

```swift
enum StatisticsPresentationState {
    case idle
    case loading(UUID)
    case ready(UUID, JSONObject)
    case failed(UUID)
}
```

- [ ] Добавить failure regression: внедрённый compute closure бросает ошибку → появляется failure presentation, `presentStatistics(JSONObject())` не вызывается.
- [ ] Выделить запрос статистики с собственным requestID и замыканием `() async throws -> JSONObject`. Production вызывает `DictionaryCoordinator.computeMetricsForPresentation()`.
- [ ] При loading показать понятное состояние; при failed — «Не удалось получить статистику», «Повторить», «Закрыть». Нулевые значения допустимы только в настоящем успешном metrics snapshot.
- [ ] Повторный запрос отменяет предыдущую презентацию; позднее завершение старого запроса не закрывает/не обнуляет новый task. Очищать task только при совпадении requestID.
- [ ] Отменённая презентация не отменяет уже принятый persistence-worker append/ack. Не менять гарантию DictionaryCoordinator, что принятая запись истории завершается.
- [ ] Проверить `stats.btn_history`: недоступный файл даёт видимую ошибку открытия; успешный snapshot и история сохраняют прежние вычисления.

## Проверки

```bash
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSUI
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSDictionary
```

- [ ] Ручной smoke: редактировать две строки, открыть/закрыть меню, дождаться refresh, сохранить одну — вторая остаётся изменённой; ошибка статистики видна отдельно от данных.
- [ ] Коммиты: `fix: preserve dictionary drafts across refreshes`, `fix: show statistics failures without fabricated values`.

**Готово:** ни один общий refresh не очищает пользовательский ввод; конфликты явные; metrics failure не создаёт таблицу нулей; существующие операции replacements и persistence проходят тесты.
