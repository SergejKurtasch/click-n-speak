# Эпоха 06 — удаление только свободных локальных моделей

> Для исполнителя: применять `executing-plans`; читать 00-PLAN.md и выполнять только эту эпоху. Глобальные ограничения из общего плана обязательны, флажки отмечать по факту.

**Цель:** исключить удаление модели во время подготовки, использования старым runtime, загрузки или проверки целостности.

**Архитектура:** один общий реестр использования артефактов в CNSCore; владельцы операций удерживают разрешение на использование до фактического завершения. Удаление получает исключительное разрешение относительно новых пользователей. UI показывает причины запрета, но окончательную проверку делает владелец файловой операции.

**Стек:** Swift concurrency, Foundation; маленькие временные model fixtures, без скачивания реальных весов.

**Спецификация:** [00-PLAN.md](00-PLAN.md), C06; после эпохи 05. Большая эпоха, блоки A/B.

## Исходная проблема

`onDeleteLocalModel` исключает из списка активные ID. После выбора вызывает `ModelManager.delete` с `activeModelID: nil`. Между формированием списка и удалением кандидат может начать подготовку; активный ID также не отражает удерживаемые роутером старые сервисы и незавершённые transfer/validation.

Сначала воспроизвести эту гонку с управляемой паузой fake preparation. Не считать статическую трассировку доказательством воспроизведённого падения на установленной программе.

## Файлы

Изменить:

- `Packages/CNSCore/Sources/CNSCore/ModelManager.swift` и `ModelDownloader.swift`.
- `ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift` и `AppRuntimeCoordinator.swift`.
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`.
- `Packages/CNSTranscription/Sources/CNSTranscription/TranscriberRouter.swift`.
- `Packages/CNSEditors/Sources/CNSEditors/AiEditorRouter.swift`.
- `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift`.
- `Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift` и `ModelDownloaderNetworkTests.swift`.
- `ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift`.
- `locales/{ru,en,uk,de,es,fr}.json`.

Создать:

- `Packages/CNSCore/Sources/CNSCore/ModelArtifactAccess.swift`.
- `Packages/CNSCore/Tests/CNSCoreTests/ModelArtifactAccessTests.swift`.
- `Packages/CNSUI/Tests/CNSUITests/ModelDeletionTests.swift`.

## Блок A — реестр и удержание использования

- [ ] Найти все production-вызовы удаления, redownload, validate, подготовки локального STT/editor и старта загрузки. Зафиксировать в тестах, что ни один путь удаления не обходит общий сервис.
- [ ] Ввести `ModelArtifactAccess`: потокобезопасный объект с короткими синхронными критическими секциями. Одна instance создаётся в AppDelegate и передаётся всем владельцам. Не создавать отдельный реестр на каждый downloader/factory.
- [ ] Ключ реестра — канонический ID ModelRegistry, соответствующий одному артефакту. Legacy aliases нормализуются до захвата. Для тестового override использовать изолированную идентичность, не блокировать пользовательскую модель случайно.
- [ ] Определить контракт:

```swift
public enum ModelArtifactUse: String, Sendable, Hashable {
    case preparing, runtime, transfer, validation
}

public enum ModelArtifactAccessError: Error, Sendable, Equatable {
    case inUse(modelID: String, reasons: Set<ModelArtifactUse>)
    case deletionInProgress(modelID: String)
}
```

- [ ] `acquireUse(modelID:reason:) throws -> UUID` добавляет token либо отказывает при уже зарезервированном удалении. `releaseUse(_:)` идемпотентен. `reserveDeletion(modelID:) throws -> UUID` проверяет отсутствие use tokens и атомарно помечает удаление. `finishDeletion(_:)` снимает только соответствующий token. Снимок причин доступен для UI, но не даёт права удалить.
- [ ] Не держать lock во время await, работы с диском или уведомления UI. Reserve выполняется до файловой операции; все новые users отклоняются до finishDeletion. Ошибка удаления также освобождает reservation через `defer`.
- [ ] Захватывать preparation token до validation/чтения файлов; передавать владение подготовленному сервису без окна release/acquire. Продвижение reason preparing→runtime меняет только описание, не право владения.
- [ ] При провале preparation освобождать token после фактического stop кандидата. При успехе держать его весь срок сервиса, включая retired service, который ещё обслуживает старую запись/файл/prepare/reload/refine.
- [ ] Привязать освобождение к существующему drain/stop роутеров. Отмена ожидания не означает завершение inference и не освобождает token преждевременно. Не менять lease правила InferenceExecutionGate.
- [ ] Загрузчик удерживает transfer token с начала операции до выхода task и cleanup; atomic validation удерживает тот же token или дополнительный validation token без промежутка. Late callback не может освободить token другой операции.
- [ ] Не расширять реестр до нового алгоритма публикации загрузок: существующие staging, checksum, generation и atomic activation сохраняются. Реестр этой эпохи согласовывает использование с удалением.

Тесты A: два использования одного ID; разные ID независимы; запрещённый reserve; запрещённый acquire после reserve; двойной release; stale finish token; exception cleanup; cancelled prepare still running; retired service releases only after final use; transfer validation has no deletion gap.

**Граница A:** пользователи интегрированы, тесты зелёные; UI удаления пока остаётся прежним. Коммит: `feat: track local model artifact ownership`.

## Блок B — защищённая команда и recovery

- [ ] Изменить ModelManager.delete так, чтобы production-удаление требовало общий ModelArtifactAccess и само захватывало reservation. Удалить небезопасный обход `activeModelID: nil`; тестовые удаления временных fixtures также используют изолированный реестр.
- [ ] После reservation повторно проверить расположение артефакта в управляемых Paths и установленность. Удалять только файлы выбранного descriptor и связанные validation records; не делать рекурсивное удаление общего cache/model root.
- [ ] Предоставить UI список установленных моделей с причинами недоступности: используется, готовится, загружается/проверяется, удаляется. Нельзя показывать выбранный desired ID как свободный только потому, что active ещё старый.
- [ ] После подтверждения повторно вызвать защищённый delete. При изменившемся состоянии показать «Модель сейчас используется» и обновить список. При файловой ошибке показывать failure, не сообщать об успехе и не сбрасывать текущий runtime.
- [ ] После успеха обновить наличие и размеры моделей, галочки и recovery предложения. Не менять выбранную рабочую модель без необходимости.
- [ ] Провести redownload из эпохи 05 через тот же owner. Если повреждённая модель удерживается работающим сервисом, безопасно отклонить замену до освобождения и объяснить причину; не останавливать запись ради повторной загрузки.
- [ ] Проверить, что файл может начать подготовку только после завершения удаления: missingArtifact должен вести к точному download recovery, а не к половинной активации.

Сквозные регрессии:

1. Открыт список удаления → начинается prepare той же модели → подтверждение удаления отклонено, файлы целы.
2. Удаление зарезервировано → начинается prepare → prepare получает typed refusal/missing recovery, не читает удаляемый файл.
3. Runtime переключён, старая модель ещё занята file job → удаление запрещено до реального выхода job.
4. Cancel download во время callback/validation → удаление запрещено, пока task не вышел; после cleanup разрешено.
5. Невозможна запись/удаление fixture → UI failure, reservation освобождён, повторная попытка работает.
6. Свободная модель удалена → другие артефакты и пользовательская конфигурация сохранены.

## Проверки и завершение

```bash
source venv/bin/activate
swift test --package-path Packages/CNSCore
swift test --package-path Packages/CNSTranscription
swift test --package-path Packages/CNSEditors
swift test --package-path Packages/CNSUI
swift test --package-path ClickNSpeak
```

- [ ] Concurrency-тесты управляют suspend/resume через barriers, а не случайные sleeps.
- [ ] Все destructive tests используют временные fixtures; пользовательские модели не удаляются.
- [ ] Diff проверен на прямые `removeItem` в новых UI/recovery путях и независимые registry instances.
- [ ] Коммит B: `fix: prevent deletion of models with active owners`; обновить архитектурные инварианты AGENTS.md.

**Готово, когда:** все пути удаления проверяются в момент операции и ни одно незавершённое использование не теряет свой артефакт.
