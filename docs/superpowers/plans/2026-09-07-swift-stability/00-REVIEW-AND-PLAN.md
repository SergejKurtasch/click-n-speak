# Аудит Swift и план стабилизации Click-n-speak

> Для исполнителя: применять `executing-plans` по одному файлу эпохи. Использовать флажки для прогресса. Этот запрос включает ревью и подготовку плана; исправления приложения ещё не применялись.

**Цель:** устранить потерю данных и гонки Swift-приложения, затем подтвердить паритет пользовательских сценариев с Python.

**Архитектура:** сохранить существующие SwiftPM-пакеты. Исправить контракты между владельцами конфигурации, сессии и runtime; стабилизировать их до дальнейшего развития UI.

**Стек:** Swift 6, AppKit/SwiftUI, AVFoundation, whisper.cpp, MLX Swift; Python из проектного `venv` для acceptance.

**Спецификация:** настоящий документ — актуальная спецификация исправлений. Поведенческий референс — текущие `main.py` и `src/`; прежний аудит от 2026-08-29 — исторический материал.

**Проверенный снимок:** `31cf399`, ветка `swift_migration`, 2026-09-07. До аудита рабочее дерево было чистым. Номера строк ниже относятся к этому снимку.

## Ограничения для всех эпох

- Ответы и планы — по-русски; код, комментарии и сообщения коммитов — по-английски.
- Перед любой тестовой командой: `source venv/bin/activate`. Если активация не удалась, тесты не запускать.
- Реальные пользовательские config, dataset, corrections, clipboard и TCC не использовать в автоматических регрессиях.
- Работать с временным `CNS_DATA_DIR`; не переводить DEBUG на production paths.
- Не менять Python-референс ради прохождения Swift-проверок. Обнаруженные общие дефекты отмечать отдельно.
- Не ослаблять frozen quality thresholds и не считать пропущенные release-critical проверки успешными.
- При выполнении эпохи сохранять неизвестные JSON-поля и решения `manual_replacements`, `approved_auto_replacements`, `rejected_replacements`.
- Обычную политику TCC из текущего AGENTS.md не менять неявно. Для автоматической acceptance-сборки явно передавать `CNS_RESET_TCC_AFTER_BUILD=0`.
- Перед коммитом проверить `.gitignore` и staged diff на секреты; Conventional Commits. После успешного коммита применить `update-Codex-md`.

## Вывод и границы проверки

Swift уже содержит настоящие STT, локальный Qwen, cloud-клиенты, файловую транскрипцию, словарь, updater и развитый UI. Старые утверждения «редактор — заглушка», «файловой транскрипции нет», «тесты не компилируются» больше не соответствуют коду.

Но считать перенос завершённым рано: найдены **15 замечаний — 8 P1 и 7 P2**. Первые десять замечаний подтверждены **11 падающими регрессионными сценариями**; ещё пять установлены трассировкой production-кода. P1 означает исправление до следующего стабильного выпуска; P2 — необходимая работа по надёжности/паритету. P0 в проверенном объёме не установлен.

Проверены composition root, session/runtime routing, recorder/chunker, insertion, STT/editor paths, config/dictionary persistence, основные UI-пути, model downloads, updater/helper и acceptance/soak. Это статическое ревью плюс тесты контрактов. Реальная запись через микрофон, TCC, вставка в чужое приложение, живые API, долгий GPU-прогон и подписанное обновление в этом аудите не выполнялись.

## Фактические проверки

| Проверка | Результат нового прогона |
|---|---|
| `source venv/bin/activate && bash scripts/swift_verify.sh` | **373 теста прошли**, 8 пакетов и executable; exit 0 |
| `source venv/bin/activate && python -m pytest -q tests/parity` | **6 passed**, exit 0 |
| Дополнительные runtime/startup probes | **5 тестов упали**, 5 ожидаемых проверок нарушены |
| Дополнительные session probes | **6 тестов упали**, 7 ожидаемых проверок нарушены |
| Whisper/Qwen real-model jobs | Не запускались; нужны явные пути моделей |
| Release `.app`/DMG, TCC, external acceptance, 8-hour soak | Не запускались; прежние результаты не объявляются новой проверкой |

Сумма Swift-тестов по компонентам: Core 96, Audio 28, Input 17, Editors 15, Transcription 53, Dictionary 60, Session 37, UI 55, executable 12. Учитываются XCTest и Swift Testing; строка XCTest «0 tests» не означает отсутствие Swift Testing-тестов.

Логи текущего аудита: `/private/tmp/cns-review-swift-verify-20260907.log`, `/private/tmp/cns-review-python-parity-20260907.log`, `/private/tmp/cns-review-runtime-probes-20260907.log`, `/private/tmp/cns-review-session-probes-20260907.log`. Это временные артефакты, не пользовательские данные.

Полные исходники воспроизведений сохранены в `scripts/review_swift_20260907/RuntimeAuditProbes.swift` и `SessionAuditProbes.swift`. Они намеренно находятся вне тестовых targets. При выполнении эпох переносить относящиеся к ней тесты в соответствующий target, сохраняя проверки ожидаемого поведения. Не переносить все красные тесты одновременно в обязательный gate ранней эпохи.

## Подтверждённые замечания

### R01 · P1 · Повреждённый config перезаписывается при запуске

**Место:** [Config.swift:24](../../../../Packages/CNSCore/Sources/CNSCore/Config.swift), [AppDelegate.swift:62](../../../../ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift), [DictionaryCoordinator.swift:1058](../../../../Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift).

`Config.load` превращает и отсутствие файла, и ошибку чтения/JSON в дефолт. `initializeReplacementPolicyIfNeeded` затем дважды сохраняет этот дефолт поверх исходного config. Проверка совместимости покрывает только чтение, поэтому не замечает разрушительную последовательность запуска.

**Воспроизведение:** файл `{"user_terms": damaged`; вызвать тот же bootstrap, что использует AppDelegate. Исходные байты изменяются. Теряются сохранённые термины и replacement approvals/rejections, включая запреты повторного обучения.

**Исправление:** throwing load с различением missing/corrupt/unreadable; не запускать пишущих координаторов до успешного чтения. Исходник сохранить, показать восстановление/выбор резервной копии. Подробности и код — эпоха 01, задача 1.

### R02 · P2 · Использование терминов обновляется в памяти, но не сохраняется

**Место:** [DictionaryCoordinator.swift:300](../../../../Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift), [AppDelegate.swift:195](../../../../ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift), [AppRuntimeCoordinator.swift:161](../../../../ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift).

После `updateUsage` устанавливается `dirty = true`, публикуется snapshot. AppDelegate передаёт его в `adoptPersistedConfiguration`, тот вызывает `onConfigActivated`, который возвращает snapshot в `adoptConfiguration`; там `dirty = false`. Записи на диск между этими действиями нет. `flushIfNeeded` после такого круга ничего не делает.

**Воспроизведение:** произнести существующий manual-термин один раз, выполнить flush. В памяти `use_count = 1`, на диске `0`, расходятся и `last_seen`. Реактивация/decay после рестарта опираются на устаревшие значения. Эпоха 01, задача 2: отделить уведомление об изменении от подтверждения долговременной записи; не возвращать владельцу его же unsaved snapshot как persisted.

### R03 · P1 · Состояния файла и вставки не блокируют новую запись

**Место:** [SessionController.swift:223](../../../../Packages/CNSSession/Sources/CNSSession/SessionController.swift), `isProcessing` около строки 81, `transcribeFile` около 900.

`toggle` блокирует только `.stopping/.processing`; `fileJobActive` и `.injecting` пропускаются. При файловой транскрипции state остаётся `.idle`. Можно одновременно запустить микрофон и файл; общий `abortInFlight` теряет однозначную цель. Нажатие hotkey между Enter и завершением вставки запускает новую сессию до восстановления фокуса старой.

**Воспроизведения:** удержать fake file-job на continuation и нажать hotkey — `startCount = 1` вместо 0; подтвердить попап и сразу нажать hotkey — `startCount = 2` вместо 1. Эпоха 02, задача 1: явная таблица допустимых переходов и единый признак занятости для записи, файла, вставки и замены runtime.

### R04 · P1 · Дописывание тишины уничтожает открытый попап

**Место:** [SessionController.swift:545](../../../../Packages/CNSSession/Sources/CNSSession/SessionController.swift), [PreviewPanel.swift:213](../../../../Packages/CNSUI/Sources/CNSUI/PreviewPanel.swift).

В ветке пустого `fullText` вызывается `panel.hide`. Для interactive-панели это немедленный `teardownInteractive`, даже когда текущая запись лишь дополняет уже готовый текст.

**Воспроизведение:** первая фраза → попап → hotkey → тишина → stop. Попап закрыт, первую фразу подтвердить нельзя. При Enter/Escape во время append есть смежный риск: UI закрывается до того, как `claimPopupOutcome` отвергает событие вне `.popup`. Эпоха 02, задача 2: сохранить draft; временно согласовать доступность действий панели и session state.

### R05 · P2 · Append искажает исходные данные обучения

**Место:** [SessionController.swift:259](../../../../Packages/CNSSession/Sources/CNSSession/SessionController.swift), `handleConfirm` около 660.

Каждая дополнительная запись очищает `rawChunks` и меняет runtime metadata; финальная панель содержит все записи. Dataset получает `raw_whisper = second`, но `user_final = first second`. Анализатор рассматривает первую фразу как пользовательскую вставку, искажая candidates и edit-score.

**Воспроизведение:** append двух записей `first` и `second`, затем Enter; raw содержит только `second`. Аналогичный сброс raw есть и в Python `start_recording`: это долг общего поведения, а не исключительно регрессия Swift. Не переносить этот дефект как требование паритета. Эпоха 02, задача 2: draft с provenance всех частей, одной записью подтверждения и достоверными полями.

### R06 · P1 · Потерянный средний чанк скрывается успешным результатом

**Место:** [SessionController.swift:509](../../../../Packages/CNSSession/Sources/CNSSession/SessionController.swift), `finalize` около 545, `completeSession` около 619.

Ошибка записывается в `lastTranscriptionError`, но показывается только если весь результат пуст. Если первая и третья части распознаны, пользователь получает их склейку без предупреждения о пропущенной середине.

**Воспроизведение:** `success(first) → failed(decode) → success(third)`. Панель: `first third`; статусы: `Transcribing…, Ready`. Эпоха 02, задача 3: сохранять chunk outcome, показывать неполноту, давать восстановить/повторить потерянный фрагмент, не считать такой результат чистой обучающей парой.

### R07 · P1 · Shutdown не инвалидирует продолжающуюся работу

**Место:** [SessionController.swift:206](../../../../Packages/CNSSession/Sources/CNSSession/SessionController.swift), `finalize` после `await editor.refine`, [AppDelegate.swift:384](../../../../ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift).

Отмена task не гарантирует, что collaborator перестал возвращать результат. Shutdown не меняет session generation; после `await` в `finalize` нет проверки shutdown/cancellation. Worker может снова показать панель и перевести state в `.popup`. Не отслеживаются также все задачи persistence/injection/file-job для завершения приложения.

**Воспроизведение:** остановить приложение, пока fake editor ждёт; позднее завершение снова открывает попап и меняет `.idle` на `.popup`. Эпоха 02, задача 4: отдельная terminal phase/generation, запрет публикаций после неё, отслеживание задач и ограниченное ожидание завершения.

### R08 · P1 · Кандидат runtime устанавливается в уже начавшуюся запись

**Место:** [AppRuntimeCoordinator.swift:201](../../../../ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift), `commitPreparedRuntime` около 284; routers в CNSTranscription/CNSEditors.

Idle проверяется до длительного `prepare`, но не резервируется на commit. Пока модель готовится, работающий runtime разрешает новую запись. После подготовки router меняется без повторного ожидания. Router фиксирует сервис для отдельного вызова, а не для всей сессии, поэтому следующие чанки/редактор могут работать уже другим сервисом. Dataset при этом использует descriptor от начала сессии.

**Воспроизведение:** заблокировать `prepare`, начать запись, разрешить `prepare`. Router меняется Gemini → OpenAI, несмотря на `isRuntimeIdle = false`. Дополнительно два последовательных `await install` не обеспечивают атомарность пары STT/editor при supersede. Эпоха 03, задача 1: эксклюзивный commit lease, повторная проверка idle и согласованный runtime bundle.

### R09 · P2 · Смена API-ключа активного backend не обновляет клиента

**Место:** [AppRuntimeCoordinator.swift:118](../../../../ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift), `revalidateDesiredConfiguration` около 132, factory/clients с immutable `apiKey`.

Revalidation повторяет ту же config; `RuntimeSelection` не меняется, срабатывает data-only fast path. Для уже активного Gemini/OpenAI клиент не пересоздаётся ни при исправлении ключа, ни при его удалении. Старый секрет остаётся в памяти клиента.

**Воспроизведение:** initial activation → revalidation; factory вызван один раз вместо двух. Существующий тест проверяет только ранее неактивный failed backend. Эпоха 03, задача 2: явные причины revalidation и отдельная credential generation без самих секретов в config/логах.

### R10 · P2 · Языковые настройки расходятся с effective prompt

**Место:** [MenuBarController.swift:974](../../../../Packages/CNSUI/Sources/CNSUI/MenuBarController.swift), data-only activation в AppRuntimeCoordinator, `adoptConfiguration` в DictionaryCoordinator.

Меню меняет `primary_language`/`additional_languages`, но не перестраивает `initial_prompt`. В отличие от Python `_apply_primary_language`, выбор языка не выключает auto-detect. Список дополнительных языков преобразуется через unordered Set. Локализация меню и SessionStrings также фиксируется при старте — нужен явный контракт её обновления либо требования рестарта.

**Воспроизведение:** русские и немецкие термины, ru → de. На диске остаётся `Русский язык. словарь`; ожидается `Deutscher Text. Wörterbuch`. Эпоха 03, задача 3: одна транзакция языковых настроек, rebuild prompt/files, стабильный порядок и согласованное UI-поведение.

### R11 · P2 · UI принимает форматы, которые отвергает backend

**Место:** [FileDropPanel.swift:250](../../../../Packages/CNSUI/Sources/CNSUI/FileDropPanel.swift), [FileTranscription.swift:27](../../../../Packages/CNSTranscription/Sources/CNSTranscription/FileTranscription.swift), `MediaAudioSegmentReader.open` около 44.

UI разрешает `ogg`, `opus`, `caf`; `FileMediaType` их не распознаёт. Local и cloud пути используют эту проверку до декодирования/отправки. Настоящий Ogg/Caf не пройдёт даже при наличии аудиотрека. Тесты проверяют перечень расширений UI отдельно от backend.

**Воспроизведение по коду:** файл `voice.ogg` с заголовком `OggS`: UI принимает, `FileMediaType.detect` возвращает nil. Эпоха 04, задача 1: общий каталог capabilities плюс сквозные fixtures. Python также зависит от доступных Core Audio декодеров: сначала сравнить реальные файлы, а не только объявленные расширения. Для CAF и прочих доступных форматов реализовать сквозное декодирование, не просто переименовывать расширение/MIME.

### R12 · P1 · Загрузчик бесконечно повторяет ошибочный GET

**Место:** [ModelDownloader.swift:627](../../../../Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift), `handleRejectedResume` около 291, `didReceive data` около 657.

Любой неподходящий HTTP-ответ считается отказом resume. Даже при `offset = 0` новый GET с 403/404/500 вызывает fresh retry, который повторяет тот же путь без лимита. HEAD может быть успешным, а GET — нет: это достаточно для цикла. При неизвестном Content-Length поток ещё и не ограничен `expectedSize` до записи на диск.

**Исправление:** отдельно классифицировать HTTP failure и resume rejection; один fresh retry только для настоящего ranged request, ограниченные transient retries с backoff; проверять суммарные байты до `write`. Эпоха 04, задача 2. Живой сетевой сбой в аудите не инсценировался.

### R13 · P1 · Update helper меняет приложение, не убедившись в выходе процесса

**Место:** [CNSUpdateHelper/main.swift:72](../../../../ClickNSpeak/Sources/CNSUpdateHelper/main.swift), rollback около 104, [RecoverableAppSwap.swift:110](../../../../Packages/CNSCore/Sources/CNSCore/RecoverableAppSwap.swift).

После максимум 30 секунд ожидания helper безусловно продолжает swap, даже если `kill(parentPID, 0)` ещё подтверждает живой процесс. На rollback отправляется `terminate()` всем приложениям с bundle ID и сразу меняются файлы без ожидания завершения. `rollback` удаляет target до проверки существования backup.

**Сценарий:** shutdown завис в inference; helper заменяет bundle работающего приложения, новый экземпляр не получает single-instance lock, ack не приходит, начинается rollback поверх ещё живых процессов. Эпоха 05, задача 1: process-exit prerequisite, точное владение PID/URL и обратимые файловые шаги. Реальный swap на машине пользователя не выполнялся.

### R14 · P2 · Уведомления об ошибках вставки не подключены

**Место:** [AppDelegate.swift:148](../../../../ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift), [SystemTextDelivery.swift:22](../../../../Packages/CNSInput/Sources/CNSInput/SystemTextDelivery.swift).

AppDelegate создаёт `SystemTextDelivery(log: log)`, оставляя `notify` пустым closure. При исчезнувшем target/focus timeout текст копируется в clipboard, но обещанное сообщение пользователю не приходит. При отказе Accessibility попап уже закрыт, а вызов уведомления также ничего не делает. Рядом отсутствует app-level уведомление о `.memoryPressure` локального редактора, которое было в Python.

**Исправление:** передать адаптер `UserNotificationService`, локализовать исходы и сохранить возможность восстановить недоставленный draft. Эпоха 02, задача 4; для memory pressure — эпоха 03, задача 4.

### R15 · P2 · Диагностика и acceptance дают неполное доказательство устойчивости

**Место:** [RuntimeTelemetry.swift:32](../../../../Packages/CNSCore/Sources/CNSCore/RuntimeTelemetry.swift), [swift_acceptance.py:266](../../../../scripts/swift_acceptance.py), [analyze_swift_soak.py:51](../../../../scripts/analyze_swift_soak.py).

`runtime_event` печатается в stdout, а штатный FileLogger обслуживает другие сообщения; связи с `paths.logFile` в app нет. Soak-протокол требует runtime events в app log. Analyzer считает session IDs без идентификатора запуска: после перезапуска IDs снова начинаются с 1. `local_editor_p95_seconds` собирается из всех editor events, включая Gemini. Manual evidence принимает произвольную непустую строку без проверки существования артефакта, commit/hash кандидата. Автоматическая acceptance вызывает build script со сбросом TCC по умолчанию, несмотря на название «non-destructive».

**Исправление:** общий content-free sink, run/session identity, корректное разделение метрик и проверяемая привязка evidence к кандидату; acceptance явно сохраняет TCC. Эпоха 06, задачи 1–2. Не путать существующие 25 passed scenario flags с 25 отдельными end-to-end испытаниями: многие опираются на один `swift_fast` gate.

## Технический долг и ещё не доказанные риски

Это отдельный список, не дополнительные «подтверждённые падения».

1. **GPU lifecycle и восстановление (существенный риск).** Shared gate охватывает `transcribe`/`refine`, но `WhisperCppTranscriber.decodeSilence/prepare/tokenCount` и `LocalAiEditor.prepare/stop` обходят его. `warmupIfIdle` не проверяет fileJobActive; после caller timeout фактическая GPU-задача может ещё держать lease. Abort callback кооперативный; `await reload/stop` не может прервать намертво зависший native вызов. Нужны проверки lifecycle и отдельное решение по helper process после fault injection; перенос Python watchdog сам по себе не завершён.
2. **Audio device lifecycle (существенный риск).** В AudioRecorder нет явного обработчика смены устройства/AVAudioEngine configuration change, converter optional может приводить к молчаливому пропуску tap. Есть тесты pure chunker/watchdog, но нет полноценных проверок реальной input graph. Нужна матрица отключения устройства, sleep/wake, отказа start/stop и timeout с понятным recoverable state.
3. **Память больших сессий (заметное влияние).** `AsyncStream` чанков `.unbounded`; offline/slow backend может накопить много audio. `CorrectionAnalyzer.getOpcodes` выделяет матрицу O(m×n): одна подтверждённая 10 000-token пара требует порядка 100 млн Int-ячеек, около 800 MB только полезных данных матрицы. Добавить bounded policy и большие fixtures; не допускать молчаливого отбрасывания аудио.
4. **Файлы и публикация snapshot.** Prompt analysis читает existing/skipped/mode перед `await`, затем применяет результат к уже изменившемуся snapshot без revision-проверки; параллельная правка/отклонение кандидата требует повторной валидации. Metrics append выполняется в отдельных detached tasks, хотя persistence worker для correction index уже сериализован. Нужны interleaving tests, прежде чем расширять API панелей.
5. **Монолитные владельцы.** MenuBarController — 1681 строка, DictionaryCoordinator — 1370, SessionController — 983. Извлекать только стабильные роли при исправлениях: file-job, popup draft, config publication, update lifecycle. Не делать массовый косметический рефакторинг перед регрессиями.
6. **Документы расходятся.** IMPLEMENTATION_STATUS по-прежнему говорит, что обычные сборки не сбрасывают TCC и что cutover не выполнен, тогда как актуальный AGENTS.md описывает Swift как поставляемое приложение и разрешает reset в dev. Обновить статус по фактическим gate результатам; различать «код написан» и «принято на подписанной сборке».

## Матрица паритета

| Подсистема | Что уже есть | Что остаётся |
|---|---|---|
| Launch/permissions | Асинхронный wizard, single-instance, отдельные dev paths | R01, signed first-run/revoke/regrant/update matrix |
| Hotkey/injection | Carbon, два stable PID checks, clipboard changeCount | R03/R14; реальные приложения и отзыв Accessibility |
| Recording/chunks | FVAD, 16 kHz, drain/final guards, defaults 1/4/8/1 | R04/R06/R07; устройство, overflow, долгий decode |
| STT/editor | Реальные local/cloud backends, runtime descriptors, timeout wrappers | R08/R09, lifecycle gate; новые real-model/live-provider результаты |
| Language/dictionary | Миграции v10, canonical terms, decay, approval/rejection policy | R02/R05/R10; concurrent analysis и long draft |
| File transcription | Segments, progress, refine, Copy/Save | R03/R11; cancel/reopen/late progress и длинные файлы; Python auto-export Markdown/clipboard заменён явными действиями и требует фиксации продуктового контракта |
| UI | Локали, панели, history, multi-display placement | Согласование действий append, локализация после смены языка, VoiceOver/Retina |
| Downloads/updates | Pinned sizes/hashes, resume, signature verification, swap backup | R12/R13; реальный signed update и network failures |
| Acceptance/observability | Общий fast gate, parity schemas, frozen thresholds, soak tooling | R15; свежие доказательства и исправление метрик |

**Намеренные отличия, которые не нужно «исправлять»:** Carbon hotkey требует Microphone/Accessibility без Python Input Monitoring; Swift DEBUG использует изолированные данные; локальный Whisper работает через whisper.cpp, Qwen — MLX Swift; UI может быть нативнее Python. Эти различия допустимы при сохранности текста и проверенном пользовательском поведении. Процессная изоляция Python требует отдельной оценки устойчивости, а не механического копирования.

## Порядок исполнения

| Эпоха | Файл | Результат | Зависимости |
|---|---|---|---|
| 01 | [Данные и конфигурация](01-DATA-AND-CONFIG.md) | Исходные файлы и dirty updates сохраняются | Нет |
| 02 | [Сессии и текст](02-SESSION-AND-TEXT.md) | Однозначная занятость, целый draft, безопасный shutdown | 01 |
| 03 | [Runtime, языки и GPU](03-RUNTIME-AND-LANGUAGE.md) | Атомарная активация и обновление ключей/языков | 01–02 |
| 04 | [Файлы и загрузки](04-FILES-AND-DOWNLOADS.md) | Сквозные форматы и bounded transfer | 02–03 |
| 05 | [Обновление приложения](05-UPDATE-LIFECYCLE.md) | Swap/rollback только после выхода нужных процессов | 02 |
| 06 | [Диагностика и приёмка](06-OBSERVABILITY-AND-ACCEPTANCE.md) | Проверяемый release decision для конкретной сборки | 01–05 |

Запрос для следующего запуска: **«Выполни эпоху 01 из docs/superpowers/plans/2026-09-07-swift-stability/01-DATA-AND-CONFIG.md. Сначала прочитай 00-REVIEW-AND-PLAN.md. Исправляй и проверяй только эту эпоху».** Аналогично менять номер. После каждой эпохи оставить проходящий обязательный gate; не начинать следующую автоматически без соответствующего задания.

## Что сделано хорошо

Разделение на пакеты и инъекция зависимостей позволяют воспроизводить ошибки без моделей и пользовательских данных. Factual descriptors, атомарные файлы, generation-scoped abort, clipboard restoration по `changeCount`, pinned model hashes и устойчивые replacement tombstones — полезные уже реализованные гарантии. Новый аудит показывает главным образом ошибки соединения этих механизмов, а не необходимость переписать приложение заново.

По пяти уровням ревью: синтаксис/компиляция — блокеров в свежем fast gate нет; логика — R01–R14; чистота — крупные владельцы и частично неиспользуемые контракты; производительность — GPU lifecycle/неограниченные коллекции/DP; тестируемость — хорошая база unit-тестов, но недостаточная проверка составных пользовательских сценариев и release evidence.
