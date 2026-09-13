# Эпоха 01. Надёжный перезапуск

> Для исполнителя: `executing-plans`, флажки по факту. Прочитать [общий план](00-PLAN.md). Не запускать следующие эпохи.

**Цель:** «Перезапустить» создаёт один процесс после выхода текущего; отказ завершения и ошибки запуска имеют явный исход.

**Архитектура:** небольшой отдельный CNSRestartHelper ждёт разрешённого завершения родителя. AppRestartCoordinator владеет запросом, меню только вызывает callback. Существующий updater/helper не используется для фиктивного обновления той же версии.

**Стек:** Swift 6, Foundation Process, существующий process-exit adapter, AppKit termination.

**Спецификация:** C01 и глобальные ограничения из 00-PLAN.md. Пункты меню 15–16.

## Файлы

Создать:

- `Packages/CNSCore/Sources/CNSCore/AppRestart.swift`: типы ticket, состояния и исполняемая последовательность helper.
- `Packages/CNSCore/Tests/CNSCoreTests/AppRestartTests.swift`: контракт ожидания и отмены.
- `ClickNSpeak/Sources/CNSRestartHelper/main.swift`: CLI helper, без UI и inference.
- `ClickNSpeak/Sources/ClickNSpeak/AppRestartCoordinator.swift`: подготовка/разрешение/отмена restart.
- `ClickNSpeak/Tests/ClickNSpeakTests/AppRestartCoordinatorTests.swift`.

Изменить:

- `ClickNSpeak/Package.swift`, `scripts/swift_build_app.sh`, `scripts/swift_verify_bundle.sh`: target, упаковка и подпись helper.
- `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift`: заменить прямой Process на `onRestartRequested`.
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`: связать restart с drain и отказом завершения.
- `Packages/CNSCore/Sources/CNSCore/Paths.swift`: каталог restart tickets внутри dataDirectory.
- `locales/{ru,en,de,uk,es,fr}.json`: локализованные исходы.

## A. Handoff и helper

Предлагаемый контракт:

```swift
public enum RestartTicketPhase: String, Codable, Sendable {
    case prepared, authorized, consumed, cancelled
}

public struct RestartTicket: Codable, Sendable, Equatable {
    public let id: UUID
    public let parentPID: Int32
    public let applicationURL: URL
    public var phase: RestartTicketPhase
}

public enum RestartOutcome: Sendable, Equatable {
    case launched
    case cancelled
    case parentDidNotExit
    case launchFailed
}

public enum AppRestartError: Error, Sendable {
    case helperMissing
    case helperNotReady
    case invalidTicket
}
```

Ticket не содержит ключи, окружение, транскрипты или произвольную shell-команду. Путь — UUID-файл в app-owned каталоге. Запись атомарная. Helper проверяет свой bundle, applicationURL и ID ticket; перед запуском перечитывает authorized-фазу.

- [ ] Добавить `RestartExecutor.run(ticketURL:waitForExit:launch:) async -> RestartOutcome`; замыкания имеют типы `(Int32) async throws -> Bool` и `(URL) async throws -> Void`, оба `@Sendable`. Ticket читается внутри executor до ожидания и повторно перед launch. Ошибки чтения/неверный ticket означают `.cancelled`, ошибка launch — `.launchFailed`.
- [ ] Добавить `AppRestartTests` с временным ticket и fake wait/launch. Исходная последовательность запуска приложения нарушает тест «launch не вызывается до выхода родителя».
- [ ] Реализовать helper: подтвердить готовность отдельным UUID-bound ready-файлом, дождаться родителя с deadline 60 секунд, перечитать ticket и запустить только authorized-запрос. Не посылать SIGKILL, не снимать instance lock самостоятельно.
- [ ] Использовать точный bundle/executable приложения, сохранить режим данных. Helper наследует нужное окружение родителя; при запуске нового процесса не терять `CNS_DATA_DIR`, не переносить секреты в argv/ticket/log. Не копировать старые `--update-*` launch arguments в обычный restart.
- [ ] При запуске из среды без bundled helper вернуть видимую ошибку `helperMissing`; не завершать приложение и не использовать гонку как fallback.
- [ ] Добавить executable target, build/install/sign/verify для CNSRestartHelper в тех же местах, где сейчас перечислен CNSUpdateHelper. Права helper 0755. Проверить как Developer ID, так и ad-hoc ветки без смены политики TCC.

Обязательные сценарии: parent ещё жив → launchCount 0; exit → один launch; cancelled ticket → 0; timeout → 0; повреждённый/чужой ticket → 0; повтор run для consumed ticket → 0; ошибка launch → typed failure; путь dev-данных не меняется.

Перед launch helper захватывает UUID-bound claim через эксклюзивное создание файла (`O_CREAT | O_EXCL`) и переводит ticket в consumed. Только владелец claim может запускать приложение: два одновременно начатых helper не создают два процесса. После успешного launch удалить только свой ticket/ready, а consumed claim хранить до безопасного cleanup следующего запуска. Если launch не удался после выхода родителя, оставить consumed claim и content-free failure record для следующего запуска; это не обещание, что завершившийся процесс покажет диалог. Проверить concurrent run одного ticket, а не только последовательный повтор.

## B. Интеграция с остановкой

Добавить `AppRestartCoordinator.prepare() async throws`, `authorizeAfterDrain() throws`, `cancel()`. На главном actor не более одного prepared request. `prepare` создаёт ticket, запускает helper и ждёт ready не более 5 секунд; при ошибке отменяет ticket и возвращает управление работающему приложению.

- [ ] В MenuBarController добавить `public var onRestartRequested: (() -> Void)?`; `onRestart()` только вызывает callback. Пока запрос готовится, повторный click не создаёт второй helper.
- [ ] AppDelegate начинает `prepare`; лишь после готовности helper вызывает `NSApp.terminate(nil)`.
- [ ] В ветке успешного `drainForTermination` вызвать `authorizeAfterDrain()` до освобождения instance lock и подтверждения выхода. Если ticket не записался — не подтверждать restart; показать отдельную ошибку, сохранив возможность повторного Quit.
- [ ] Непосредственно перед authorize проверить, что подготовленный helper ещё жив и его ready относится к этому ticket. Если deadline helper истёк во время долгого drain, не завершать приложение с ложным обещанием restart; отменить запрос и показать failure.
- [ ] В ветках session timeout/dictionary failure отменить ticket прежде, чем ответить AppKit отказом. Helper никогда не должен запустить приложение после будущего обычного Quit по старому запросу.
- [ ] Обычный Quit не создаёт и не авторизует ticket. Повторные termination callbacks не дублируют side effects.
- [ ] Тестировать callbacks AppDelegate с внедрённым coordinator: helper preparation failed → terminate не вызван; drain failed → cancel 1/authorize 0; success → authorize 1/release после него; обычный Quit → restart calls 0.

Не считать отмену task доказательством завершения процесса. Сохранить текущую terminal shutdown semantics: после неудачного drain приложение может быть уже остановлено для записи; это не основание автоматически оживлять SessionController.

## Проверки

```bash
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSCore --filter AppRestartTests
source venv/bin/activate && swift test --disable-index-store --package-path ClickNSpeak
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSUI
```

- [ ] Добавить процессный integration test с собственным fixture-parent и временным lock: медленный exit → child получает lock только после parent exit. Не запускать установленное приложение.
- [ ] Согласованный bundle smoke: idle restart, restart при записи/сохранении, двойное нажатие, отказ drain, отсутствующий helper. После успешного restart ровно один процесс и доступна запись.
- [ ] Проверить diff и packaging. Коммит: `fix: make application restart wait for shutdown`.

**Готово:** отсутствует запуск нового экземпляра из обработчика меню; все сценарии ожидания/отказа зелёные; bundle содержит проверенный helper. Если ресурса мало, завершить A с тестами, не включать новую команду меню до завершения B.
