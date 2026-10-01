# Эпоха 09 — независимые операции обновления и видимые ошибки

> Для исполнителя: применять `executing-plans`; читать 00-PLAN.md и выполнять только эту эпоху. Глобальные ограничения из общего плана обязательны, флажки отмечать по факту.

**Цель:** приложение показывает ход собственного обновления, правильно отменяет именно его и не скрывает ошибки установки; загрузка модели продолжает жить независимо.

**Архитектура:** AppUpdateViewModel владеет UI-состоянием и task, AppUpdater — staging/installation ownership; AppDelegate согласует установку с общим termination barrier. Существующие durable swap, проверка candidate и CNSUpdateHelper сохраняются.

**Стек:** Swift concurrency, AppKit, fake archive downloader/mounter/verifier/process operator.

**Спецификация:** [00-PLAN.md](00-PLAN.md), C01/C09; после эпох 01 и 06. Большая эпоха, строго разделить A и B.

## Исходные проблемы

- Update и model download используют один `downloadPanel`: show заменяет callbacks и generation другой операции.
- Progress `downloadAndStage` игнорируется. Повторные check/create Task не ограничены одним запросом.
- Старый task может обнулить `appUpdateTask` новой операции; глобальный `cancelAndCleanUp()` способен очистить чужой staged update.
- `try? await swapAndRelaunch()` скрывает ошибки копирования, проверки и запуска helper.
- После «Позже» проверенный candidate остаётся в памяти updater, но нет очевидной команды установить его без новой загрузки.
- При отказе AppDelegate завершить процесс уже запущенный helper всё ещё ждёт его выхода. Этот переход также требуется проверить: последующий обычный Quit не должен неожиданно завершать отклонённую установку.

## Файлы

Изменить:

- `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift` и `ModelDownloadPanel.swift`.
- `Packages/CNSCore/Sources/CNSCore/AppUpdater.swift`.
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`.
- `Packages/CNSCore/Tests/CNSCoreTests/UpdateSecurityTests.swift`, `UpdateProcessLifecycleTests.swift`, `UpdateTransactionRecoveryTests.swift`.
- `Packages/CNSUI/Tests/CNSUITests/MenuStateTests.swift`.
- `locales/{ru,en,uk,de,es,fr}.json`.

Создать:

- `Packages/CNSUI/Sources/CNSUI/AppUpdateViewModel.swift`.
- `Packages/CNSCore/Sources/CNSCore/AppUpdateOperation.swift`.
- `Packages/CNSUI/Tests/CNSUITests/AppUpdateViewModelTests.swift`.
- `Packages/CNSCore/Tests/CNSCoreTests/AppUpdateOwnershipTests.swift`.
- `ClickNSpeak/Tests/ClickNSpeakTests/UpdateTerminationTests.swift`.

`CNSUpdateHelper/main.swift` и `RecoverableAppSwap.swift` менять только если сквозная проверка выявит необходимое расширение отмены до установки. Не менять формат durable transaction ради удобства UI.

## Блок A — владение загрузкой и панелью

- [ ] Добавить AppUpdateViewModel на MainActor. Передать closures check/download/cancel/install вместо прямых статических вызовов из menu handler. Состояния: idle, checking(UUID), downloading(UUID), readyToInstall(handle), installing(handle), failed(UUID, localizedMessageKey). Внедряемые fake closures позволяют проверять порядок callback без сети.
- [ ] Проверка single-flight: повторный click во время checking/downloading показывает текущее состояние, не создаёт новый запрос или alert. Ошибка check освобождает только свой task slot и разрешает повтор.
- [ ] Создать два экземпляра ModelDownloadPanel: `modelDownloadPanel` и `appUpdatePanel`. Это два окна с разными cancel/retry handlers. Не строить общий менеджер загрузок для всех типов.
- [ ] Каждый callback проверяет operationID ViewModel и generation своего panel. Старый completion/error/defer не очищает новую activeTask. Уничтожение ViewModel отменяет только принадлежащую ему работу.
- [ ] В CNSCore определить handle без содержимого файлов и ключей:

```swift
public struct StagedUpdateHandle: Sendable, Equatable {
    public let operationID: UUID
    public let version: String
}

public enum AppUpdateStage: String, Sendable {
    case downloading, verifyingArchive, staging, verifyingCandidate, ready
}

public struct AppUpdateProgress: Sendable {
    public let stage: AppUpdateStage
    public let fraction: Double?
}
```

- [ ] Добавить явные public initializers. Изменить `downloadAndStage(update:operationID:progress:)` на возврат StagedUpdateHandle; URL candidate остаётся внутри AppUpdater. Сопоставление handle с текущим staged обязательно проверяется при последующих действиях.
- [ ] `cancelAndCleanUp(operationID:)` действует только на указанную текущую operation/staged. Cancellation старого UUID не увеличивает generation новой операции и не удаляет её directory. Сохранить локальный cleanup sessionDirectory в catch downloader.
- [ ] Не начинать второй app download до фактического выхода отменённого task; модель при этом может загружаться. Новая check после завершения разрешена. Инъецированные late callbacks всё равно отсекаются UUID.
- [ ] Передать реальный download fraction в панель через небольшой метод отображения процента/стадии. Clamp 0…1 только для отображения. Не выдумывать speed/ETA из одного процента. Во время verification/staging показывать отдельную неопределённую стадию.
- [ ] Для неотменяемой atomic проверки отключать cancel/close до безопасной границы, как у model validation. Нажатая ранее отмена удерживает ownership до выхода операции.
- [ ] Failure показывает понятный текст и Retry только после завершения cleanup. Retry получает новый UUID; старые сообщения и cancellation не влияют на него.

Тесты A: одновременные model/app progress; cancel app не вызывает model.cancel; cancel model не вызывает updater.cancel; repeated check → 1 request; late success/error старого UUID; cancel до/после stage; старый cleanup после нового staged; ошибка checksum не становится ready; прогресс достигает ready только после verification.

**Граница A:** новое владение и независимые панели готовы. Существующая команда install временно подключена через адаптер старого updater до B; её ошибки не объявлять исправленными. Коммит: `fix: isolate application update progress and cancellation`.

## Блок B — «Позже», установка и отказ завершения

- [ ] При ready показать «Установить и перезапустить» и «Позже». Later сохраняет handle; пункт меню меняется на «Установить обновление VERSION…» или получает соответствующий вложенный action. Повторное открытие показывает тот же готовый candidate, без download.
- [ ] Перед install проверить соответствие handle текущему staged и наличие candidate, затем повторно выполнить существующую проверку подготовленной копии. Missing candidate → явная ошибка и путь повторной загрузки.
- [ ] Убрать `try?` с install пути. Ошибка до успешного запуска helper оставляет приложение открытым и staged доступным для retry, если candidate по-прежнему цел. Удаляются только принадлежащие неудачной попытке temporary siblings.
- [ ] Разделить core `swapAndRelaunch` на запуск установки и запрос AppKit termination: `beginInstallation(handle:) async throws -> UpdateInstallationHandle`, где новый public Sendable/Equatable handle содержит transactionID UUID и operationID UUID. AppUpdater удерживает конкретный Process helper и состояние этой попытки; AppDelegate вызывает NSApp.terminate только после успешного begin.
- [ ] Подключить callback установки из ViewModel через MenuBarController к AppDelegate. На время подготовки и handoff запрещены второй install и обычный restart. Один общий intent выхода: quit, restart или update, без одновременного CNSRestartHelper и CNSUpdateHelper.
- [ ] В AppDelegate при отказе drain вызвать `cancelPendingInstallation(handle:) async throws` до разрешения повторного restart/install. Метод действует только на собственный ещё ожидающий helper при живом исходном процессе: остановить его, дождаться реального выхода, сохранить/убрать transaction-owned подготовленные файлы согласно durable phase. Не трогать replacement PID или target app.
- [ ] Если остановка helper не подтверждена, оставить установку busy и instance lock удержанным, показать failure. Не разрешать новый intent и не считать Task.cancel доказательством выхода helper. Recovery после process failure остаётся в существующем transaction mechanism.
- [ ] При успешном drain не останавливать helper; release instance lock и AppKit reply выполняются как сейчас. Helper сам доказывает exit родителя перед atomic install.
- [ ] Не сообщать «Обновлено» при старте helper: прежний процесс может сказать только «Подготовлено / Завершаем приложение». Успех установки определяется существующими ack и finalize нового процесса.
- [ ] Не добавлять обещание сохранения staged UI после произвольного перезапуска. В этой эпохе Later работает в текущем процессе; уже начатые durable transactions восстанавливаются по прежним правилам.
- [ ] Проверить terminal shutdown: отказ не оживляет остановленный SessionController. Возможность обычного повторного Quit сохраняется после подтверждённой отмены handoff.

Тесты B:

1. Later → повторный install использует handle, downloadCount остаётся 1.
2. Ошибка копирования/verification/helperMissing/helper.run → видимая failure, parent не завершён, безопасный retry.
3. Двойной install → один helper, один termination request.
4. Shutdown refused → helper завершён до освобождения intent; последующий обычный Quit не устанавливает update.
5. Parent ещё жив → atomic install не вызван; parent вышел → одна установка.
6. Wrong/старый handle не устанавливает иной candidate и не удаляет его staging.
7. Existing wrong ack/launch failure/rollback/finalize failure tests остаются зелёными, exact PID и candidate hashes сохраняются.

## Проверки и завершение

```bash
source venv/bin/activate
swift test --package-path Packages/CNSCore
swift test --package-path Packages/CNSUI
swift test --package-path ClickNSpeak
```

- [ ] Проверить все сценарии сначала на fake filesystem/processes, затем на отдельном disposable app bundle. Не обновлять установленное приложение этим планом.
- [ ] Новое состояние и localized labels не скрывают исходную причину error; нет передачи raw provider response или config в логи.
- [ ] Коммит B: `fix: make staged update installation explicit and recoverable`; обновить AGENTS.md для ownership/termination contract.

**Готово, когда:** UI операций независим, любой pre-install failure виден, Later повторно использует candidate, а отказ shutdown не оставляет неожиданную отложенную установку.
