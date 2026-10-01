# Аудит паритета Python → Swift и план доведения Click-n-speak

- Дата аудита: 2026-08-29
- Ветка: `swift_migration`
- Снимок: текущий рабочий каталог, включая незакоммиченные изменения
- Целевой эталон поведения: действующая Python-версия

## 1. Цель документа

Этот документ отвечает на два вопроса:

1. Насколько текущая Swift-реализация повторяет уже работающую Python-версию.
2. В каком порядке устранять разрывы, чтобы получить надёжное приложение, а не только собирающийся прототип.

Исходный архитектурный план `docs/SWIFT_MIGRATION_PLAN.md` остаётся полезным как описание целевого устройства. Этот аудит дополняет его фактическим состоянием кода, найденными дефектами, приоритетами, критериями готовности и программой приёмки.

## 2. Краткий итог

Swift-приложение уже собирается и имеет хорошую модульную основу, но до функционального паритета с Python пока далеко. Главный вывод: исправлять отдельные визуальные симптомы сейчас недостаточно. Сначала нужно стабилизировать четыре системных слоя:

1. Идентичность `.app`, подпись и TCC-права.
2. Единую модель состояния приложения и жизненный цикл сервисов.
3. Тестовый контур и воспроизводимую сборку.
4. Единые пути данных и гарантированное обновление UI после изменений.

Самые серьёзные подтверждённые проблемы:

- `scripts/swift_build_app.sh` при каждой ad-hoc сборке сбрасывает Microphone, Accessibility и Input Monitoring через `tccutil`. Поэтому выданные права предсказуемо исчезают после следующей сборки.
- `SetupWizard` запускает мониторинг Accessibility в задаче, унаследовавшей `MainActor`, а затем блокирует этот же actor через `runModal()`. Это объясняет зависание примерно до 120 секунд после включения права.
- Незавершённый мастер всё равно записывает `setup_done`, поэтому последующие запуски попадают в противоречивое состояние.
- В DEBUG история намеренно читается из `Click-n-speak-dev`, где файла нет, тогда как в production-файле обнаружено 1824 записи. Пользователь видит пустую историю, хотя данные не потеряны.
- Выбор STT-модели, STT-backend или AI Editor в меню меняет JSON, но не пересоздаёт уже созданные `transcriber` и `aiEditor`. UI говорит одно, а текущая сессия продолжает использовать старый сервис.
- При отсутствии модели или API-ключа приложение молча подменяет настоящий STT на `StubTranscriber`. Снаружи это выглядит как «ничего не распознаётся».
- Локальный AI Editor пока заглушка, а локальная транскрипция файлов не реализована.
- `SessionController` дважды завершает отменённую сессию. Это подтверждено падающим тестом: после 20 циклов счётчик равен 40, а модель не перезагружается в ожидаемый момент.
- Иконка status bar устанавливается один раз в состоянии `idle` и не получает состояния `recording`/`processing`.
- Несколько меню и панелей реализованы частично, используют неверные ключи локализации или не обновляют `initial_prompt` после изменения словаря.
- Тесты `CNSCore` и `CNSUI` сейчас не компилируются; настоящий golden-тест Whisper пропущен.

До устранения P0-дефектов Swift-версию нельзя использовать для замены production Python-приложения или для работы с единственной копией пользовательских данных.

## 3. Что уже сделано хорошо

Важно сохранить удачные части, а не переписывать миграцию целиком:

- Проект разделён на локальные пакеты `CNSCore`, `CNSAudio`, `CNSInput`, `CNSTranscription`, `CNSSession`, `CNSDictionary`, `CNSUI`.
- Основной AppKit-код и `SessionController` изолированы через `@MainActor`.
- Carbon hotkey работает без Input Monitoring — это правильное намеренное отличие от Python/pynput.
- В инжекторе перенесены стабильные проверки frontmost PID и безопасное восстановление pasteboard по `changeCount`.
- Перенесены VAD-чанкинг, guard короткого финального чанка, RMS-проверка тишины, фильтр галлюцинаций и сборка контекста.
- Форматы `config.json`, phrase history, dataset и corrections в основном сохраняют совместимость.
- Реализованы атомарные записи конфигурации, Keychain-обвязка, модельный каталог и загрузчик моделей.
- Поддержан сценарий «горячая клавиша при открытом попапе дописывает текст».
- `CNSAudio`, `CNSInput`, `CNSDictionary` и большая часть unit-тестов `CNSTranscription` уже проходят.

Стратегия должна быть эволюционной: укрепить composition root и state machine, затем довести пользовательские поверхности.

## 4. Методика аудита

Проверены:

- карта Python-модулей и задокументированные thread-safety/state-machine инварианты;
- текущие Swift-пакеты и `AppDelegate`;
- мастер прав, build/signing-скрипты и runtime paths;
- меню, ассеты, popup и новые окна;
- аудио, сессия, локальный/cloud STT, AI Editor;
- история, словарь, corrections, metrics и maintenance;
- downloader, updater, autostart и завершение приложения;
- сборка приложения и тесты каждого Swift-пакета.

Статусы в матрице:

- **Зелёный** — основная логика перенесена и проверяется тестами.
- **Жёлтый** — работает частично либо нет достаточной end-to-end проверки.
- **Красный** — отсутствует, работает неверно или создаёт блокирующий дефект.

## 5. Фактическое состояние сборки и тестов

| Компонент | Результат на 2026-08-29 | Вывод |
|---|---|---|
| `ClickNSpeak` | `swift build` проходит | Исполняемый таргет компилируется |
| `CNSAudio` | 28 тестов проходят | Хорошая база, но нужны race/real-time тесты |
| `CNSInput` | 17 тестов проходят | Хоткей и доставка текста покрыты лучше других слоёв |
| `CNSDictionary` | XCTest и Swift Testing проходят | Форматы и базовые анализаторы работают, интеграция с app отсутствует |
| `CNSTranscription` | тесты проходят; настоящий Whisper golden-тест пропущен | Проверены фильтры/контекст, не проверен реальный движок в CI |
| `CNSSession` | 1 тест падает | Подтверждено двойное завершение/двойной счёт сессий |
| `CNSCore` | тестовый target не компилируется | Ошибки Swift 6 actor isolation в health/update tests |
| `CNSUI` | тестовый target не компилируется | Тесты отстали от сигнатур панелей; структура меню также не соответствует ожиданиям |

Дополнительный риск: тесты пакетов запускаются отдельно, но нет одного root-командного сценария, который собирает приложение, прогоняет все пакеты и проверяет собранный `.app`.

## 6. Матрица функционального паритета

| Область | Эталон Python | Swift сейчас | Статус | Приоритет |
|---|---|---|---|---|
| Single instance | `flock`, активация уже запущенного приложения | Перенесено | Зелёный | P2: добавить интеграционный тест |
| Runtime paths | Production использует общие данные; dev-пути известны явно | DEBUG уходит в `Click-n-speak-dev`, но `Permissions` читает production-флаг | Красный | P0 |
| Мастер прав | Последовательный, повторно проверяет TCC, не помечает ошибку успехом | Блокирующий `runModal`, гонка с MainActor, неправильный `setup_done` | Красный | P0 |
| Подпись/TCC | Стабильный `.app` и стабильная запись TCC | Ad-hoc подпись меняется, build-скрипт сам сбрасывает TCC | Красный | P0 |
| Hotkey | pynput + 3 права, restart после выдачи | Carbon, Input Monitoring не нужен | Зелёный | P1: согласовать тексты мастера |
| Старт приложения | Wizard → language → model → warmup → ready | Wizard и language picker соединены через `else if`; pipeline создаётся независимо от готовности | Красный | P0 |
| Audio capture | Надёжный stop, весь хвост попадает в final chunk | Есть потенциальная гонка consumer/stop и старт после уже выполненного stop | Жёлтый | P0 |
| VAD chunking | Адаптивные пороги, non-blocking queue | Основная логика перенесена | Зелёный | P1: stress/performance |
| Локальный STT | Рабочий MLX Whisper child process, warm/cold policy | whisper.cpp реализован, но нет обязательного golden run и полной warmup policy | Жёлтый | P1 |
| Cloud STT | Prompt/language/timeouts, корректные MIME и file flow | Prompt/языки обрабатываются неполно; MIME и ошибки HTTP ненадёжны | Красный | P1 |
| File transcription | Аудио/видео файл → STT → optional AI → результат | `WhisperCppTranscriber.transcribeFile` не реализован | Красный | P1 |
| AI Editor local | Реальный Qwen, lock, timeout, memory-pressure skip | `LocalAiEditor` — заглушка | Красный | P1 |
| Gemini Editor | Статусы, неперекрывающиеся запросы, realtime/file timeouts | Основа есть, но timeout/session semantics и HTTP-валидация неполны | Жёлтый | P1 |
| Session state machine | IDLE → RECORDING → PROCESSING → POPUP, exact cleanup | Большая часть перенесена; есть double cleanup и start/stop races | Красный | P0 |
| Popup | HUD, interactive edit, append, Enter/Escape, ⌘D | Основной сценарий работает | Жёлтый | P1: multi-monitor, teardown, i18n |
| Injection | Stable PID, background paste, guarded clipboard restore | Основная логика и тесты есть | Зелёный | P1: полноценный E2E |
| Status bar icon | idle/recording/processing визуально синхронны | Всегда `idle` | Красный | P1 |
| Menu structure | Нативные rows, status icons, live permissions, history UX | Частично; stale tests, неверные ключи, неполные иконки/states | Красный | P1 |
| Live config changes | Выбор модели/backend сразу влияет на сервисы | Меняется Config, созданные сервисы не пересобираются | Красный | P0 |
| Phrase history | Production TSV, быстрый счётчик, copy/show more | Data layer есть; DEBUG смотрит в пустой файл, UX неполон | Красный | P0/P1 |
| Dataset/corrections | Запись метаданных, correction analysis | Основа есть; неверное поле STT model, пути резолвятся повторно | Жёлтый | P1 |
| User dictionary | Add/edit/revert, canonicalization, prompt sync | ⌘D есть; панели/accept/delete не всегда перестраивают prompt | Красный | P1 |
| Suggestions | Startup alert, review, accept/reject/cooldown | Частичная SwiftUI-панель, схема полей расходится, нет полного flow | Красный | P1 |
| Replacements | Ручные и авто пары, редактирование/сохранение | Только частичное чтение/удаление corrections | Красный | P2 |
| Prompt file sync | Atomic write, watcher, protection от пустого файла | Не найден полный эквивалент | Красный | P1 |
| Metrics/decay | Daily snapshot, notifications, 60s dirty flush | Scheduler пишет `not implemented` | Красный | P1 |
| Model download | Child download, progress, cancel, activation | Основа есть; слабая проверка готового файла и live activation | Жёлтый | P1 |
| Autostart | Config и системное состояние синхронны | SMAppService есть, menu/config state может расходиться | Жёлтый | P2 |
| Updates | Проверка/установка release с безопасной заменой | Основа есть; staging, права и проверка подписи требуют доработки | Жёлтый | P2 |
| i18n | Все пользовательские строки из locale JSON | Новые панели содержат hardcoded English и неверные keys | Красный | P2 |
| Shutdown | Остановка recorder/workers/models, flush config | Останавливаются hotkey/scheduler/lock; pipeline не закрывается полностью | Красный | P1 |
| Telemetry/privacy | События без transcript/prompt/clipboard | База есть, но не все разрывы/overflow наблюдаемы | Жёлтый | P2 |

## 7. Подтверждённые причины текущих пользовательских симптомов

### 7.1 Права «включены, но приложение висит»

Причина составная:

1. `scripts/swift_build_app.sh:44-48` сбрасывает TCC для каждой ad-hoc сборки.
2. `SetupWizard.waitForPermissionWithDialog()` создаёт `Task` на `MainActor`, после чего вызывает синхронный `NSAlert.runModal()` на том же actor.
3. Таймер-проверка должен вызвать `NSApp.abortModal()`, но его выполнение зависит от actor, который занят modal flow.
4. Timeout равен 120 секундам — это совпадает с наблюдаемым «зависает на пару минут».
5. После неполного flow `SetupWizard.swift:148` всё равно вызывает `Permissions.markSetupDone()`.
6. `Permissions` жёстко пишет флаг в production Application Support, игнорируя `Paths.mode`. DEBUG и production поэтому используют смешанное состояние.

### 7.2 История сообщений не показывается

Data layer `PhraseHistory` существует, а production-история не потеряна: в ней 1824 строки. Но DEBUG-сборка через `Paths.resolveDefault()` читает `~/Library/Application Support/Click-n-speak-dev/phrase_history.txt`; этот файл отсутствует.

Дополнительно UI истории отстаёт от Python:

- меню использует `menu.history_more`, тогда как locale-файлы содержат `menu.show_more`;
- нет нативной copy-иконки и временного feedback «скопировано»;
- «показать ещё» закрывает меню и проявляет результат только при следующем открытии;
- после добавления новой фразы нет явного события обновления submenu;
- debug/release источник данных нигде не показан пользователю.

### 7.3 Иконки и пункты меню ведут себя несогласованно

- Status item получает `idle` image при создании и больше не обновляется.
- Permissions submenu не отражает granted/denied цветными иконками, хотя ассеты существуют.
- Запрашивается отсутствующий asset `api-keys`.
- Model/language rows хранят check state внутри `NSButton` custom view, а не в `NSMenuItem.state`. Это ломает нативное поведение, тесты и часть layout/highlight semantics.
- Меню полностью перестраивается прямо во время action callback. Это провоцирует закрытие, мигание и устаревшие ссылки во время tracking loop.
- Текущие тесты ожидают другую структуру меню: одновременно старый Input Monitoring и отсутствие новых Setup/About.
- Часть новых окон сделана на SwiftUI, хотя зафиксированная архитектура миграции требует AppKit для поведения 1:1.

### 7.4 Настройка меняется, но фактический backend остаётся старым

`AppDelegate` создаёт `transcriber` и `aiEditor` один раз. `onConfigChanged` сохраняет JSON, обновляет menu и передаёт config в session, но не пересоздаёт сами сервисы. То же касается выбора скачанной модели.

Следствия:

- выбранная модель может вступить в силу только после перезапуска;
- смена local/Gemini/OpenAI может показываться в UI, но не меняться в runtime;
- новый API key не подключает backend автоматически;
- удаление активной модели оставляет живой объект в неопределённом состоянии;
- telemetry/dataset записывают настройку, а не обязательно фактически использованный движок.

### 7.5 Сессия может завершаться дважды

`runWorker()` вызывает `finishCleanup()` после показа popup. Затем Escape вызывает `handleCancel()`, который снова вызывает `finishCleanup()`. Это уже поймано тестом: 20 отменённых сессий превращаются в 40 завершённых.

Параллельно присутствуют ещё два риска:

- `beginStart()` отмечает `isRecording = true`, а `recorder.start()` выполняется в отдельной задаче. Быстрый второй hotkey может сделать stop до фактического старта AVAudioEngine, после чего engine всё же запустится.
- `AudioRecorder.stop()` отменяет consumer и сразу читает ring buffer. Consumer может уже извлечь хвост, увидеть `recording == false` и отбросить его.

### 7.6 Латентность снова может ухудшиться

Python специально убрал принудительный Whisper/Qwen warmup перед первым реальным чанком. В Swift `SessionController.beginStart()` снова вызывает `transcriber.preWarm()` на каждое нажатие hotkey. Это возвращает ранее исправленную причину задержки: synthetic work может конкурировать с первой реальной транскрипцией.

При этом отсутствует полная замена Python-стратегии startup/15-minute/wake/health warmup: maintenance callbacks в `AppDelegate` пока только логируют `not implemented`.

## 8. Целевая архитектура исправлений

### 8.1 Один composition root и одна runtime-конфигурация

Нужен владелец живых сервисов, например `AppServices`/`RuntimeCoordinator`, который:

- хранит единый `Paths` и передаёт его всем компонентам;
- создаёт recorder, transcriber, editor, history, dataset, metrics и menu;
- знает фактически активные backend/model, а не только значения JSON;
- выполняет безопасную реконфигурацию только в `idle`;
- сообщает menu и telemetry результат активации;
- не допускает silent fallback на stub в пользовательской сборке;
- выполняет единый shutdown/flush.

`StubTranscriber` должен остаться только для тестов и явно включаемого demo-режима.

### 8.2 Явная state machine вместо набора независимых Bool

Рекомендуемое состояние:

```text
launching
  → needsPermissions | needsLanguage | needsModel
  → idle
  → starting(sessionID)
  → recording(sessionID)
  → stopping(sessionID)
  → processing(sessionID)
  → popup(sessionID, targetPID)
  → injecting(sessionID)
  → idle
  → failed(recoverable | restartRequired)
```

Дополнительные флаги вроде append-to-popup могут быть ассоциированными данными состояния, но завершение сессии должно проходить через один idempotent `completeSession(id:reason:)`.

### 8.3 Неблокирующий permission coordinator

Wizard должен быть event-driven:

```text
welcome → request microphone → wait/recheck microphone
        → request/open Accessibility → poll asynchronously
        → complete | explicit skip | retry
```

Нельзя держать `runModal()` во время ожидания внешнего TCC-события. Следует использовать sheet/window с callback или отдельный `NSPanel`, а polling выполнять через `Task.sleep`/timer без захвата MainActor между ticks.

### 8.4 Menu view model

Меню должно отображать одно снапшот-состояние:

- session state;
- фактический active backend/model/editor;
- permission statuses;
- download/update state;
- history count и pagination;
- pending suggestion count;
- autostart system status.

Изменения лучше применять точечно или отложенно после завершения menu tracking, а не удалять и строить все items внутри каждого action.

## 9. Пошаговый план работ

### Фаза 0. Зафиксировать воспроизводимый baseline

Цель: отделить реальные регрессии от случайных эффектов dirty worktree, DEBUG paths и подписи.

Работы:

1. Зафиксировать текущий набор незакоммиченных изменений отдельным контролируемым checkpoint после ручной проверки владельцем ветки.
2. Добавить одну команду `scripts/swift_verify.sh`, которая последовательно запускает все package tests, app build и bundle smoke checks.
3. Создать fixtures для config/history/dataset/corrections, не содержащие личные фразы.
4. Описать два режима данных:
   - isolated dev fixture;
   - release-compatible acceptance с явной read-only копией production данных.
5. Не использовать живой production-файл для автоматических тестов.
6. Снять Python baseline по сценариям из раздела 11: menu tree, screenshots, runtime events, ожидаемые переходы состояний, latency samples.
7. Добавить номер build/channel (`DEBUG DEV DATA` или `RELEASE`) в About/diagnostics, чтобы источник данных был виден.

Критерий готовности:

- один verify command воспроизводит текущий результат;
- тесты используют только временную директорию;
- production Python-данные не изменяются;
- для каждого пользовательского сценария есть ожидаемый Python-результат.

### Фаза 1. Вернуть зелёный build/test gate

Цель: любое последующее исправление должно проверяться автоматически.

Работы:

1. Обновить `CNSUI/UIPanelsTests` под текущие init signatures либо сначала вернуть согласованные signatures.
2. Переписать `MenuStructureTests` под целевую структуру без Input Monitoring.
3. Тестировать check state того контрола, который реально рисуется, либо отказаться от custom buttons в пользу нативных `NSMenuItem`.
4. Исправить Swift 6 isolation в `RuntimeHealthTests` через `@MainActor` async tests.
5. Переделать `UpdateCheckerTests` на `URLProtocol`/инъекцию HTTP client, не использовать network-dependent ожидания.
6. Исправить double cleanup и сделать падающий `CNSSession` тест regression guard.
7. Сделать настоящий whisper.cpp golden test обязательным в локальном full suite; в CI разрешить отдельный model-gated job, но не считать skipped проверкой паритета.
8. Включить warnings-as-errors хотя бы для новых/изменяемых Swift targets после очистки текущих warnings.

Критерий готовности:

- все package tests компилируются и проходят;
- app debug/release builds проходят;
- нет skipped critical tests без явно отмеченного CI job;
- verify command возвращает ненулевой exit code при сбое любого пакета.

### Фаза 2. Исправить подпись, TCC и первый запуск

Цель: права выдаются один раз, немедленно отражаются в UI и не исчезают после обычной сборки.

Работы по сборке:

1. Удалить `tccutil reset` из обычного `swift_build_app.sh`.
2. Вынести reset в отдельный явный скрипт `swift_reset_permissions_for_testing.sh` с предупреждением.
3. Для разработки использовать стабильную Apple Development подпись; для distribution — Developer ID + hardened runtime + notarization.
4. Собирать и запускать acceptance `.app` из стабильного пути. Не менять bundle ID и designated requirement между сборками одного канала.
5. Добавить bundle smoke test: `codesign --verify`, `codesign -dv`, entitlements, bundle ID, executable path.

Работы по коду:

1. Превратить `Permissions` в сервис с инъецированным `Paths`; setup flag должен быть `paths.setupDoneFile`.
2. Для первой Accessibility-регистрации вызвать `AXIsProcessTrustedWithOptions` с prompt, затем открыть нужную pane только по запросу пользователя.
3. Переписать wizard без долгого `runModal()`.
4. Отдельно обрабатывать `undetermined`, `denied`, `restricted`, `granted` для microphone.
5. После возврата из System Settings повторно проверять permission, обновлять menu и продолжать flow без рестарта, если Carbon и текущие API это позволяют.
6. Записывать `setup_done` только при:
   - полном успехе;
   - явном выборе Skip.
7. Не записывать flag при timeout, исключении или неполной выдаче прав.
8. После успешного wizard в том же launch показать language picker, а затем model flow; убрать текущий `else if` разрыв.
9. Не запускать запись, пока microphone недоступен; без Accessibility разрешить распознавание только если UX явно предлагает copy вместо injection.
10. Удалить из текстов мастера устаревшее требование Input Monitoring/restart.

Обязательная ручная матрица:

- чистый TCC, оба права `.notDetermined`;
- microphone granted, Accessibility denied;
- microphone denied ранее и включён в Settings во время wizard;
- Accessibility включается при открытом окне ожидания;
- пользователь нажимает Skip;
- timeout без выдачи права;
- повторный запуск с уже выданными правами;
- сборка новой версии поверх старой без TCC reset;
- запуск `.app` после перемещения в Applications;
- системный язык RU, EN, DE.

Критерий готовности:

- ни один сценарий не блокирует main thread более одного run-loop tick;
- status menu обновляется в течение секунды после изменения TCC;
- обычная пересборка не удаляет права;
- неполный wizard повторяется при следующем запуске;
- процесс first-run детерминирован: permissions → language → model → ready.

### Фаза 3. Исправить lifecycle и runtime-реконфигурацию

Цель: выбранные пользователем настройки соответствуют фактически работающим сервисам.

Работы:

1. Ввести `RuntimeCoordinator`/factory для `Transcribing` и `AiEditing`.
2. Хранить `activeConfiguration` отдельно от `desiredConfiguration`.
3. При смене backend/model:
   - проверить prerequisites;
   - дождаться `idle`;
   - остановить/release старый service;
   - создать и warm up новый;
   - только после успеха пометить menu item активным.
4. При ошибке оставить предыдущий рабочий service и показать понятную ошибку.
5. Запретить silent `StubTranscriber` fallback в user build.
6. После ввода API key активировать выбранный cloud backend без перезапуска.
7. После завершения model download валидировать файл и активировать модель через coordinator.
8. При удалении активной модели сначала переключиться на доступный backend или отменить удаление.
9. Передавать фактически использованные backend/model в dataset и telemetry.
10. На terminate/cancel update выполнить stop recorder, cancel tasks/watchdogs/downloads, release model contexts, flush config/log и затем release instance lock.
11. Хранить и invalidation-ить update timer.

Критерий готовности:

- смена модели/backend/editor проверяется в следующей сессии без restart;
- UI не показывает активной настройку, которая не загрузилась;
- missing model/key даёт actionable state, а не пустой transcript;
- завершение приложения не оставляет аудиопотоков и задач.

### Фаза 4. Довести session/audio state machine

Цель: ровно одна запись, один worker и одно завершение на session ID.

Работы:

1. Добавить состояние `starting`; второй hotkey отменяет/дожидается start, но не позволяет AVAudioEngine запуститься после stop.
2. Все callback должны нести `sessionID` и проверять generation перед изменением state/UI.
3. Сделать `completeSession(id:reason:)` idempotent; убрать отдельные конкурирующие cleanup paths.
4. Не увеличивать completed session count при повторном Escape/callback.
5. Удалить неиспользуемый `doFinishCleanup()`.
6. Убрать `preWarm()` с hotkey path.
7. Реализовать startup warmup, 15-minute keepalive, wake prewarm и health-triggered reload только в idle.
8. Заменить unsynchronised `AbortFlag` на атомарное/lock-protected состояние.
9. Синхронизировать остановку consumer task и дренаж ring buffer; final chunk должен включать весь хвост один раз.
10. Отслеживать ring-buffer overflow в privacy-safe telemetry и показывать диагностический warning при повторении.
11. Согласовать fresh-config defaults с Python: `target=4.0`, `max=8.0`, `min=1.0`, `silence=1.0`; fallback значения не должны расходиться.
12. Проверить, что AppKit/AVAudioConverter allocation не выполняет тяжёлую работу в real-time callback; вынести конвертацию/Array allocation из tap, если Instruments подтверждает нагрузку.

Тесты:

- stop до завершения `recorder.start()`;
- 30 быстрых hotkey toggle;
- stop на границе VAD frame;
- final callback одновременно с consumer read;
- stale callback от предыдущей сессии;
- soft timeout и hard timeout;
- Escape/Enter вызываются повторно;
- append-to-popup с сохранением target PID;
- sleep/wake во время idle и recording;
- смена входного устройства/отключение Bluetooth mic.

Критерий готовности:

- `completedSessions` увеличивается ровно один раз;
- ни один sample после stop не попадает в следующую сессию и не теряется из текущего final;
- hotkey никогда не запускает synthetic warmup перед первым real chunk;
- state и status icon проходят одинаковую последовательность.

### Фаза 5. Восстановить menu/status/history UX

Цель: меню визуально и функционально повторяет Python-версию.

Работы по status/menu:

1. Связать state machine с `idle`, `recording`, `processing` menu-bar icons.
2. Обновлять permission parent и child icons при каждом открытии меню и после coordinator event.
3. Добавить/заменить отсутствующий `api-keys` asset; проверить все имена ресурсов автоматическим asset test.
4. Привести размеры/template semantics к Python: template icons для menu bar, цветные status icons там, где цвет несёт смысл.
5. Для model rows вернуть нативные текущая/download/delete states и layout.
6. Для language rows обеспечить правильные radio/check semantics и keyboard navigation.
7. Не перестраивать всё меню внутри action; применять snapshot после закрытия tracking либо точечно обновлять items.
8. Синхронизировать autostart item с реальным `SMAppService.status`, затем сохранять config.
9. Реализовать Revert Terms вместо логирования `not implemented`.
10. Перед Open Log/Config создать файл при отсутствии.
11. Все диалоги, Quit/About/Update/Model download строки перевести через I18n.

Работы по истории:

1. Использовать один инъецированный `PhraseHistory`, а не независимо резолвить пути в разных слоях.
2. После `append()` отправлять событие обновления history submenu/count.
3. Исправить ключ `menu.history_more` → реальный locale key или унифицировать locale schema.
4. Перенести Python UX: copy icon, feedback, pagination без неожиданного закрытия, reset count при следующем открытии.
5. Явно показать, что DEBUG работает с dev fixture.
6. Добавить performance test для 2 000, 20 000 и 100 000 строк без чтения всего файла на main thread.
7. Не логировать содержимое истории.

Критерий готовности:

- menu screenshot/tree соответствует Python baseline для RU/EN и dark/light;
- status icon меняется без задержки;
- history появляется сразу после подтверждения фразы;
- production acceptance видит существующие 1824 строки через release paths;
- menu остаётся отзывчивым при большой истории.

### Фаза 6. Довести STT до production-паритета

Цель: локальная, cloud и file транскрипция дают предсказуемое качество и ошибки.

Локальный whisper.cpp:

1. Сделать real-model golden corpus обязательным перед релизом.
2. Прогнать тот же русско-английский corpus, который использовался в bake-off, через полный app pipeline.
3. Зафиксировать WER, code-switch WER, first/warm decode p50/p95 и memory footprint.
4. Проверить language retry, silence padding, hallucination filters и exact token context в end-to-end режиме.
5. Реализовать отдельные cold/warm deadline semantics и контролируемый abort/reload.
6. Проверить memory pressure и sleep/wake.

Cloud STT:

1. Передавать prompt и language hints согласно контракту backend.
2. Не подменять detected language первым разрешённым языком.
3. Проверять HTTP status и декодировать provider error body без записи audio/text в лог.
4. Установить connect/request/resource timeouts для realtime и file flows отдельно.
5. Определять реальный MIME/filename; не объявлять mp3/m4a как wav.
6. Конвертировать неподдерживаемые контейнеры в согласованный PCM/WAV либо использовать корректный upload endpoint.
7. Добавить retry только для безопасных transient ошибок с bounded backoff.

File flow:

1. Реализовать `WhisperCppTranscriber.transcribeFile`.
2. Добавить Open panel наряду с drag-and-drop.
3. Поддержать форматы, которые поддерживает Python, с явной ошибкой для остальных.
4. Для длинных файлов сделать segmentation, progress и cancellation.
5. Передать initial prompt, dictionary hints и optional AI refinement.
6. Не блокировать MainActor чтением/декодированием файла.

Критерий готовности:

- качество не хуже зафиксированного bake-off/Python допуска;
- отсутствие модели/сети/API key показывает точную причину;
- realtime и file timeout не смешиваются;
- file transcription проходит на коротком, часовом, mp3, m4a и wav fixtures.

### Фаза 7. Реализовать настоящий AI Editor

Цель: local и Gemini повторяют Python statuses, locks и fallback behavior.

Работы:

1. Заменить `LocalAiEditor` stub на MLX Swift/Qwen с реальными весами.
2. Поддержать те же system prompts, known terms и misrecognitions.
3. Реализовать статусы `ok`, `unchanged`, `timeout`, `skipped`, `error`, `disabled` во всех ветках.
4. Сериализовать локальный Whisper/Qwen Metal execution; overlapping refine должен давать `skipped`, а не создавать второй inference.
5. Memory-pressure skip применять только к local editor.
6. Для realtime сохранить жёсткий короткий timeout; для file flow — blocking acquisition и длинный timeout.
7. Для длинного локального текста резать только по границам предложений с budget, эквивалентным Python.
8. Для Gemini создать отдельные URLSession policies для realtime и file; проверить 5-minute file timeout.
9. Lock cloud editor должен оставаться занят до фактического завершения HTTP request даже если вызывающий realtime path уже получил timeout.
10. Применять manual replacements в том же месте pipeline, что Python.
11. Пересоздавать editor при смене backend/model/key через RuntimeCoordinator.

Критерий готовности:

- golden edit corpus совпадает с допустимым Python behavior;
- два одновременных запроса не перекрываются;
- timeout не блокирует следующую сессию навсегда;
- memory pressure не пропускает cloud editor;
- dataset записывает правильный status и фактическую model.

### Фаза 8. Подключить словарь, suggestions, prompt и maintenance

Цель: после подтверждения текста система учится и обслуживает данные так же, как Python.

Работы:

1. После успешного user flow вызвать `updateTermUsage`, включая реактивацию inactive terms.
2. Использовать инъецированные paths для corrections/dataset, не вызывать `Paths.resolveDefault()` внутри session.
3. Запускать prompt analysis каждые N фраз с теми же primary/additional thresholds и lookback.
4. Полностью перенести suggest/auto/disabled modes.
5. Исправить schema mapping `correction_count`/`frequency_count` в Suggestions panel.
6. После accept/reject/add/delete/revert всегда:
   - канонизировать identity;
   - обновить `user_terms`/`skipped_terms`/snapshot;
   - перестроить `initial_prompt`;
   - атомарно сохранить config;
   - синхронизировать prompt text file;
   - обновить menu/panel.
7. Реализовать startup pending-suggestions alert и badge.
8. В Terms panel показать source, last seen, use count, inactive; добавить фильтры и безопасные действия.
9. Довести Replacements panel до ручных и автоматических пар, редактирования и сохранения.
10. Реализовать prompt-file watcher и защиту от пустого файла.
11. Подключить scheduler:
   - dirty config flush каждые 60 s;
   - decay/metrics не чаще 24 h;
   - metrics notification throttle;
   - flush перед model reload/terminate.
12. Довести Statistics UI до Python-набора метрик и истории.

Критерий готовности:

- один полный цикл «ошибка Whisper → правка → corrections → suggestion → accept → prompt» воспроизводится тестом;
- manual terms не decay;
- rejected term не предлагается 150 фраз;
- пустой prompt file не уничтожает непустой словарь;
- scheduler не запускает duplicate maintenance.

### Фаза 9. Довести остальные окна, i18n и accessibility

Цель: одинаковое поведение и понятный интерфейс во всех поддерживаемых языках.

Работы:

1. Вернуться к зафиксированному AppKit-подходу для Language/Suggestions/Terms/Replacements/File panels либо официально пересмотреть архитектурное решение. Для паритета с существующим UI предпочтителен AppKit.
2. Убрать hardcoded English из SwiftUI/AppKit views.
3. Проверить все locale keys статическим тестом: код → все locale files → отсутствие orphan/missing keys.
4. Language picker должен появляться в первый запуск после permissions, поддерживать тот же набор языков и auto-detect semantics.
5. Preview popup позиционировать на экране с активным приложением/мышью, а не всегда `NSScreen.main`.
6. После fade действительно `orderOut`, не оставлять невидимое окно.
7. Локализовать context menu Add to Dictionary.
8. Проверить VoiceOver labels, Full Keyboard Access, контраст, Reduce Motion и font scaling.
9. Провести screenshot regression для light/dark, 1x/2x, одного и двух мониторов.

Критерий готовности:

- нет видимых raw localization keys;
- нет hardcoded English вне diagnostic/dev UI;
- окна не теряются на втором мониторе;
- все операции доступны с клавиатуры и VoiceOver.

### Фаза 10. Models, autostart, update и distribution hardening

Цель: безопасная установка и обновление production `.app`.

Работы:

1. Проверять ожидаемый размер и checksum модели до активации; файл `>1 MB` не является достаточной проверкой.
2. Хранить resume metadata так, чтобы загрузку можно было продолжить после relaunch, либо явно очищать partial file.
3. Удалять модели по одной; активную модель защищать.
4. Синхронизировать `config.autostart` с реальным `SMAppService.status`.
5. Для updater использовать writable staging directory, а не предполагать запись в `/Applications`.
6. Перед заменой приложения проверять Team ID, bundle ID, designated requirement, code signature и notarization ticket.
7. Не снимать quarantine как замену корректной notarization.
8. Сделать swap атомарным и recoverable: backup → replace → launch validation → rollback при ошибке.
9. Подписать вложенные библиотеки/Metal resources/исполняемые файлы правильным порядком, проверить `codesign --deep --strict` только как validation, не как стратегию подписи.
10. Собрать DMG, проверить clean-machine install и update с предыдущей версией.

Критерий готовности:

- clean macOS user может установить, выдать права, перезапустить и обновить приложение;
- TCC переживает update с той же идентичностью подписи;
- повреждённая/подменённая модель или app update не активируется;
- неудачный update автоматически откатывается.

### Фаза 11. Финальная parity-приёмка и cutover

Цель: доказать, что Swift можно сделать основной версией без потери данных и поведения.

Работы:

1. Прогнать все сценарии раздела 11 сначала на Python, затем на Swift release candidate.
2. Сравнить качество STT, latency p50/p95, memory, energy, crash/hang rate.
3. Провести 8-часовой soak: записи, idle, sleep/wake, model/editor switches, network loss.
4. Проверить совместимость на копиях config schema v1-v9 и больших history/dataset.
5. Сделать read/write round trip Swift → Python на fixtures.
6. Провести dogfood период с отдельным backup/rollback.
7. Только после выполнения Definition of Done переключить основной build/distribution на Swift.
8. Python оставить доступным как rollback на один релизный цикл; не удалять его в том же релизе, где произошёл cutover.

## 10. Рекомендуемый порядок pull requests

Чтобы изменения оставались проверяемыми, не объединять всё в один PR:

1. Test gate и fixtures.
2. Build signing без автоматического TCC reset.
3. PermissionCoordinator и first-run orchestration.
4. Session exactly-once cleanup + audio start/stop race.
5. RuntimeCoordinator и live model/backend switch.
6. Status/menu state model и asset/localization checks.
7. History parity.
8. Local/cloud/file STT parity.
9. Local/Gemini editor parity.
10. Dictionary/prompt/maintenance integration.
11. Remaining panels/i18n/accessibility.
12. Updater/distribution hardening.
13. Final E2E/soak/cutover.

Каждый PR должен оставлять весь verify suite зелёным и содержать regression test на исправленный дефект.

## 11. Обязательный набор пользовательских сценариев

### Первый запуск и права

1. Чистая установка без TCC записей.
2. Все права уже выданы.
3. Microphone ранее denied.
4. Accessibility ранее denied.
5. Право включается, пока открыта System Settings.
6. Пользователь закрывает Settings без выдачи права.
7. Пользователь выбирает Skip.
8. Повторный запуск после incomplete wizard.
9. Обновление приложения без повторной выдачи TCC.

### Запись и popup

1. Короткая фраза, длинная фраза, только тишина.
2. Несколько VAD-чанков и остановка во время decode.
3. Быстрый двойной hotkey.
4. Hotkey во время processing должен быть заблокирован.
5. Hotkey при открытом popup дописывает текст.
6. Enter подтверждает; Escape отменяет; пустой текст не инжектируется.
7. ⌘D добавляет выделение и слово под кареткой.
8. Target application меняется во время popup, но вставка идёт в исходное окно.
9. Пользователь копирует новый clipboard content во время injection — он не затирается restore.
10. Accessibility исчезает между записью и injection — текст остаётся доступен для copy/retry.

### Модели и редакторы

1. Local model отсутствует.
2. Download success/cancel/network failure/resume.
3. Switch local → Gemini → OpenAI → local без restart.
4. API key отсутствует/неверен/обновлён.
5. Local AI enabled/disabled/timeout/memory pressure.
6. Два refine запроса перекрываются.
7. Модель удаляется или повреждается.

### Данные и меню

1. History: 0, 1, 5, 6, 2 000 и 100 000 фраз.
2. Copy phrase и Show More без неправильного закрытия меню.
3. Config reload после внешнего изменения.
4. Prompt add/delete/revert/file edit/empty file.
5. Suggestions accept/reject/add all/later/auto.
6. Decay, reactivation и cooldown.
7. Statistics и daily notification throttle.
8. Light/dark mode, Retina, второй монитор, RU/EN/DE.

### Жизненный цикл

1. Quit во время recording, processing, download и update.
2. Sleep/wake в idle и recording.
3. Microphone device disconnect.
4. Network исчезает во время cloud request.
5. 20+ сессий и health-triggered model reload.
6. Долгий idle и первый cold decode.

## 12. Автоматизированная стратегия тестирования

### Unit

- config migrations и path modes;
- permission state transitions без реального TCC;
- state machine exact-once transitions;
- VAD boundaries/audio final drain;
- context, language hints, guards, hallucination filters;
- editor statuses/locks/timeouts;
- dictionary canonicalization/decay/cooldown;
- menu snapshot и locale asset/key completeness.

### Integration

- SessionController с controllable fake recorder/transcriber/editor/panel;
- URLProtocol fixtures для Gemini/OpenAI/update/model download;
- temporary filesystem для config/history/dataset/corrections/prompt sync;
- app composition test: Config change пересоздаёт service и сохраняет active state;
- injection с fake workspace/pasteboard/keyboard adapters.

### System/manual

TCC, AVAudioEngine, Carbon hotkey, multi-monitor AppKit, Keychain, SMAppService, code signing и notarization нельзя достоверно закрыть только unit-тестами. Для них нужен подписанный release-candidate и отдельный manual checklist с приложенными логами без пользовательского текста.

### Performance

Зафиксировать budgets относительно Python baseline:

- hotkey → recording HUD;
- stop → interactive popup p50/p95;
- warm/cold Whisper decode;
- menu open с большой history;
- resident memory после startup, 1, 20 и 100 сессий;
- audio callback duration/overflow count;
- energy impact в idle и recording.

## 13. Definition of Done для Swift-паритета

Swift-миграция считается готовой только когда одновременно выполнено следующее:

- все Swift package/app tests зелёные;
- critical real-model и E2E tests не skipped;
- обычная build/update процедура не сбрасывает TCC;
- wizard проходит всю manual permission matrix без hang;
- history, config, dictionary, corrections, metrics и prompt files совместимы с Python;
- все menu actions имеют рабочий backend, а не только меняют checkbox;
- local STT, cloud STT, file transcription, local editor и Gemini реально работают;
- session cleanup exactly-once, нет stale audio/text и потери final tail;
- menu/status/icons/history визуально согласованы с Python baseline;
- daily maintenance и warmup/health lifecycle подключены;
- clean install, update и rollback проверены на подписанном/notarized `.app`;
- soak test не выявляет hang, orphan task, audio stream leak или неконтролируемый рост памяти;
- Python fallback сохранён на переходный релизный цикл.

## 14. Что сознательно не делать до выполнения P0/P1

- Не удалять Python-реализацию.
- Не переводить production distribution на Swift.
- Не подключать Swift DEBUG к единственной живой копии пользовательских данных.
- Не маскировать отсутствие модели/API key через `StubTranscriber`.
- Не добавлять новые функции до восстановления зелёного test gate и permission flow.
- Не «лечить» TCC регулярным `tccutil reset`.
- Не переписывать проверенные пакеты без regression evidence; исправлять интеграцию вокруг них.

## 15. Первая практическая итерация

Наиболее эффективный первый рабочий пакет:

1. Убрать TCC reset из normal build.
2. Сделать `Permissions` зависимым от `Paths`.
3. Переписать Accessibility wait без блокирующего `runModal`.
4. Исправить semantics `setup_done` и цепочку wizard → language picker.
5. Исправить падающие/не компилирующиеся тесты.
6. Устранить double cleanup в session.
7. Добавить app state → status icon binding.
8. Явно показывать dev data mode и подключить history fixture.

После этой итерации приложение ещё не достигнет полного паритета, но перестанет создавать ложное впечатление случайных прав, зависаний, пустой истории и несогласованного статуса. Это даст стабильную основу для STT/AI/dictionary этапов.
