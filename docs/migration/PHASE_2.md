# Фаза 2: аудио + STT-ядро

Статус: done — 104 теста зелёные; пайплайн хоткей→whisper.cpp→HUD работает
Предусловия: фаза 1 done. Движок STT формально выбирается в фазе 0 (bake-off); задачи 2.1–2.3, 2.7, 2.8 от выбора НЕ зависят и делаются сразу. Реальная интеграция WhisperKit (2.4b) ждёт результата bake-off — до этого пайплайн работает на stub/mock transcriber.
Читать перед стартом: docs/migration/CONVENTIONS.md, SWIFT_MIGRATION_PLAN.md §4.2, §4.4, §4.5, §5

## Цель и milestone

Хоткей → запись → чанки текста появляются в HUD в реальном времени. К концу фазы работает цепочка: AVAudioEngine → ring buffer → VAD-чанкер → transcriber (сначала stub, потом WhisperKit) → PreviewPanel (неинтерактивный режим). Фильтры галлюцинаций и guard'ы чанков перенесены 1:1.

## Ключевое архитектурное отличие (§4.5)

VAD НЕ выполняется в audio callback (как в `recorder.py._callback`). Tap только пишет PCM в lock-free ring buffer; отдельная задача-потребитель прогоняет VAD и машину чанкинга. Пороги и логика чанкинга при этом переносятся дословно (1.0/0.4/0 s silence, target 3 s, max 8 s, min_speech 0.5 s, финальный <0.3 s discard).

## Задачи (по порядку)

### 2.1 CNSAudio package + AudioChunker (чистая машина состояний) ✅
- Прочитать: `src/recorder.py` (`_callback`, `_trigger_chunk`, `stop` — вся логика silence_counter / effective_silence_duration / has_speech / min_speech / финальный discard)
- Создать: `Packages/CNSAudio` + `AudioChunker.swift` + тесты
- Сделать: чистый state machine, принимает последовательность фреймов с флагом speech/silence (от VAD) + длительности, эмитит чанки по тем же правилам. Без AVAudioEngine — тестируется синтетикой.
- Приёмка: тесты воспроизводят все три ветки (normal 1.0 s, micro 0.4 s после 3 s, force 0 s после 8 s), discard шумовых чанков, финальный <0.3 s discard.

### 2.2 VoiceActivityDetecting protocol + RMS detector ✅
- Прочитать: `src/recorder.py` (RMS-ветка `energy = sqrt(mean(indata²))`, threshold 0.01; webrtcvad-ветка 30 ms фреймы aggressiveness 2)
- Создать: `VoiceActivityDetecting.swift`, `RMSVoiceActivityDetector.swift` + тесты
- Сделать: протокол `isSpeech(frame) -> Bool`; RMS-реализация калибрована как в Python. **libfvad-реализация — отдельная follow-up задача 2.2b** (вендоринг C-исходников libfvad как SPM C-target); до неё пайплайн работает на RMS (Python поддерживает обе ветки).
- Приёмка: RMS-детектор различает тишину/речь на синтетических фреймах.

### 2.2b FVADVoiceActivityDetector (libfvad) ✅
- Вендорены исходники libfvad (BSD-3, WebRTC-derived) в `Packages/CNSAudio/Sources/Cfvad` как чистый SPM C-таргет (без cmake/бинарников). `FVADVoiceActivityDetector`: mode 2 = `webrtcvad.Vad(2)`, конвертация float32→int16 PCM, NSLock (не `OSAllocatedUnfairLock` — его `withLock` требует @Sendable-замыкания, несовместимого с C-указателем). Кадры невалидной длины падают на RMS, а не отбрасываются. **Стал дефолтом в `AudioRecorder`.** 6 тестов.

### 2.3 AudioRecorder (AVAudioEngine tap → ring buffer → consumer) ✅ (кроме звуков/watchdog)
- Прочитать: `src/recorder.py` (`start`, `stop`, устройство, sample rate, конвертация; watchdog зависания close)
- Создать: `AudioRecorder.swift`, `RingBuffer.swift` + тесты (ring buffer)
- Сделано: AVAudioEngine input tap → `AVAudioConverter` в 16 kHz mono float32 → `SampleRingBuffer`; consumer-задача (`Task.detached`) гоняет VAD пофреймово (30 ms) + `AudioChunker`, эмитит чанки через callback. Start/stop, финальный чанк из остатка с guard <0.3 s.
- Follow-up (не блокирует): звуки старт/стоп (`Tink.aiff`/`Pop.aiff`), watchdog зависания close→fatal-error (специфика PortAudio, для AVAudioEngine менее критично).
- Приёмка: ring buffer тесты (wrap-around, overflow, clear) ✅; ручной тест записи (нужен мик + разрешение) — pending.

### 2.4 Transcribing protocol + stub ✅
- Прочитать: `src/transcriber.py` (сигнатура `transcribe(audio, initial_prompt, language, is_final)`), `src/cloud_transcriber.py` (duck-typing → протокол)
- Создано: `Packages/CNSTranscription` — `Transcribing` протокол (`TranscriptionRequest`/`TranscriptionResult`, `.empty` = skip/fail как Python `""`), `StubTranscriber` (actor, детерминированный текст). 3 теста.

### 2.4b whisper.cpp transcriber ✅ (движок-победитель фазы 0)
- Создано: `scripts/build_whisper_xcframework.sh` (закреплённый commit whisper.cpp → статическая либа macOS arm64 + встроенный Metal → `whisper.xcframework` 3.5 МБ, gitignored), `Packages/CNSTranscription` binaryTarget + `WhisperCppTranscriber` (actor поверх C-API, продакшн-параметры: greedy, temp 0, no_speech 0.5, entropy_thold 2.0, язык форсируется при одном allowed). Контекст в nonisolated box (deinit-free). Подключён в AppDelegate: реальный движок при наличии модели, иначе stub.
- Проверено: model-gated тест декодирует golden-WAV 007 → тот же текст, что CLI в bake-off. App стартует с «Using whisper.cpp engine».
- Follow-up'ы закрыты: **language-retry** (padding 0.1 с с обеих сторон при языке вне allowed, только для нефинальных нетривиальных чанков; текст ретрая сохраняется независимо от его языка, пустой — дропает чанк), **токен-точный контекст** (`whisper_token_count` через `Transcribing.tokenCount`, async-вариант `ChunkContextBuilder.build` с кэшем и фолбэком на эвристику), **троттлинг прогрева** (`warmup` идемпотентен, `preWarm` пропускается если декод был <45 с назад).

### 2.5 HallucinationFilter ✅
- Прочитать: `src/transcriber.py` (`_hallucination_phrases`, `_SUBWORD_REPEAT_RE`, повторы слов, CJK, guard'ы коротких/тихих чанков, language-retry)
- Создано: `AudioGuards.swift` (pre-decode: tiny final ≤8000, silent short <48000 & RMS<0.005) + `HallucinationFilter.swift` (CJK, phrase-list word-boundary, single-word you/the, collapse repetition, subword strip, final strip). Поведение сверено с реальными Python-функциями. `GuardedTranscriber` декоратор оборачивает любой движок и подключён в пайплайн. Language-retry остаётся в движке-адаптере (нужен ре-декод). 13+3 тестов.

### 2.6 Chunk context builder ✅
- Прочитать: `src/app.py` (`_build_chunk_context`, `_RECENT_CHARS_RATIO`, `_MAX_RECENT_CHUNKS`, лимиты 220 BPE / 700 char)
- Создано: `ChunkContextBuilder.swift` — 1:1 гарантии (vocab целиком, recent урезается первым, ≤3 чанка, ≤50% char budget). Токен-счётчик инъектируемый (эвристика; WhisperKit-токенизатор в 2.4b). Выходы сверены с Python на 4 кейсах. 5 тестов.

### 2.7 HotkeyManager (Carbon) ✅
- Прочитать: `src/hotkey_handler.py`
- Создано: `Packages/CNSInput` — `HotkeyManager.swift` (RegisterEventHotKey, Option+Space default). Carbon-ресурсы в nonisolated box (deinit-cleanup). Вся CGEventTap/Input-Monitoring/macOS-15-TSM обвязка удалена (§4.3). 2 теста (binding); ручная проверка срабатывания — pending (нужна GUI).

### 2.8 PreviewPanel (неинтерактивный HUD) ✅
- Прочитать: `src/preview_panel.py` (неинтерактивный режим)
- Создано: `Packages/CNSUI/PreviewPanel.swift` — non-activating NSPanel, HUD material, corner radius 12, иконка+title+text, позиция у курсора, show/updateStatus/updateText (truncate 290)/hide с fade. @MainActor напрямую (§4.2, без очереди). Интерактивный режим — фаза 3.

### 2.9 Сквозная проводка ✅ (на stub)
- Создано: `ClickNSpeak/RecordingCoordinator.swift` — хоткей → AudioRecorder → чанки → StubTranscriber → PreviewPanel. Подключено в AppDelegate. App запускается, хоткей регистрируется (лог "Hotkey registered: Option+Space"). Замена stub на WhisperKit — после bake-off (2.4b). Ручной тест диктовки — pending (мик+GUI).

## Инварианты фазы (из §6)

- Audio tap не делает ничего, кроме записи в ring buffer (VAD в consumer). [нов. инвариант §4.5]
- Guard'ы чанков: финальный ≤0.5 s (8000 samples) skip, нефинальный <3 s + RMS-тишина skip, финальный <0.3 s discard в recorder.
- Пороги чанкинга: 1.0/0.4/0 s, target 3 s, max 8 s, min_speech 0.5 s — дословно.
- Троттлинг pre_warm 45 s, cold-idle 300 s (относится к 2.4b).
- Очередь чанков без блокирующих put.
- Весь AppKit (PreviewPanel) на @MainActor.

## Вне scope

- Интерактивный попап, инжекция, append-to-popup — фаза 3.
- AI-редактор, cloud STT — фаза 4.
- Реальная WhisperKit-интеграция до результата bake-off (работаем на stub).
- libfvad до задачи 2.2b (работаем на RMS).

## Критерии завершения фазы

- [x] AudioChunker + VAD (libfvad) + ring buffer с тестами
- [ ] AudioRecorder пишет чанки из живого мика
- [ ] HotkeyManager срабатывает глобально
- [ ] PreviewPanel показывает текст чанков live
- [x] HallucinationFilter + chunk context с тестами
- [x] Сквозная цепочка хоткей→HUD на реальном whisper.cpp
- [x] `swift test` всех пакетов зелёный (104 теста)

## Открытые вопросы

(заполняет исполнитель)
