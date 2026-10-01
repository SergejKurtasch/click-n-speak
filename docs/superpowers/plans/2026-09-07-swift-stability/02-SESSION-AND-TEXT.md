# Эпоха 02 — Состояния сессии, сохранность текста и shutdown

> Для исполнителя: использовать `executing-plans`; сначала проверить завершение эпохи 01. Импортировать из audit probes только тесты текущей задачи.

**Цель:** закрыть R03–R07/R14, исключить молчаливую потерю текста и одновременные несовместимые операции.

**Архитектура:** SessionController владеет activity и draft; popup отображает состояние и не принимает решение о допустимости confirm самостоятельно. Долговечный draft отделён от очередной recording generation.

**Стек:** CNSCore, CNSSession, CNSUI, CNSInput, CNSDictionary, ClickNSpeak.

**Спецификация:** [00-REVIEW-AND-PLAN.md](00-REVIEW-AND-PLAN.md), R03–R07/R14 и долг 3. Все глобальные ограничения обязательны.

## Задача 1 — Полная таблица занятости

**Файлы:** `Packages/CNSSession/Sources/CNSSession/SessionController.swift`, `SessionState.swift`; `Packages/CNSUI/Sources/CNSUI/MenuState.swift`; `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`; tests `SessionControllerTests.swift`, `SessionDoubles.swift`, `MenuStateTests.swift`.

**Интерфейс:** добавить `isShuttingDown` и `runtimeMutationInProgress` в SessionController; `isRuntimeIdle` требует `.idle`, отсутствия file job, shutdown, reload и mutation. Методы `beginRuntimeMutation() -> Bool` / `endRuntimeMutation()` доступны composition root через runtime session protocol в эпохе 03. Запись и file-job не начинаются при активной mutation.

- [ ] Перенести `fileJobBlocksHotkey` и `injectingBlocksHotkey` из SessionAuditProbes; использовать continuation для file job. Добавить второй file request, file request при popup, duplicate Enter, hotkey при shutdown/reload.
- [ ] Выполнить red `source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSSession --filter ReviewAuditSessionProbes` с импортированными двумя тестами.
- [ ] Заменить логику «всё, что не processing/recording, начинает запись» явными переходами:

```swift
guard !isShuttingDown, !fileJobActive, !runtimeMutationInProgress else { return }
switch state {
case .starting, .recording:
    beginStop()
case .idle, .popup:
    guard runtimeAvailable, !restartPending, !reloadInProgress else { return }
    beginStart()
case .failed(let recoverable, _):
    guard recoverable, runtimeAvailable, !restartPending, !reloadInProgress else { return }
    beginStart()
case .stopping, .processing, .injecting:
    return
}
```

- [ ] file-job разрешать только при той же effective idle-проверке и доступном runtime. UI menu должен показывать file processing, а отмена должна принадлежать именно file-job, не общей «текущей» операции.
- [ ] Реализовать синхронное на MainActor приобретение runtime mutation: проверить effective idle, установить flag, вернуть true. Освобождение idempotent. Эта проверка и установка не содержат await.
- [ ] Green Session/UI/executable; коммит `fix: enforce exclusive session activities`.

## Задача 2 — Draft и append без утраты исходной фразы

**Файлы:** создать `Packages/CNSSession/Sources/CNSSession/PopupDraft.swift`; изменить SessionController, `Packages/CNSCore/Sources/CNSCore/SessionProtocols.swift`, `Packages/CNSUI/Sources/CNSUI/PreviewPanel.swift`; tests SessionController/PreviewPanel/DatasetLogger/CorrectionAnalyzer.

**Интерфейсы:** `PopupDraft` хранит ID, target PID, массив сегментов `(raw, edited, runtime, promptHash)` и набор проблем распознавания. Новый `PopupPresenting.setDecisionEnabled(_ enabled: Bool)` обязателен и для FakePanel. `setDecisionEnabled(false)` сохраняет текст/selection, но запрещает confirm/cancel до возврата в `.popup`.

- [ ] Перенести `silentAppendPreservesPopup`, `appendPreservesDatasetSource`. Добавить append после пользовательской правки, неудачный recorder start при append, Enter/Escape во время append, два append подряд с последующим confirm.
- [ ] При первой записи создавать draft. При append очищать только накопители нового segment, не provenance прежних частей и target PID. Снимок текста брать из панели только на confirm; пользовательские исправления не записывать как raw.
- [ ] Пустой append должен восстановить `.popup`, включить действия и оставить draft. Минимальная ветка:

```swift
if fullText.isEmpty, appendToPopup, panel.isShowingInteractive {
    appendToPopup = false
    panel.setDecisionEnabled(true)
    return
}
```

- [ ] В PreviewPanel проверять `decisionEnabled` **до** `teardownInteractive` и вызова handler. Проверить клавиши и UI-кнопки, не только fake callback. Во время append можно продолжать редактировать текст, но outcome не должен уничтожать draft.
- [ ] Dataset для `first + second` должен содержать raw обоих сегментов и один user_final. Для смешанного статуса редактора не придумывать единый successful `ai_edited`: добавить необязательное поле `segments` с provenance либо оставить aggregate ai_edited nil, сохранив по-сегментные данные. Новые поля JSON должны игнорироваться старым Python. Runtime swap при открытом draft в эпохе 03 запрещён до завершения draft.
- [ ] Проверить, что CorrectionAnalyzer не учит первую фразу как вставку. Green Session/UI/Dictionary; коммит `fix: preserve popup drafts across appended recordings`.

## Задача 3 — Неполный результат и ограниченный backlog

**Файлы:** SessionController, PopupDraft, PreviewPanel, SessionProtocols, RuntimeTelemetry; локали; tests SessionController/OverdueWatchdog/PreviewPanel.

**Интерфейс:** в draft хранить `failedChunkIndices: Set<Int>`; дать SessionChunk monotonic `index`, enqueue/capture uptime. Новый метод панели `showIncompleteWarning(_ message: String)` показывает предупреждение внутри interactive UI. Он не заменяет сохранённый текст и не скрывается обычным `updateStatus(ready)`.

- [ ] Перенести `partialFailureIsVisible`. Изменить проверку отображения на новый typed warning, сохранив суть: ошибка середины видна одновременно с `first third`. Cases: timeout, provider failure, abort, guard/noSpeech; последние два штатных фильтра не объявлять потерей речи без причины.
- [ ] Записать проблемный index до пропуска text. Сохранить пригодные части и предложить явный retry по сохранённому аудио либо продолжение с неполным draft. По умолчанию не отправлять такие пары в автоматическое обучение; history/dataset могут хранить их с `incomplete=true`.
- [ ] Установить bounded audio backlog по суммарным samples, а не просто числу chunks. Начальный предел — 120 секунд PCM 16 kHz Float32 (около 7.68 MB). При достижении: остановить capture, дренировать уже принятые chunks, показать предупреждение. Не заменять `.unbounded` на `bufferingNewest` с тихим выбрасыванием речи.
- [ ] Тест удерживает fake decoder, подаёт chunks до лимита, проверяет ровно один controlled stop, монотонные индексы, отсутствие пропуска уже принятого аудио, warning. Для oversized chunk не принимать его незаметно: фиксировать overflow и остановку.
- [ ] Hard watchdog считать из фактического pending audio/chunk count, а не `transcribedParts.count`. После отмены завершить ожидание, не оставлять `try? Task.sleep` в горячем cancellation loop.
- [ ] Green Session/UI и общий gate; коммит `fix: surface incomplete transcription and bound queued audio`.

## Задача 4 — Termination barrier и восстановление недоставленного текста

**Файлы:** SessionController, `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`, `UserNotificationService.swift`, `Packages/CNSInput/Sources/CNSInput/SystemTextDelivery.swift`, `TextInjector.swift`, `Packages/CNSDictionary/Sources/CNSDictionary/DictionaryCoordinator.swift`; tests SessionController, TextInjector, AppDelegateStartup.

**Интерфейсы:** `shutdown() async` — idempotent, инвалидирует session generation до первого await. `DictionaryCoordinator.drainAndStop() async` ожидает принадлежащие ему writes, затем flush. SessionController хранит handles worker/start/file/injection/confirmation tasks; отмена не равна подтверждённому завершению внешнего действия.

- [ ] Перенести `shutdownCannotReopenPopup`; fake editor намеренно возвращает ответ после cancellation. Дополнительно shutdown во время focus wait, duplicate shutdown, queued final, сохранение history перед выходом.
- [ ] В начале shutdown поставить terminal flag и увеличить generation. В processChunk/finalize/completeSession проверять generation, terminal flag и Task.isCancelled после каждого существенного await и перед UI/persistence side effect:

```swift
guard !isShuttingDown, sessionId == id, !Task.isCancelled else { return }
```

- [ ] Ожидания и cleanup должны иметь deadline. Если native backend не завершается, вернуть failure termination outcome и показать восстановление, не признавать приложение healthy и не освобождать instance lock преждевременно. Отдельная процессная стратегия рассмотрена в эпохе 03.
- [ ] Подключить уведомления через уже имеющийся сервис:

```swift
let delivery = SystemTextDelivery(
    notify: { [weak notificationService] title, _, body in
        Task { @MainActor in
            notificationService?.deliver(title: title, body: body)
        }
    },
    log: log
)
```

- [ ] Перевести тексты delivery outcomes на локализованные значения, разрешённые выбранной архитектурой CNSInput/CNSCore. Missing target → сохранить draft/clipboard + уведомить; missing Accessibility → draft остаётся доступным для Copy/retry. Не считать уведомление эквивалентом успешной вставки.
- [ ] Тестировать уведомление и восстановление на injected focus/clipboard/notification spies, без работы с NSPasteboard.general. Подтвердить existing clipboard changeCount и PID guarantees.
- [ ] Green Input/Session/Dictionary/executable; полный Swift gate; коммит `fix: drain session shutdown and preserve failed deliveries`.

## Выход эпохи

- [ ] Все шесть исходных session probes проходят как постоянные поведенческие регрессии.
- [ ] Нет потерянного draft после тишины, ошибки или закрытия приложения; подтверждение и dataset provenance согласованы.
- [ ] Подготовлены activity lease API для эпохи 03. Следующая эпоха не должна вводить обходные flags в UI вместо этого контракта.
