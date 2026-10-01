# Эпоха 04 — Файловая транскрипция и загрузка моделей

> Для исполнителя: использовать `executing-plans`; предпосылки — эпохи 02–03. Не вызывать платные API и не скачивать пользовательские модели для unit-тестов.

**Цель:** закрыть R11/R12 и ошибки отмены/повторного запуска file-job.

**Архитектура:** общий каталог форматов связывает UI с реальным декодером; операции файла имеют собственный ID. Загрузчик различает HTTP failure, отказ resume и превышение размера.

**Стек:** CNSTranscription, CNSUI, CNSCore, AVFoundation/Core Audio, URLSession.

**Спецификация:** [00-REVIEW-AND-PLAN.md](00-REVIEW-AND-PLAN.md), R03/R11/R12. Глобальные ограничения обязательны.

## Задача 1 — Реальные capabilities форматов

**Файлы:** `Packages/CNSTranscription/Sources/CNSTranscription/FileTranscription.swift`, `MediaAudioDecoder.swift`, `CloudSTTTranscriber.swift`, `Packages/CNSUI/Sources/CNSUI/FileDropPanel.swift`; tests `MediaAudioDecoderTests.swift`, `CloudSTTTranscriberTests.swift`, `UIPanelsTests.swift`; создать маленькие синтетические audio fixtures в `Packages/CNSTranscription/Tests/CNSTranscriptionTests/Fixtures/Media/`.

**Интерфейс:** `MediaFormatCapabilities` в CNSTranscription экспортирует поддерживаемые расширения и policy `nativeDecode`, `coreAudioConversion`, `unsupported`. FileDropPanel читает этот каталог. MIME соответствует реальному контейнеру; расширение не является доказательством кодека.

- [ ] Создать короткие известные signals в WAV 16/44.1/48 kHz mono/stereo, CAF, M4A/AAC и Ogg/Opus. Зафиксировать способ генерации и checksums, исключить реальную речь. Для каждого формата тест должен пройти UI acceptance→decoder→bounded PCM→fake transcriber.
- [ ] Зафиксировать исходный red: CAF принимается UI, но backend возвращает unsupported. Отдельно проверить `FileMediaType.detect` на `OggS`, `caff`, raw AAC ADTS и mislabeled extension.
- [ ] Добавить native CAF path, проверить AVFoundation decode. Для Core Audio форматов, которые AVAssetReader не принимает, использовать ту же систему преобразования, что Python `_load_audio_for_transcription`: `/usr/bin/afconvert`, аргументы `-f WAVE -d LEI16@16000 -c 1`, отдельный temporary WAV, затем существующий segmented reader. Process должен иметь timeout 300 s, отмену с ожиданием выхода и cleanup принадлежащего job файла.
- [ ] Ogg/Opus не объявлять поддержанными только потому, что они перечислены в Python UI: Python также зависит от доступных Core Audio декодеров. На минимальной поддерживаемой macOS проверить реальный fixture обоими путями. Если platform decoder отсутствует, общий каталог должен честно возвращать unsupported до начала job; расширение codec support становится отдельным явным продуктовым решением, а не скрытой зависимостью от установленного ffmpeg.
- [ ] Для raw AAC/неподдерживаемого provider MIME конвертировать в WAV и отправлять сегменты; не присваивать audio/mp4 произвольным AAC bytes. Provider tests проверяют bytes/header вместе с MIME.
- [ ] Проверить сохранность source checksum, ограничение сегмента, временные файлы при success/cancel/error. Сохранить fixture матрицу для macOS 14 и текущей поддерживаемой ОС.
- [ ] Green Transcription/UI; коммит `fix: align file format support across UI and transcription`.

## Задача 2 — HTTP failures, resume и жёсткий лимит bytes

**Файлы:** `Packages/CNSCore/Sources/CNSCore/ModelDownloader.swift`, `ModelManager.swift`; tests `Packages/CNSCore/Tests/CNSCoreTests/ModelTests.swift`. При необходимости выделить `ModelTransferPolicy.swift` из downloader, сохранив прежний публичный API.

**Интерфейс:** `ModelResponseAction` со значениями `.accept`, `.restartFresh`, `.retry(after: TimeInterval)`, `.fail`; policy принимает HTTP status, offset, contentRange, responseLength, expectedSize, attempt/fresh-restart count. URLSession/configuration factory должен инъецироваться, чтобы URLProtocol fixture управлял настоящими callbacks, а не только pure policy.

- [ ] Добавить integration red: HEAD 200 с верным размером, GET 404 → терминальная ошибка и один GET; HEAD 200, GET 500 трижды → ограниченное число попыток; range запрос получает 200 → ровно один fresh GET; fresh GET снова неверен → failure.
- [ ] Установить maxAttempts=3 для transient 429/5xx/временных network ошибок с backoff 1s/2s и ограниченным Retry-After. 401/403/404 не повторять автоматически. Только отказ **настоящего** resume допускает fresh restart:

```swift
if offset > 0, !didRestartFresh, response.statusCode == 200 {
    return .restartFresh
}
guard (200..<300).contains(response.statusCode) else {
    return failureOrBoundedRetry(response.statusCode)
}
```

`failureOrBoundedRetry(_ statusCode: Int) -> ModelResponseAction` — метод новой policy; использует её `attempt: Int`, `maxAttempts: Int`, `retryAfter: TimeInterval?`. Возвращает `.retry` только для 429/500/502/503/504 при attempt < 3; задержка max(backoff, Retry-After), ограниченная 30 s. Иначе `.fail`. Не оставлять callback catch-all, который снова входит в beginTransfer.

- [ ] Content-Range валидировать целиком: start, end, total, end >= start, total == expectedSize. Некорректный ответ fresh request — failure, не resume restart.
- [ ] До каждой записи в partial проверять лимит:

```swift
let remaining = expectedSize - offset - receivedBytes
guard remaining >= 0, Int64(data.count) <= remaining else {
    dataTask.cancel()
    reportFailure(URLError(.dataLengthExceedsMaximum))
    return
}
try fileHandle.write(contentsOf: data)
receivedBytes += Int64(data.count)
```

- [ ] Проверки unknown Content-Length + oversized stream, zero/negative response length, 416, changed ETag, retry cancellation, late delegate callback предыдущей generation. Bytes/hash validation остаётся обязательной после download.
- [ ] Отдельно проверить отмену в validating: UI не должен обещать Cancel, который downloader игнорирует. Либо поддержать cooperative validation cancellation до activation, либо изменить доступность кнопки на время короткого атомарного commit.
- [ ] Green Core/UI и общий Swift gate; коммит `fix: bound model transfer retries and disk writes`.

## Задача 3 — Отмена и повторное открытие file-job

**Файлы:** `Packages/CNSUI/Sources/CNSUI/FileDropPanel.swift`, SessionController, FileTranscription types; tests UIPanels/SessionController/MediaAudioDecoder/LocalAiEditor/GeminiEditor.

**Интерфейс:** выделить `@MainActor FileTranscriptionViewModel` с `jobID: UUID?`, task handle и view state. `start`, `cancel`, `onProgress` проверяют принадлежность ID. Session хранит task/ID file operation; cancel не обрывает новый unrelated request.

- [ ] Cases: cancel A → start B → поздний progress/result A; close/reopen panel при A; cancel на стадиях decoding/uploading/refining; второй start до фактического завершения отменённой job получает понятное busy состояние.
- [ ] Перед публикацией progress/result проверять ID:

```swift
let currentID = UUID()
jobID = currentID
// Every completion/progress callback checks the captured ID before mutation.
guard jobID == currentID else { return }
```

- [ ] Не сбрасывать `isProcessing` нового B из cancelled handler старого A. Не показывать completed upload как завершение всей работы перед optional refine. Cancel должен дойти до editor task, а не только STT abort.
- [ ] При file failure/cancel частичный результат либо остаётся доступным с явной неполнотой, либо его отсутствие прямо объясняется; повторное открытие не теряет ранее завершённый несохранённый текст без видимого действия пользователя.
- [ ] Зафиксировать продуктовое отличие от Python: Python автоматически пишет Markdown в Downloads и копирует текст, Swift предлагает Copy/Save As. В этой эпохе сохранить явные Copy/Save As и документировать это как выбранный native workflow; не добавлять скрытую запись/перезапись clipboard ради формального паритета. Если пользователь требует точное прежнее поведение, добавить отдельную настройку auto-export с collision-safe именованием и тестом отказа диска.
- [ ] Green UI/Session/Transcription/Editors; коммит `fix: isolate file transcription task lifecycle`.

## Выход эпохи

- [ ] UI не обещает неподдерживаемый формат; capabilities доказаны реальными fixture bytes.
- [ ] Model download заканчивается success/error/cancel при каждом scripted HTTP outcome, без бесконечной серии GET и без записи лишних bytes.
- [ ] File cancel/reopen не влияет на следующую задачу и не запускает запись одновременно с текущей.
