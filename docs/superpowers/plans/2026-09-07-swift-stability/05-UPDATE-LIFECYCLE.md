# Эпоха 05 — Безопасное обновление и rollback

> Для исполнителя: использовать `executing-plans`; сначала завершить shutdown barrier эпохи 02. В этой эпохе автоматические тесты работают только с fake processes и временными `.app` директориями.

**Цель:** закрыть R13 и подтвердить, что updater не заменяет файлы живого приложения и всегда сохраняет путь восстановления.

**Архитектура:** helper управляет явной транзакцией stop→install→launch→ack→finalize. Process lifecycle и file operations инъецируются; отсутствие prerequisite приводит к остановке транзакции до изменения target.

**Стек:** CNSCore, CNSUpdateHelper, Foundation/AppKit, XCTest/Swift Testing.

**Спецификация:** [00-REVIEW-AND-PLAN.md](00-REVIEW-AND-PLAN.md), R13 и release constraints. Не публиковать релиз и не выполнять swap установленного приложения в рамках unit-тестов.

## Задача 1 — Process-exit prerequisite и безопасный rollback

**Файлы:** `ClickNSpeak/Sources/CNSUpdateHelper/main.swift`, `Packages/CNSCore/Sources/CNSCore/RecoverableAppSwap.swift`; создать `Packages/CNSCore/Sources/CNSCore/UpdateProcessLifecycle.swift`; tests `UpdateSecurityTests.swift`, создать `UpdateProcessLifecycleTests.swift`.

**Интерфейсы:** `UpdateProcessOperating: Sendable` с `isRunning(pid:) -> Bool`, `requestTermination(pid:) throws`, `waitForExit(pid:timeout:) async throws -> Bool`, `launch(application:arguments:) async throws -> Int32`. Runtime implementation отличает PID приложения от PID команды `/usr/bin/open`; использует URL/запуск NSWorkspace или другой способ получить именно запущенный процесс. Fake принимает script жизненного цикла.

- [ ] Red cases: parent жив после 30s → target/staged/backup не изменены; parent вышел → install разрешён; новая app не выходит после termination → rollback не удаляет её файлы; backup отсутствует → исходный target остаётся; рядом другое приложение с тем же bundle ID не завершается.
- [ ] Заменить цикл `for ... where kill(...) == 0` на проверяемый prerequisite:

```swift
guard try await processes.waitForExit(pid: parentPID, timeout: 30) else {
    throw UpdateLifecycleError.parentDidNotExit
}
try swap.install(staged: staged, target: target, backup: backup)
```

`UpdateLifecycleError` определить в новом файле: `.parentDidNotExit`, `.replacementDidNotExit`, `.acknowledgementTimedOut`. В production считать unknown/permission-denied состояние процесса как «не доказан выход», не как завершение.

- [ ] На rollback работать только с replacement PID и URL данной транзакции. `terminate()` — запрос; ждать фактического выхода. Если не вышел, оставить target/backup и durable record для следующего восстановления, вернуть failure; не удалять live bundle и не завершать все приложения с тем же bundle ID.
- [ ] В `RecoverableAppSwap.rollback` сначала проверять backup, затем переместить target в transaction-owned failed-candidate path, затем восстановить backup. При move failure пытаться вернуть failed-candidate обратно. Удалять failed copy только после доказанного восстановления/успешного запуска. Обновить `UpdateFileOperating` и fake для этой последовательности.
- [ ] Проверить шаги на injected ошибках create/move/launch/exit/ack/finalize и повторном recovery. Target и backup не должны исчезать одновременно.
- [ ] Green Core/helper build; коммит `fix: require process exit before update swap and rollback`.

## Задача 2 — Ack и восстановление после прерывания helper

**Файлы:** `Packages/CNSCore/Sources/CNSCore/AppUpdater.swift`, RecoverableAppSwap, CNSUpdateHelper main, AppDelegate/AppLaunchCoordinator; tests UpdateSecurity/AppDelegateStartup/UpdateProcessLifecycle.

**Интерфейс:** существующий `UpdateSwapTransactionRecord` дополнить candidate identity и точным phase/error outcome. Запись record должна бросать ошибку, а не молча проглатывать I/O failure. Ack относится к token, candidate build/hash и конкретному запуску.

- [ ] Fault matrix: helper прекращён после prepared/installed/ack; следующий запуск читает запись и предлагает/выполняет однозначное восстановление. Не удалять backup просто потому, что target directory существует.
- [ ] Не отправлять healthy ack после любого завершения `activateInitial`: оно может завершиться `.degraded` и отсутствием рабочего STT. Зафиксировать критерий ack: bootstrapped config, рабочий AppKit loop, instance lock и готовый runtime либо явно разрешённый recoverable setup state. Если пользователь должен пройти мастер, показать helper статус setup-pending и не трактовать длительное взаимодействие как crash через 60 секунд.
- [ ] Record должен быть сохранён до каждого необратимого удаления. Отказ записи record → сохранить backup и закончить ошибкой, а не продолжать без recoverability.
- [ ] Archive downloader проверяет максимум bytes во время transfer, а не только после `URLSession.download` завершения. Переиспользовать bounded transfer policy эпохи 04 там, где она подходит, сохранив update checksum/signature проверки.
- [ ] Green security/process/startup tests, `source venv/bin/activate && bash scripts/swift_verify.sh`; коммит `fix: persist update recovery state and validate launch acknowledgement`.

## Приёмка подписанной сборки

После unit gate — отдельное испытание на disposable user/VM и двух Developer ID подписанных сборках: normal update, slow shutdown, launch failure, no ack, rollback, no disk space, TCC сохранность. Требуются release credentials и разрешённая среда; отсутствие этих prerequisites оставляет соответствующий release gate открытым. Не заменять результат ad-hoc bundle verification утверждением о проверенном production update.

## Выход эпохи

- [ ] Нет swap/rollback поверх живого owning process; no-backup failure сохраняет target.
- [ ] Есть deterministic tests для каждого crash point и повторного восстановления.
- [ ] В normal-app запуске нельзя объявить update успешным исключительно из-за наличия процесса или app bundle.
