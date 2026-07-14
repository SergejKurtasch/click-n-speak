# Фаза 2: аудио + STT-ядро

Статус: in progress
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

### 2.2b FVADVoiceActivityDetector (libfvad) — follow-up
- Вендорить libfvad (C), SPM C-target, обёртка `FVADVoiceActivityDetector`. Заменяет RMS как дефолт (webrtcvad-паритет). Отдельный PR.

### 2.3 AudioRecorder (AVAudioEngine tap → ring buffer → consumer) ✅ (кроме звуков/watchdog)
- Прочитать: `src/recorder.py` (`start`, `stop`, устройство, sample rate, конвертация; watchdog зависания close)
- Создать: `AudioRecorder.swift`, `RingBuffer.swift` + тесты (ring buffer)
- Сделано: AVAudioEngine input tap → `AVAudioConverter` в 16 kHz mono float32 → `SampleRingBuffer`; consumer-задача (`Task.detached`) гоняет VAD пофреймово (30 ms) + `AudioChunker`, эмитит чанки через callback. Start/stop, финальный чанк из остатка с guard <0.3 s.
- Follow-up (не блокирует): звуки старт/стоп (`Tink.aiff`/`Pop.aiff`), watchdog зависания close→fatal-error (специфика PortAudio, для AVAudioEngine менее критично).
- Приёмка: ring buffer тесты (wrap-around, overflow, clear) ✅; ручной тест записи (нужен мик + разрешение) — pending.

### 2.4 Transcribing protocol + stub
- Прочитать: `src/transcriber.py` (сигнатура `transcribe(audio, initial_prompt, language, is_final)`), `src/cloud_transcriber.py` (duck-typing → протокол)
- Создать: `Packages/CNSTranscription` + `Transcribing.swift` + `StubTranscriber.swift` + тесты
- Сделать: протокол; stub возвращает фиксированный текст (для сквозного теста пайплайна без модели).

### 2.4b WhisperKit transcriber (после bake-off)
- Реальная интеграция движка-победителя фазы 0 за протоколом `Transcribing`. Прогревы (таблица §GPU warmup), initial prompt, language hint, токенизатор для 2.6.

### 2.5 HallucinationFilter
- Прочитать: `src/transcriber.py` (`_hallucination_phrases`, `_SUBWORD_REPEAT_RE`, повторы слов, CJK, guard'ы коротких/тихих чанков, language-retry)
- Создать: `HallucinationFilter.swift` + тесты (перекалибровка на golden-наборе)
- Приёмка: тесты на каждый тип галлюцинации из Python.

### 2.6 Chunk context builder
- Прочитать: `src/app.py` (`_build_chunk_context`, `_RECENT_CHARS_RATIO`, `_MAX_RECENT_CHUNKS`, лимиты 220 BPE / 700 char)
- Создать: `ChunkContextBuilder.swift` + тесты
- Сделать: 1:1 с гарантиями (vocab всегда полный, recent_text урезается). Токен-счётчик из 2.4b (до него — эвристика из фазы 1).

### 2.7 HotkeyManager (Carbon)
- Прочитать: `src/hotkey_handler.py`
- Создать: `Packages/CNSAudio` или отдельный — `HotkeyManager.swift` (RegisterEventHotKey)
- Сделать: глобальный хоткей `<alt>+<space>` по умолчанию, без Input Monitoring.
- Приёмка: ручной тест срабатывания.

### 2.8 PreviewPanel (неинтерактивный HUD)
- Прочитать: `src/preview_panel.py` (неинтерактивный режим, `append_text`, `update_text`, `update_status`, HUD-вид NSPanel non-activating)
- Создать: `Packages/CNSUI` + `PreviewPanel.swift`
- Сделать: HUD появляется, показывает текст чанков live. Интерактивный режим (редактирование, ⌘D) — фаза 3.

### 2.9 Сквозная проводка
- Хоткей → AudioRecorder → чанки → StubTranscriber → PreviewPanel. Заменить stub на WhisperKit после bake-off.
- Приёмка: milestone фазы.

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

- [ ] AudioChunker + RMS VAD + ring buffer с тестами
- [ ] AudioRecorder пишет чанки из живого мика
- [ ] HotkeyManager срабатывает глобально
- [ ] PreviewPanel показывает текст чанков live
- [ ] HallucinationFilter + chunk context с тестами
- [ ] Сквозная цепочка хоткей→HUD (на stub или WhisperKit)
- [ ] `swift test` всех пакетов зелёный

## Открытые вопросы

(заполняет исполнитель)
