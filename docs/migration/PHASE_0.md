# Фаза 0: bake-off STT-движков (WhisperKit против whisper.cpp)

Статус: not started
Предусловия: нет (первая фаза)
Читать перед стартом: docs/migration/CONVENTIONS.md, SWIFT_MIGRATION_PLAN.md §2, §4.5, фаза 0 в §8

## Цель и milestone

Выбрать основной локальный STT-движок по замерам, а не по удобству. По завершении существует заполненная таблица замеров в `docs/migration/BAKEOFF_RESULTS.md`, решение зафиксировано в SWIFT_MIGRATION_PLAN.md §2, и есть тонкий Swift-harness, доказывающий, что движок-победитель интегрируется через SPM с initial prompt и language hint.

Важно: у проекта НЕТ сохранённых аудиозаписей. Датасет `~/.clicknspeak_dataset.jsonl` содержит только тексты. Поэтому фаза начинается со сбора golden-набора: пользователь надиктует фразы, а Python-версия с debug-флагом сохранит WAV-чанки и эталонные транскрипты.

## Задачи (по порядку)

### 0.1 Debug-дамп чанков в Python-версии
- Прочитать: `src/app.py` (`process_chunk`, `chunk_worker`), `src/recorder.py` (`_callback`, chunk_callback-путь), `src/transcriber.py` (`transcribe()` вход/выход)
- Изменить: `src/app.py` (минимальный диф)
- Сделать: при env `CNS_DUMP_CHUNKS=1` каждый чанк, уходящий в `transcriber.transcribe()`, сохраняется как WAV (16 kHz mono float32 → int16) в `~/Click-n-speak-bakeoff/session_<ts>/chunk_<n>.wav`, рядом `chunk_<n>.json` с полями: `text_raw` (ответ Whisper до AI-редактора), `initial_prompt` (контекст, переданный в transcribe), `language`, `is_final`, `duration_s`, `decode_time_s`. Без флага поведение не меняется ни на байт.
- Приёмка: `source venv/bin/activate && python -m pytest tests/ -x` зелёный. Запуск с флагом, одна диктовка: в каталоге появились WAV+JSON, без флага каталог не создаётся.

### 0.2 Сбор golden-набора (делает пользователь, подготовить инструкцию)
- Сделать: короткая инструкция в `docs/migration/BAKEOFF_RESULTS.md` (черновик): надиктовать 30–50 фраз, покрытие: ru и en обязательно, uk желательно, длины чанков от 1–2 s до 8 s, термины из словаря пользователя, цифры, смешанная ru/en речь. После сбора вручную выверить `text_raw` каждого чанка до эталона (поле `text_ref` в JSON): эталон — то, что реально было сказано, а не то, что распознал Whisper.
- Приёмка: ≥ 30 чанков с `text_ref`, разложены по языкам.

### 0.3 Прогон whisper.cpp (CLI, без Swift)
- Сделать: собрать whisper.cpp с Metal (`cmake -B build -DGGML_METAL=1 && cmake --build build`), скачать `ggml-large-v3-turbo` в двух квантованиях: `f16` и `q8_0`. Скрипт `spikes/stt-bakeoff/run_whispercpp.sh`: для каждого WAV вызвать `whisper-cli` с `--language <lang>` и `--prompt "<initial_prompt из JSON>"`, писать результат + тайминги в `results_whispercpp_<quant>.jsonl`. Замерить отдельно: время загрузки модели (cold), decode warm (второй прогон того же файла в одном процессе, режим `--no-timestamps`).
- Приёмка: два JSONL-файла результатов, по строке на чанк, с полями `text`, `load_s`, `decode_s`.

### 0.4 Прогон WhisperKit (CLI, без Swift)
- Сделать: `whisperkit-cli transcribe` (SPM-сборка из репо argmaxinc/WhisperKit) с моделью `openai_whisper-large-v3-v20240930` (это turbo-вариант в whisperkit-coreml). Тот же протокол замеров, плюс отдельно зафиксировать длительность ПЕРВОЙ загрузки модели на машине (ANE-компиляция) и последующих загрузок. Prompt передавать через опцию промпта CLI, если её нет в текущей версии CLI — задача 0.6 закрывает prompt через API, здесь пометить.
- Приёмка: `results_whisperkit.jsonl` + записанные времена первой/повторной загрузки.

### 0.5 Подсчёт WER и сводная таблица
- Сделать: `spikes/stt-bakeoff/score.py` (venv, можно `jiwer`): нормализация (lowercase, убрать пунктуацию), WER по каждому движку/квантованию против `text_ref`, разбивка по языкам и по длине чанка (< 3 s / ≥ 3 s). Baseline: WER текущего mlx-whisper из `text_raw` тех же чанков. Заполнить `docs/migration/BAKEOFF_RESULTS.md`: таблица WER, таблица латентности (cold load, warm decode на чанках 2 s и 8 s), пиковая память (`/usr/bin/time -l`), выводы.
- Приёмка: таблица заполнена всеми ячейками, включая baseline.

### 0.6 Swift-harness движка-победителя (Stage B)
- Сделать: `spikes/stt-bakeoff/BakeoffHarness/` — SPM executable, подключает победителя (WhisperKit через SPM либо whisper.cpp через C-интероп/SwiftWhisper-подход), транскрибирует те же WAV с initial prompt и language hint через API (не CLI), сверяет тексты с CLI-прогоном, печатает тайминги. Цель: доказать, что API даёт паритет с CLI и что prompt/language реально влияют. Проверить доступ к токенизатору (нужен для лимита 220 BPE в `_build_chunk_context`).
- Приёмка: `swift run` на golden-наборе, расхождений с CLI-текстами нет (или объяснены), prompt подтверждённо работает.

### 0.7 Фиксация решения
- Сделать: вписать решение и его обоснование в SWIFT_MIGRATION_PLAN.md §2 (заменить строку bake-off на выбор), отметить, шипим ли второй движок как fallback. Обновить `docs/migration/PHASE_0.md` статус: done.
- Приёмка: план обновлён, BAKEOFF_RESULTS.md содержит раздел «Решение».

## Критерий выбора движка

Лексикографический, по приоритетам проекта:
1. WER не хуже baseline mlx-whisper более чем на 1 абсолютный пункт на ЛЮБОМ из языков ru/en (жёсткий порог).
2. Из прошедших порог: меньший warm-decode на чанке 2 s.
3. При близких результатах (< 15% разницы латентности): перспектива (скорость появления новых моделей, живость проекта) и простота интеграции.

## Инварианты фазы

- Поведение Python-версии без `CNS_DUMP_CHUNKS` не меняется ни на байт (диф только в `src/app.py`, аудит дифа перед завершением).
- Golden-набор и результаты не содержат чувствительных диктовок: пользователь надиктовывает специально подготовленные фразы, не рабочий контент.

## Вне scope (запрещено в этой фазе)

- Никакого кода будущего приложения: ни ClickNSpeak/, ни Packages/. Только spikes/.
- Не чинить и не улучшать Python-код за пределами задачи 0.1.
- Не тестировать MLXLLM/Qwen глубоко: только smoke-замер `mlx_lm.generate` латентности refine-подобного промпта для строки «совместная память» в таблице (одна команда, полчаса).
- Не выбирать модель «получше turbo»: сравниваем только large-v3-turbo, паритет с текущей версией.

## Критерии завершения фазы

- [ ] BAKEOFF_RESULTS.md: таблицы WER/латентности/памяти заполнены, baseline присутствует
- [ ] Решение вписано в SWIFT_MIGRATION_PLAN.md §2
- [ ] Swift-harness победителя работает с prompt и language через API
- [ ] Диф Python-кода ограничен `CNS_DUMP_CHUNKS`-веткой, pytest зелёный

## Открытые вопросы

(заполняет исполнитель)
