# Фаза 3: полный цикл сессии (попап → инжекция)

Статус: код готов, ручная проверка (мик + GUI) не сделана — 174 теста зелёные, .app 6.5 МБ
Предусловия: фаза 2 done (104 теста, пайплайн хоткей→whisper.cpp→HUD работает).
Читать перед стартом: docs/migration/CONVENTIONS.md, SWIFT_MIGRATION_PLAN.md §4.2, §6 (инварианты), §5 (маппинг модулей)

## Цель и milestone

Полный цикл диктовки, идентичный текущему: хоткей → запись → распознавание → **интерактивный попап с редактированием** → Enter → **вставка текста в активное приложение** с восстановлением фокуса и клипборда. Плюс append-режим (хоткей при открытом попапе дописывает текст).

К концу фазы Swift-версия делает то же, что Python-версия, для основного сценария использования.

---

## 0. Долг фазы 2 (сделать первым, мелочь)

### 0.1 Звуки старта/остановки записи ✅
- Прочитать: `src/recorder.py` (`start`: `play_sound(SOUND_RECORDING_START)` + `time.sleep(0.2)` ДО открытия потока, чтобы бип не попал в запись; `stop`: `play_sound(SOUND_RECORDING_STOP)`), `src/utils.py` (`SOUND_RECORDING_START = /System/Library/Sounds/Tink.aiff`, `SOUND_RECORDING_STOP = .../Pop.aiff`, `play_sound`)
- Изменить: `Packages/CNSAudio/Sources/CNSAudio/AudioRecorder.swift`
- Сделать: `NSSound(contentsOf:byReference:)?.play()` перед стартом движка + пауза 0.2 с (чтобы бип не записался), и на стопе. Пути вынести в константы. Звук не должен блокировать вызывающий поток дольше паузы.
- Сделано: `RecordingSounds.swift` — AudioToolbox `AudioServicesPlaySystemSound` вместо `afplay` (нет спавна процесса на каждый хоткей, нет зависимости от AppKit в аудио-слое), `SoundCache` регистрирует файлы один раз. `AudioRecorder.start` стал `async`: бип → `Task.sleep(0.2)` → открытие потока, поэтому пауза не блокирует поток вызова.
- Приёмка: ручная проверка (слышен бип, в записи его нет) — pending.

### 0.2 Watchdog зависания остановки потока ✅
- Прочитать: `src/recorder.py` (`_stop_stream_with_timeout`, `_watchdog`, 12 с, `_on_fatal_error`), `src/app.py` (`_on_recorder_fatal_error`: ставит `_restart_pending=True` синхронно, затем постит closure на главный поток; `toggle_recording` проверяет `_restart_pending`)
- Изменить: `AudioRecorder.swift` (+ callback `onFatalError`), `RecordingCoordinator`
- Сделать: остановка `AVAudioEngine` в отдельной задаче с дедлайном 12 с; при превышении — вызов `onFatalError`, который выставляет флаг рестарта. Для AVAudioEngine риск ниже, чем у PortAudio, но watchdog оставляем как страховку от зависаний Core Audio при смене устройств/Bluetooth.
- Сделано: `StreamCloseWatchdog.swift` — остановка движка на отдельной очереди, `DispatchGroup` + дедлайн 12 с, `onHang` → `SessionController.handleRecorderFatalError()` (ставит `restartPending`, хоткей блокируется). `AudioRecorder.start` ждёт незавершённый close до 12 с и бросает `RecorderError.previousStreamStuck`, если тот завис. 5 тестов (норма, зависание, неблокирующий close, отказ старта, поздний доход).

---

## 1. TextInjector (`Packages/CNSInput`) ✅

Самая ответственная часть фазы: ошибки здесь портят пользователю клипборд или вставляют текст не туда.

- Прочитать целиком: `src/injector.py` (`inject_text`, `MacPasteboardAdapter`, `QuartzKeyboardAdapter`, `InjectionResult`, `PasteboardSnapshot`, протоколы `ClipboardAdapter`/`KeyboardAdapter`)
- Создать: `TextInjector.swift`, `PasteboardAdapter.swift`, `KeyboardAdapter.swift` + тесты на моках
- Логика 1:1:
  1. Пустой текст → `InjectionResult(ok, method: none)`.
  2. Нет Accessibility (`AXIsProcessTrusted`) → уведомление + `InjectionResult(failure)`, без вставки.
  3. `snapshot()` клипборда → `setText(text)` (запоминаем `changeCount`) → ⌘V через CGEvent → пауза `restore_delay = 0.35` → `restoreIfUnchanged(snapshot, changeCount)`.
  4. Fallback при недоступном клипборде: посимвольный набор через `CGEventKeyboardSetUnicodeString` с троттлингом.
- **Инвариант (§6 п.3):** клипборд восстанавливается ТОЛЬКО если `changeCount` совпадает с тем, что мы записали. Иначе пользователь скопировал что-то своё за эти 0.35 с и мы обязаны это сохранить.
- Сделано: `TextInjector.swift` (async — пауза 0.35 с через `Task.sleep`), `PasteboardAdapter.swift` (`MacPasteboardAdapter`, снимок всех типов каждого item), `KeyboardAdapter.swift` (`QuartzKeyboardAdapter`, `AccessibilityTrust`). Уведомления и логи инъектируются замыканиями — пакет не зависит от CNSCore.
- Отличие от Python (осознанное): `typeText` шлёт UTF-16 порциями по 20 единиц с паузой 5 мс. Python отправляет всю строку одним событием `CGEventKeyboardSetUnicodeString`, что для длинного текста ненадёжно; путь и так резервный.
- Приёмка ✅: 9 тестов на моках — успешная вставка, восстановление клипборда, ОТКАЗ при изменившемся `changeCount`, fallback-набор, восстановление перед фолбэком после сбоя ⌘V, отсутствие Accessibility, пустой текст, обе ветки провалились.

## 2. Восстановление фокуса ✅

- Прочитать: `src/app.py` (`_activate_previous_app_and_inject`, `_start_injection_worker`; константы `FOCUS_RESTORE_TIMEOUT_SECONDS=1.5`, `FOCUS_RESTORE_POLL_SECONDS=0.05`, `FOCUS_RESTORE_STABLE_CHECKS=2`)
- Создать: `FocusRestorer.swift` (в CNSInput)
- Логика: `NSRunningApplication(processIdentifier:)` → `activate()` → поллинг `NSWorkspace.frontmostApplication` каждые 0.05 с **на главном потоке**; после **двух подряд** совпадений PID — запуск инжекции. Таймаут 1.5 с → копируем текст в клипборд + уведомление «вставьте вручную».
- Если целевой PID уже не запущен или nil → тот же fallback (копия в клипборд + уведомление), НИКОГДА не вставлять вслепую.
- **Инвариант (§6 п.2):** две стабильные проверки PID на главном потоке ДО вставки; сама вставка — вне главного потока.
- Сделано: `FocusRestorer.swift` — `@MainActor`, возвращает `FocusOutcome` (`.confirmed` / `.targetUnavailable` / `.timedOut(frontmostPid:)`); решение «вставлять или в клипборд» принимает `SystemTextDelivery` в CNSSession. Активация и чтение frontmost инъектируются.
- Приёмка: 6 тестов (две стабильные проверки, сброс счётчика на мигании фокуса, таймаут, nil-frontmost, отсутствующий pid, процесс уже завершён). Ручная проверка вставки — pending.

## 3. Интерактивный PreviewPanel ✅

- Прочитать: `src/preview_panel.py` (`_create_panel(interactive=True)` — NSScrollView + NSTextView, размеры 400×160; `show_interactive`, `_handle_confirm`, `_handle_cancel`, локальный/глобальный монитор клавиш, `append_text`, `_set_text_view_text`, `_flash_toast`, `DictionaryAwareTextView.menuForEvent_`, `_add_selection_to_dictionary`, `_word_at_offset`, `_is_valid_term`)
- Изменить/создать: `Packages/CNSUI/PreviewPanel.swift` (добавить интерактивный режим), `DictionaryAwareTextView.swift`
- Сделать:
  - Пересоздание панели при смене режима (как в Python: интерактивный и неинтерактивный — разная вёрстка).
  - NSTextView в NSScrollView, белый текст 14pt, фон `white alpha 0.08`, corner radius 6, rich text выключен, автозамены выключены.
  - **Enter** подтверждает, **Escape** отменяет — через `NSEvent.addLocalMonitorForEvents` (панель non-activating, поэтому нужны мониторы, а не обычный responder chain).
  - **⌘D / контекстное меню** «Add to Dictionary»: слово под кареткой или выделение 1–4 слов → callback. Валидация термина как `_is_valid_term`.
  - `appendText` для append-режима: текущий текст + пробел + новый, каретка в конец.
  - Toast-подтверждение добавления термина (`_flash_toast`, 1.5 с, зелёный заголовок).
- Сделано: `PreviewPanel` получил интерактивный режим (пересоздание панели при смене режима, `KeyablePanel`, NSScrollView + `DictionaryAwareTextView`), `appendText`, тост в заголовке, локальный монитор клавиш. Через границу изоляции монитора передаётся только Bool («событие съедено»): `NSEvent` не Sendable. Разбор термина вынесен в `CNSCore/TermParsing.swift` (`wordAtOffset`, `isValidTerm`, `TermStoplist`) — чистые функции, сверены с Python.
- Приёмка ✅: 10 тестов панели (Enter, Escape, однократность решения, съедание клавиш, append, ⌘D по каретке и по выделению, отказ на невалидном терме, смена режимов, игнор статуса в интерактиве) + 4 теста `TermParsing`. Ручная проверка редактирования — pending.

## 4. SessionController (ядро) ✅

Заменяет `RecordingCoordinator` из фазы 2. Это самый большой кусок — переносить построчно из `src/app.py`.

- Прочитать: `src/app.py` целиком в части сессии: `toggle_recording`, `start_recording`, `stop_recording_and_process`, `chunk_worker`, `process_chunk`, `_do_finish_cleanup`, `_watch_overdue_worker`, `_on_confirm`/`_on_cancel`/`_on_add_to_dictionary` (строки ~960–1080), `_maybe_run_deferred_restart`. Плюс раздел «Session state machine» в CLAUDE.md.
- Создать: `Packages/CNSSession` (или в app-таргете) — `SessionController.swift`
- Состояния и флаги переносятся дословно: `isRecording`, `isProcessing`, `sessionId` (инкремент на каждый `startRecording`, проверка перед показом попапа), `stopWorker`, `appendToPopup`, `workerOverdue`, `previousAppPid`.
- Ключевые переходы:
  - IDLE → RECORDING: `sessionId += 1`, захват `previousAppPid` (в append-режиме НЕ трогать), `preWarm()`, HUD «Запись».
  - RECORDING → PROCESSING: `stopWorker` выставлен, воркер дренирует очередь, финальный чанк с `isFinalChunk=true`.
  - PROCESSING → POPUP: проверка `sessionId` (защита от stale-инжекции), `showInteractive`.
  - POPUP → IDLE: Enter → инжекция; Escape → отмена.
  - POPUP + хоткей → RECORDING с `appendToPopup=true`, попап остаётся открытым.
- **Overdue-watchdog:** soft-таймаут НЕ сбрасывает `isProcessing`; отдельная задача держит флаг до hard-дедлайна, затем перезагружает модель (`stop()` + повторный `load()` у `WhisperCppTranscriber`).
- Каждые 20 завершённых сессий — reload модели (`TRANSCRIBER_RESTART_AFTER_SESSIONS`).
- Сделано: `Packages/CNSSession` — `SessionController` (@MainActor), `SessionProtocols` (`PopupPresenting`, `AudioCapturing`, `TextDelivering`, `FrontmostAppProviding`), `SystemTextDelivery` (фокус + инжекция + фолбэк в клипборд), `ChunkJoiner` (порт `_join_chunks`).
- Вместо потоков и `_main_thread_queue`: чанки идут в `AsyncStream` (unbounded — аналог `put_nowait`), воркер — один `Task`, транскрайбер-актор сериализует декоды сам. Всё на главном акторе, UI не блокируется, потому что декод — это `await`.
- Overdue: soft-таймаут (30 с) только меняет заголовок HUD и НЕ снимает `isProcessing`; hard-дедлайн (backlog×35+20, зажат в 105…300 с) вызывает `abortInFlight()` + `reload()`. Ожидание сделано опросом флага `finishedWorkerSessionId`, а не `withTaskGroup`: группа дожидается всех детей, что и есть то самое неограниченное ожидание.
- **Новое в движке:** `Transcribing.abortInFlight()` + `reload()`. В `WhisperCppTranscriber` abort реализован через `whisper_full_params.abort_callback` — в Python эту роль играл рестарт дочернего процесса, в общем процессе его нет.
- Приёмка ✅: 20 тестов (полный цикл, стриминг частичных чанков, инжекция в захваченный pid, отмена, пустое подтверждение, append-режим с сохранением pid, блокировка хоткея при processing, дебаунс, блок после fatal-error, сбой старта рекордера, тишина без попапа, чанк из прошлой сессии, языки, ⌘D и дубль термина, reload каждые 20 сессий, оба таймаута watchdog).

## 5. Логирование результата ✅

- Прочитать: `src/phrase_history.py` (`append_phrase`, TSV), `src/dataset_logger.py` (`append_to_dataset`, поля `raw_whisper`/`ai_edited`/`user_final`/`ai_status`/`lang`/`prompt_hash`/`vocab_terms_in_raw|final`)
- Создать: `Packages/CNSDictionary` — `PhraseHistory.swift`, `DatasetLogger.swift` + тесты
- Форматы байт-в-байт совместимы с Python (те же файлы читает Python-версия и аналитические скрипты).
- Вызываются после подтверждения пользователем, в `_run_injection`-эквиваленте.
- Сделано: `Packages/CNSDictionary` — `PhraseHistory` (TSV, кэш счётчика) и `DatasetLogger` (JSONL). Для датасета в `JSONValue` добавлен `serializedJSONLine()` — точный аналог `json.dumps(ensure_ascii=False)` (компактные разделители, кириллица не экранируется), сверен с реальным выводом Python. 9 тестов.

## 6. Add to Dictionary (минимальный путь) ✅

- Прочитать: `src/vocab_provider.py` (`add_term_to_user_terms`), `src/utils.py` (`detect_term_script`, `target_lang_for_script_bucket`)
- Сделать: добавление термина из попапа → выбор языка по доминирующему скрипту (при ничьей — primary) → `user_terms` → пересборка `initial_prompt` → атомарное сохранение конфига.
- Полный словарный контур (анализаторы, decay, панели) — фаза 5, здесь только путь из попапа.
- Сделано: `CNSDictionary/UserTerms.swift` (`add`, `activeTerms`, `targetLanguage(for:config:)`, `sanitize`) + вызов из `SessionController.handleAddToDictionary` → пересборка `initial_prompt` → `onConfigChanged` (атомарное сохранение в AppDelegate). 7 тестов.

---

## Инварианты фазы (из §6, проверять на приёмке)

1. Весь AppKit только на `@MainActor`.
2. Две стабильные проверки frontmost-PID на главном потоке до вставки; вставка — вне главного потока.
3. Восстановление клипборда только при совпадении `changeCount`.
6. `isProcessing` не сбрасывается по soft-таймауту; hard-дедлайн у watchdog-задачи.
8. Атомарная запись config.json.
11. Проверка `sessionId` перед показом попапа (защита от stale-инжекции).
12. Append-to-popup: `previousAppPid` сохраняется, попап не закрывается.

## Вне scope

- AI-редактор и cloud STT — фаза 4.
- Словарные панели, анализаторы, decay, метрики — фаза 5.
- Wizard, права, autostart — фаза 6.
- Обновления, загрузка моделей, транскрипция файлов — фаза 7.

## Критерии завершения фазы

- [x] Звуки записи и watchdog остановки (долг фазы 2)
- [x] TextInjector с тестами на моках, включая отказ от восстановления клипборда при изменившемся changeCount
- [x] FocusRestorer с двумя стабильными проверками и fallback в клипборд
- [x] Интерактивный попап: редактирование, Enter/Escape, ⌘D
- [x] SessionController: все переходы + append-режим + stale-session guard, покрыты тестами
- [x] PhraseHistory + DatasetLogger в Python-совместимых форматах
- [ ] Ручная проверка: диктовка → правка → Enter → текст вставлен в другое приложение, клипборд не испорчен
- [x] `swift test` всех пакетов зелёный (174 теста в 7 пакетах)

## Открытые вопросы

1. **Прерывание декода.** `abort_callback` whisper.cpp опрашивается между шагами энкодера/декодера. Если зависание случится внутри одного шага Metal, abort не поможет — в Python это лечилось убийством дочернего процесса. Если такое встретится на практике, придётся выносить движок в XPC-сервис.
2. **Буферизованная финализация.** Python различает «финального чанка не было» (`_needs_buffered_finalization`) и «финальный чанк пустой». В Swift обе ветки сходятся в `finalize()` на выходе воркера — поведение то же, кода меньше; проверить на живой диктовке, что попап всегда появляется.
3. **`_previous_app_pid` в append-режиме** захватывается на главном акторе синхронно (в Python — через очередь). Значение то же, но момент чтения на кадр раньше; на практике это до показа HUD, так что frontmost ещё пользовательский.
