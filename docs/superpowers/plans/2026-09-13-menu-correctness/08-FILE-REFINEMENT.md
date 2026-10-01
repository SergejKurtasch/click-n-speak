# Эпоха 08 — отдельный результат AI-редактирования файла

> Для исполнителя: применять `executing-plans`; читать 00-PLAN.md и выполнять только эту эпоху. Глобальные ограничения из общего плана обязательны, флажки отмечать по факту.

**Цель:** при успешном распознавании и неудачном AI-редактировании текст остаётся доступным, а пользователь видит точный исход второго этапа.

**Архитектура:** FileTranscriptionResult получает neutral refinement outcome; SessionController заполняет его из RefineStatus, панель отображает. Жизненный цикл job по-прежнему принадлежит FileTranscriptionViewModel.

**Стек:** Swift, SwiftUI/AppKit; fake Transcribing/AiEditing.

**Спецификация:** [00-PLAN.md](00-PLAN.md), C08; после эпох 02 и 05. Средняя эпоха, без переделки медиа-декодеров.

## Исходная проблема

SessionController заменяет текст только при `.ok`; timeout/skipped/error/disabled остаются незаметными в успешном FileTranscriptionResult. Наличие ненулевого AiEditorRouter не означает, что активный editor существует. Галочка улучшения может обещать этап, который фактически не выполнен.

## Файлы

Изменить:

- `Packages/CNSTranscription/Sources/CNSTranscription/FileTranscription.swift`.
- `Packages/CNSSession/Sources/CNSSession/SessionController.swift`.
- `Packages/CNSUI/Sources/CNSUI/FileDropPanel.swift` и `MenuBarController.swift`.
- `Packages/CNSEditors/Sources/CNSEditors/AiEditorRouter.swift` — только если требуется точная availability, не новый router lifecycle.
- `Packages/CNSUI/Tests/CNSUITests/FileTranscriptionViewModelTests.swift`.
- `Packages/CNSSession/Tests/CNSSessionTests/SessionControllerTests.swift` и `SessionDoubles.swift`.
- `locales/{ru,en,uk,de,es,fr}.json`.

Создать: `Packages/CNSSession/Tests/CNSSessionTests/FileRefinementOutcomeTests.swift`.

## Шаг 1 — результат без потери STT

- [ ] Написать регрессию: STT возвращает текст, editor `.timeout`; результат сохраняет текст и сообщает timeout второго этапа. До исправления сообщение о втором этапе отсутствует.
- [ ] В FileTranscription.swift определить:

```swift
public enum FileRefinementOutcome: String, Sendable, Equatable {
    case notRequested
    case notRun
    case applied
    case unchanged
    case unavailable
    case skipped
    case timedOut
    case failed
}
```

- [ ] Добавить `refinement: FileRefinementOutcome` в FileTranscriptionResult и параметр initializer с default `.notRequested`. Провайдеры STT не обязаны импортировать CNSEditors; mapping выполняет CNSSession, где RefineStatus уже доступен через CNSCore.
- [ ] `.notRun` означает «пользователь просил редактор, но STT не завершился успешно/работа отменена до этапа». `.unavailable` — STT успешен, однако активного разрешённого editor нет. Не смешивать отсутствие запроса с невыполненным запросом.
- [ ] При refine=true помечать notRun сразу после STT result до раннего return. Только после успешного этапа назначать applied/unchanged, после отказа — соответствующий исход.
- [ ] Mapping: ok→applied; unchanged→unchanged; disabled→unavailable; skipped и memoryPressure→skipped; timeout→timedOut; error→failed.
- [ ] Для `.ok` использовать refined text; для unchanged/failure/skip сохранять STT text согласно текущему контракту. Пустой или некорректный успешный editor result обрабатывать существующей editor policy, не вводить здесь второй фильтр.
- [ ] Сохранить `shouldApplyDirectReplacements` и его отдельную семантику для cloud hints. Direct replacements не означают, что AI этап выполнен, и не превращают timeout в applied.
- [ ] При cancel/shutdown сохранять outer `.cancelled`, partial text и factual STT metadata. Поздний editor callback не может объявить завершённую отмену успешной.

## Шаг 2 — понятная панель

- [ ] Добавить в ViewModel отдельное `refinementMessage`/warning state, которое не подменяет основной errorMessage от STT/cancel и не очищается успешным Save As.
- [ ] Для applied показывать завершённое улучшение; unchanged — выполнено без изменений; unavailable/skipped/timedOut/failed — распознавание готово, улучшение не выполнено, текст доступен. notRun показывать только вместе с фактической причиной прекращения основной работы.
- [ ] Все сообщения локализовать по typed outcome. Не показывать provider response body и секреты; не добавлять служебное предупреждение внутрь редактируемого транскрипта.
- [ ] Передать панели актуальную availability активного редактора. При Disabled или незавершённой подготовке сделать недоступность видимой рядом с выключенным toggle и объяснить выбор backend через меню. Не пересоздавать ViewModel при runtime refresh.
- [ ] Если доступность исчезла после выбора или до запуска job, SessionController всё равно возвращает `.unavailable`: UI snapshot не заменяет проверку в исполнителе. Начатый job сохраняет свой runtime snapshot.
- [ ] При изменении availability во время job не менять captured refine intent и не очищать результат. При новом старте сбрасывать сообщения предыдущего job, при закрытии/открытии сохранять состояние текущего.
- [ ] Copy/Save As экспортируют только editable text. Успешный Save не скрывает информацию о невыполненном AI; ошибка Save не стирает STT/refinement outcome.

## Шаг 3 — регрессионная матрица

- [ ] Все восемь outcomes имеют проверки mapping и отображения; `.unchanged` не рисуется ошибкой.
- [ ] Refine=false: ни одного вызова editor, `.notRequested`.
- [ ] Refine=true, editor router без active service: `.unavailable`, текст сохранён.
- [ ] STT failure/noSpeech/partial cancel: редактор не вызывается; исход STT остаётся главным.
- [ ] Cancel во время refinement: владение job сохраняется до фактического выхода; второй start отклоняется; поздний callback не меняет новый job.
- [ ] Закрытие/повторное открытие панели сохраняет partial text и warning. Runtime refresh не стирает ручные правки результата.
- [ ] Provider progress `.completed` не завершает UI до editor outcome.
- [ ] Ручная правка текста + Save As экспортирует правку без префикса warning.
- [ ] Текущая матрица media formats, content magic, AAC conversion, сегментация и cancellation остаются зелёными.

## Проверки и завершение

```bash
source venv/bin/activate
swift test --package-path Packages/CNSTranscription
swift test --package-path Packages/CNSEditors
swift test --package-path Packages/CNSSession
swift test --package-path Packages/CNSUI
swift test --package-path ClickNSpeak
```

- [ ] Не добавлено auto-copy, записи в Downloads или скрытого платного запроса.
- [ ] Отчёт UI описывает итог STT и editor раздельно; cancel никогда не становится warning-success.
- [ ] Коммит: `fix: expose file refinement outcomes without losing transcripts`; обновить AGENTS.md при изменении контракта результата.

**Готово, когда:** по завершении файла видно, состоялось ли AI-редактирование, а любой сохранённый текст доступен для правки, копирования и явного экспорта.
