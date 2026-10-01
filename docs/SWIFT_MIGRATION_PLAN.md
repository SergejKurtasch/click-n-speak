# План миграции Click-n-speak: Python → Swift

Дата: 2026-07-14 (ревизия v2 того же дня). Ветка: `swift_migration`.

**Ревизия v2:** приоритеты пересмотрены. Во главе угла скорость работы, точность распознавания и перспективы развития кода. Размер вторичен: достаточно быть в разы меньше 603 MB, бюджет 50–100 MB приемлем. Следствия: bake-off STT-движков вместо жёсткого выбора WhisperKit (§2, фаза 0), модульная структура SPM + Swift 6 strict concurrency (§2.1), VAD вне audio callback (§4.5).

## 1. Цель и рамки

- Полный перенос приложения на нативный Swift с сохранением функциональности, внешнего вида и логики 1:1.
- Приоритеты (по убыванию): скорость работы, точность распознавания, развиваемость кода, размер дистрибутива. Сейчас `.app` весит 603 MB (564 MB из них: Python-рантайм, MLX, numpy, PyObjC). Цель: **50–100 MB** без моделей. Модели, как и сейчас, скачиваются при первом запуске.
- Пользовательские данные (config, история, словарь, датасет) переносятся без миграции: те же пути, те же форматы.
- Объём исходников: ~17 800 строк Python в 30+ модулях, ожидаемый объём Swift: 12–15 K строк.

## 2. Зафиксированные технические решения

| Область | Решение | Обоснование |
|---|---|---|
| Локальный STT | **whisper.cpp** (Metal, ggml-large-v3-turbo, greedy) — решено по результатам bake-off фазы 0, см. `docs/migration/BAKEOFF_RESULTS.md` | Обгоняет текущий продакшн-движок: WER 4.1% против 4.8% (code-switch 4.6% против 7.7%, короткие команды 20% против 30%), хвост латентности 1.85 s против 2.50 s. WhisperKit отклонён: его ANE-путь на large-v3_turbo зависает бесконечно (с `tiny` работает), а на GPU он теряет своё единственное преимущество перед whisper.cpp. Движок остаётся за протоколом `Transcribing`, возврат к WhisperKit стоит одной реализации протокола |
| Локальный AI-редактор | **MLX Swift** (`mlx-swift-examples` / MLXLLM), те же веса `mlx-community/Qwen2.5-1.5B-Instruct-4bit` | Полный паритет качества: тот же фреймворк и те же веса, что сейчас. HF-кэш Qwen можно переиспользовать |
| Cloud STT / Gemini / OpenAI | Чистый `URLSession` (REST), без SDK | google-genai и openai SDK тянут мегабайты зависимостей ради двух эндпоинтов |
| VAD | **libfvad** (C-порт WebRTC VAD) через SPM-обёртку + существующий RMS-fallback | Тот же алгоритм, что webrtcvad сейчас: пороги чанкинга не придётся перекалибровывать |
| Глобальный хоткей | **Carbon `RegisterEventHotKey`** | Не требует Input Monitoring, устраняет крэш `TSMGetInputSourceProperty` на macOS 15, работает без перезапуска после выдачи прав. См. §4.3 |
| UI | Чистый **AppKit** (NSStatusItem, NSMenu, NSPanel, NSAlert, NSWindow), без SwiftUI | Текущий UI и так написан на AppKit через PyObjC: прямой маппинг сохраняет вид 1:1 |
| i18n | Порт движка `i18n.py`, те же файлы `locales/*.json` | Файлы переводов переносятся без изменений, включая славянские plural-правила |
| min macOS | **14.0 (Sonoma)**, только Apple Silicon | Требование MLX Swift (whisper.cpp работает и на 13, но планку держим по редактору) |
| Структура | Xcode-проект `ClickNSpeak/` в этом же репозитории, код в локальных SPM-пакетах (см. §2.1) | Python-версия живёт рядом до cutover |
| Concurrency | **Swift 6 strict concurrency с первого коммита**, actors для пайплайна | Гонки, которые в Python ловились годами руками (весь thread-safety раздел CLAUDE.md), ловит компилятор. Включать строгий режим на готовой кодовой базе в разы дороже |
| Bundle ID | Оставить `com.sergej.clicknspeak` | Сохраняет пути в Application Support и записи TCC (Accessibility, вероятно, придётся выдать заново из-за смены подписи бинарника) |

### 2.1 Структура кода (приоритет: развиваемость)

Не один Xcode-таргет, а тонкий app-таргет + локальные SPM-пакеты:

| Пакет | Содержимое |
|---|---|
| `CNSCore` | Config + миграции, i18n, Paths, FileLogger, канонизация терминов, InitialPromptBuilder |
| `CNSAudio` | AudioRecorder, ring buffer, VAD-чанкер |
| `CNSTranscription` | протокол `Transcribing`, движки whisper.cpp / cloud, HallucinationFilter, context builder |
| `CNSEditors` | протокол `Refining`, MLXLLM-редактор, Gemini/OpenAI |
| `CNSDictionary` | vocab provider, анализаторы, decay, метрики, phrase history, dataset logger |
| `CNSUI` | панели, меню, wizard, picker |

Выгоды: инкрементальная сборка, тесты каждого слоя без запуска приложения, потенциальный reuse (CLI-утилита батч-транскрипции, iOS-версия). Все внешние движки только за протоколами (`Transcribing`, `Refining`, `VoiceActivityDetecting`): смена движка не трогает пайплайн. DI через init injection, без фреймворков.

## 3. Бюджет размера

| Компонент | Оценка |
|---|---|
| Бинарник приложения | 3–6 MB |
| MLX / MLXNN / MLXLLM (Metal-кернелы) | 20–30 MB |
| whisper.cpp (статическая библиотека + Metal-шейдеры) | 5–15 MB |
| libfvad | < 0.5 MB |
| locales, иконки, ассеты | ~1 MB |
| **Итого `.app`** | **~35–60 MB, потолок 100 MB** (было 603 MB). Размер вторичен относительно скорости и точности |

Модели (вне бандла, скачиваются как сейчас): `ggml-large-v3-turbo.bin` 1.4 GB, Qwen 4-bit ~0.9 GB. Внимание: веса Whisper скачиваются заново в формате GGUF, старый MLX-кэш Whisper остаётся неиспользуемым (добавить пункт очистки в Advanced). Кэш Qwen переиспользуется, если направить `HubApi` swift-transformers в `~/.cache/huggingface`.

## 4. Целевая архитектура: что упрощается

### 4.1 Исчезает child-процесс транскрайбера
whisper.cpp работает in-process через C-интероп (модель грузится один раз и держится в памяти библиотеки, без multiprocessing-обвязки). Полностью удаляются:

- `process_watchdog.py`: kqueue-watchdog, PPID-поллер, orphan sweep, PGID-механика, killpg-обвязка сигналов.
- Протокол input_queue/output_queue, `_run_loop`, generation bump, рестарты child-процесса.
- `_watch_overdue_worker` упрощается: вместо рестарта процесса используется `Task`-таймаут с отменой и перезагрузка модели (`whisper_free` + повторный `whisper_init_from_file`).
- `ModelDownloader` child-процесс: заменяется на `URLSession` с прогрессом in-process (GGUF — один файл).

Семантика `TranscriberHealthMonitor` сохраняется, но «restart transcriber» означает reload моделей, а не kill процесса.

### 4.2 Главный поток
`_main_thread_queue` с дренажем раз в 0.3 s заменяется на `@MainActor` / `DispatchQueue.main.async`. Инвариант «весь AppKit только на главном потоке» сохраняется, но исчезает задержка до 0.3 s на каждую UI-операцию (попап и статусы станут отзывчивее, поведение то же).

Маппинг потоков:

| Сейчас (Python) | Станет (Swift) |
|---|---|
| rumps event loop + queue drain 0.3 s | main run loop, `@MainActor` |
| pynput hotkey thread | Carbon event handler (main run loop) |
| sounddevice callback thread | AVAudioEngine tap (audio thread) → чанкер |
| chunk_worker thread | выделенный `actor TranscriptionPipeline` (сериализует чанки, как сейчас child) |
| injection worker thread | `Task.detached` с PID-проверками через `@MainActor` |
| AiEditor daemon thread + timeout | `Task` + `withTimeout`, тот же non-blocking lock (`NSLock.try`) |
| rumps.timer (60 s flush, 3600 s maintenance, 15 min keep-alive) | `Timer` / `DispatchSourceTimer` |

### 4.3 Хоткей и права
`RegisterEventHotKey` не требует Input Monitoring и Accessibility для срабатывания. Следствия:

- Требуемых прав становится два: Microphone (запись) и Accessibility (CGEvent ⌘V-инжекция).
- Setup wizard сокращается на один шаг, пункт Input Monitoring в подменю Permissions удаляется.
- Исчезает правило «не перезапускать listener после выдачи прав на macOS 15»: проблема была специфична для pynput/CGEventTap.

Это единственное намеренное отступление от паритета (в меньшую сторону по количеству системных диалогов). Если нужен строгий паритет, оставить CGEventTap-путь как fallback.

### 4.4 GPU-конкуренция Whisper/Qwen
**Внимание:** после выбора whisper.cpp оба движка делят Metal GPU (Whisper через ggml-metal, Qwen через MLX). Исходное допущение о разведении на ANE и GPU не сработало — ANE-путь отпал вместе с WhisperKit. Non-blocking lock в редакторе сохраняем (защита от параллельных refine и повторных API-вызовов). Memory-pressure-скип для локального редактора сохраняем, но реализуем через `sysctlbyname("kern.memorystatus_vm_pressure_level")` нативно (без subprocess) либо `DispatchSource.makeMemoryPressureSource`, с тем же кэшем 5 s.

### 4.5 Целевые выигрыши в производительности (фиксируем как требования)

1. Аудио-чанки больше не сериализуются pickle'ом через multiprocessing queue: in-process движок работает с буфером напрямую, копирование исчезает.
2. Уходит дренаж main-thread queue раз в 0.3 s: HUD и статусы реагируют без искусственной задержки.
3. **VAD выносится из audio callback.** Сейчас webrtcvad вызывается прямо в callback sounddevice, это нарушение real-time-контракта аудиопотока. В Swift tap только пишет в lock-free ring buffer, VAD и чанкинг работают в отдельной задаче. Это исправление скрытого дефекта, а не отступление от паритета: пороги и логика чанкинга не меняются.
4. Холодный старт: сравнивается в bake-off честно (первая ANE-компиляция CoreML против тёплого Metal-шейдер-кэша).
5. Протокол `Transcribing` проектируется так, чтобы позже позволить настоящий streaming decode (частичные результаты внутри чанка), не ломая текущую чанковую архитектуру.

## 5. Маппинг модулей

Сложность: S (механический порт), M (порт с адаптацией API), L (ядро, построчный перенос логики).

| Python | Swift-компонент | Технологии | Слож. | Примечания |
|---|---|---|---|---|
| `main.py` | `AppDelegate`, `SingleInstanceGuard` | NSApplication, flock | S | Сигнальная обвязка почти вся не нужна (нет детей). `NSApplicationWillTerminate` cleanup остаётся |
| `src/app.py` (2809) | `SessionController` + `MaintenanceScheduler` | Swift Concurrency | **L** | Ядро state machine. Переносить построчно, флаги `is_recording` / `is_processing` / `_session_id` / `stop_worker` / `_append_to_popup` / `_worker_overdue` сохранить дословно |
| `src/recorder.py` | `AudioRecorder` | AVAudioEngine + libfvad | M | 16 kHz float32 mono, те же пороги чанкинга (1.0 s / 0.4 s / 0 s, target 3 s, max 8 s) |
| `src/transcriber.py` | `LocalTranscriber`, `HallucinationFilter` | WhisperKit | M/L | Фильтры (фразы, `_SUBWORD_REPEAT_RE`, CJK, повторы слов), guard'ы коротких/тихих чанков, language-retry с padding: перенести 1:1. Прогрев: та же стратегия |
| `src/cloud_transcriber.py` | `CloudTranscriber` | URLSession | M | WAV-кодирование из PCM (AVAudioFile или ручной RIFF-заголовок), те же таймауты 25 s / 300 s, duck-typing → протокол `Transcribing` |
| `src/ai_editor.py` | `LocalEditor`, `ExternalApiEditor`, `GeminiEditor`, `OpenAIEditor` | MLXLLM, URLSession | M/L | Все статусы refine (`ok/unchanged/timeout/skipped/error/disabled`), lock-семантика, `refine_file_text` с blocking-acquire и разбиением длинного текста |
| `src/injector.py` | `TextInjector` | NSPasteboard, CGEvent | S/M | Прямой маппинг: snapshot/restore по `changeCount`, ⌘V через CGEvent, Unicode-fallback через `CGEventKeyboardSetUnicodeString` |
| `src/hotkey_handler.py` | `HotkeyManager` | Carbon RegisterEventHotKey | S | См. §4.3 |
| `src/preview_panel.py` | `PreviewPanel`, `DictionaryAwareTextView` | NSPanel (non-activating) | M | HUD-вид, интерактивный/неинтерактивный режимы, ⌘D Add to Dictionary, `append_text` |
| `src/menu_bar.py` (3273) | `MenuBarController`, `SettingsActions` | NSStatusItem, NSMenu | **L** | Механический, но большой: все подменю (Model Cloud/Local, Languages+Auto, AI Editor, API Keys, Initial Prompt, Last Phrases, Permissions, Advanced), NSMenuDelegate-обновление прав, таймеры |
| `src/suggestions_panel.py` | `SuggestionsWindow` | NSWindow | M | Группировка по языкам |
| `src/terms_panel.py` | `TermsWindow` | NSTableView, NSSegmentedControl | M | Колонки и фильтр как сейчас |
| `src/replacements_panel.py` | `ReplacementsWindow` | NSTableView | M | Ручные пары + авто-пары из corrections |
| `src/file_drop_panel.py` | `FileDropWindow` | NSWindow drag-and-drop, NSOpenPanel | S/M | |
| `src/model_download_panel.py` | `ModelDownloadPanel` | NSPanel + NSProgressIndicator | S | |
| `src/i18n.py` | `I18n` | Foundation | S | Те же JSON, те же plural-правила RU/UK |
| `src/language_picker.py` | `LanguagePickerWindow` | NSWindow | S | |
| `src/setup_wizard.py` | `SetupWizard` | NSAlert-последовательность | M | Поллинг прав через Timer на main run loop вместо NSRunLoop-spin |
| `src/permissions.py` | `PermissionsService` | AVCaptureDevice, AXIsProcessTrusted | S | Input Monitoring и чтение TCC.db удаляются вместе с pynput |
| `src/utils.py` (1377) | `Config` (Codable) + `ConfigMigrations`, `Paths`, `FileLogger`, `LanguageScript`, `TermCanonicalizer`, `InitialPromptBuilder` | Foundation | M/L | Миграции v2→v9 сохранить (пользователи обновляются со старых конфигов). Атомарная запись: tmp + `rename` + fsync. Лог в тот же файл `~/Library/Logs/Click-n-speak.log` |
| `src/phrase_history.py` | `PhraseHistory` | Foundation | S | TSV append, кэш счётчика |
| `src/dataset_logger.py` | `DatasetLogger` | Foundation | S | Тот же JSONL и те же поля |
| `src/metrics.py` | `MetricsService` | Foundation | M | |
| `src/runtime_telemetry.py` | `RuntimeTelemetry` | Foundation | S | RSS через `task_info` вместо psutil |
| `src/runtime_health.py` | `HealthMonitor` | Foundation | S/M | «Рестарт» = reload моделей WhisperKit, тот же rolling window и cooldown 20 мин |
| `src/vocab_provider.py` | `VocabProvider` | Foundation | S/M | |
| `src/correction_analyzer.py` | `CorrectionAnalyzer` | Swift Regex | M | Схема corrections.json v2 без изменений |
| `src/log_analyzer.py` | `LogAnalyzer` | Swift Regex | M | Бакеты latin/cyrillic, те же пороги |
| `src/updater.py` | `UpdateChecker` | URLSession, GitHub API | S | |
| `src/app_updater.py` | `AppUpdater` | URLSession, hdiutil, helper script | M | Тот же DMG-flow: download → staging `.app.new` → swap-and-relaunch. Альтернатива Sparkle отклонена: кастомный флоу уже отлажен |
| `src/model_downloader.py` | `ModelDownloadService` | WhisperKit download API, HubApi | M | Без child-процесса, прогресс через delegate/AsyncSequence, cancel через `Task.cancel` |
| `src/process_watchdog.py` | **удаляется** | | | Нет дочерних процессов. Один раз при первом запуске Swift-версии: sweep осиротевших python-детей старой версии |
| `scripts/build.sh`, `setup.py`, py2app, `launcher.c` | Xcode build + `scripts/make_dmg.sh` | codesign, notarytool | M | py2app-обвязка целиком удаляется |

Подсчёт токенов для `_build_chunk_context` (лимит 220 BPE): использовать токенизатор из WhisperKit (он входит в пакет), лимит 700 символов и правила урезания recent_text перенести дословно.

## 6. Чеклист инвариантов (обязаны пережить порт)

Из раздела thread-safety CLAUDE.md, проверяется на приёмке каждой фазы:

1. Весь AppKit только на главном потоке (`@MainActor`).
2. Инжекция: две стабильные проверки frontmost-PID на главном потоке до вставки, сама вставка вне главного потока.
3. Восстановление клипборда только при совпадении `changeCount` (копия пользователя не затирается).
4. Non-blocking lock редактора, статус `skipped` при занятом lock, lock держится до конца HTTP-запроса при таймауте.
5. Memory-pressure-скип только для локального редактора, кэш значения 5 s, без блокировки пайплайна.
6. `is_processing` не сбрасывается по soft-таймауту, hard deadline у watchdog-задачи.
7. Очередь чанков без блокирующих put.
8. Атомарная запись config.json и prompt-файлов, пустой prompt-файл при непустых терминах игнорируется.
9. Guard'ы чанков: финальный ≤ 0.5 s пропуск, нефинальный < 3 s + RMS-тишина пропуск.
10. Троттлинг pre_warm 45 s, cold-idle порог 300 s, post-cold-warmup через 50 s, рестарт (reload) каждые 20 сессий.
11. `_session_id`-проверка перед показом попапа (защита от stale-инжекции).
12. Append-to-popup: хоткей при открытом попапе дописывает текст, `_previous_app_pid` сохраняется.
13. Decay: fast pass 14 дней (auto, use_count=0), slow pass 60 дней (non-manual, use_count < 3), manual вечны, реактивация автоматическая.
14. Cooldown отклонённых терминов 150 фраз, канонизация терминов по контракту `canonicalize_term`/`canonical_term_key`.
15. Ежедневные maintenance (decay, metrics) не чаще раза в 24 h, dirty-config flush раз в 60 s.

## 7. Совместимость данных: zero-migration

Не меняются ни пути, ни форматы:

| Ресурс | Путь |
|---|---|
| config.json (schema v9 + вся цепочка миграций) | `~/Library/Application Support/Click-n-speak/` |
| phrase_history.txt, corrections.json, metrics_history.jsonl, prompt-файлы, setup_done | там же |
| Датасет | `~/.clicknspeak_dataset.jsonl` |
| Лог | `~/Library/Logs/Click-n-speak.log` |
| Keychain | сервис `click-n-speak`, ключи `google_api_key` / OpenAI, через Security framework |

Особые случаи:
- **TCC**: bundle ID сохраняется, но смена бинарника/подписи, скорее всего, сбросит Accessibility. Wizard это обработает штатно при первом запуске.
- **Модели Whisper**: скачиваются заново в CoreML-формате. Старый MLX-кэш (~1.6 GB) не удаляем автоматически, добавим пункт в Advanced для очистки.
- **`stt_backend`/`stt_cloud_model`, `ai_editor_backend`**: значения конфига интерпретируются одинаково.

## 8. Фазы миграции

Этот раздел — roadmap (что и почему). Исполняемые work orders для моделей-исполнителей лежат в `docs/migration/`:

- `CONVENTIONS.md` — конвенции Swift-кодовой базы, читается в начале каждой сессии кодинга.
- `PHASE_0.md`, `PHASE_1.md` — готовые пофазные задания (задачи по 0.5–2 часа, критерии приёмки, инварианты, запреты «вне scope»).
- `PHASE_TEMPLATE.md` — шаблон для генерации файлов следующих фаз.

**Workflow исполнения по фазам:**
1. В начале фазы N сильная модель (Fable/Opus) генерирует `PHASE_N.md` по шаблону, читая соответствующий Python-код и результаты предыдущих фаз. Файлы фаз 2+ заранее не пишутся: они устаревают.
2. Кодинг ведёт модель-исполнитель (Sonnet) с промптом вида: «Прочитай docs/migration/CONVENTIONS.md и docs/migration/PHASE_N.md, выполни задачи N.x по порядку». Одна сессия — 1–3 задачи, не вся фаза.
3. Приёмку фазы (чеклист «Критерии завершения» + секция «Открытые вопросы») делает сильная модель или пользователь.
4. Принцип для исполнителя: **спецификация — это Python-код**, файл фазы говорит, что читать и что считается «готово».

### Фаза 0: bake-off STT-движков (5–8 дней) — выбор движка по замерам
Сравниваются **WhisperKit и whisper.cpp**, оба large-v3-turbo, на одном golden-наборе (30–50 WAV, эталоны из текущей Python-версии и `~/.clicknspeak_dataset.jsonl`, поле `raw_whisper`).

Метрики, по каждому языку (ru/uk/en):
- WER относительно текущего mlx-whisper (главный критерий: точность не хуже).
- Латентность warm на чанках 2 s и 8 s (важна latency одного короткого запроса, не throughput).
- Латентность cold + время первого прогрева (ANE-компиляция против Metal-шейдер-кэша).
- Пиковая память, поведение с initial prompt и language hint, устойчивость к тихим/коротким чанкам.
- MLXLLM + Qwen2.5-1.5B-4bit: латентность refine (цель ≤ 1 s warm), совместное потребление памяти с каждым из движков.

Выход фазы: заполненная таблица замеров, выбор основного движка, решение шипить ли второй как переключаемый fallback. Обе интеграции остаются в кодовой базе за протоколом `Transcribing`.

### Фаза 1: каркас (≈1 неделя)
Xcode-проект, SPM-зависимости, entitlements (без sandbox, дистрибуция вне App Store, как сейчас), `Config` + миграции v2→v9 + атомарная запись, `I18n`, `FileLogger`, `Paths`, single instance, menu bar со статусами (заглушки действий), таймеры maintenance.
Milestone: приложение запускается, читает боевой config.json, показывает полное меню на языке пользователя.

### Фаза 2: аудио и STT-ядро (1–2 недели)
`AudioRecorder` (AVAudioEngine + libfvad, чанкинг), `LocalTranscriber` (WhisperKit, прогревы, guard'ы, фильтры галлюцинаций), `_build_chunk_context`, `HotkeyManager`, `PreviewPanel` (неинтерактивный режим).
Milestone: хоткей → запись → чанки текста появляются в HUD в реальном времени.

### Фаза 3: полный цикл сессии (1–2 недели)
`SessionController` целиком: state machine, stop-и-drain, интерактивный попап с редактированием, `TextInjector` (PID-проверки, clipboard-restore, fallback-набор), append-to-popup, `PhraseHistory`, `DatasetLogger`, cleanup, overdue-watchdog (Task-версия).
Milestone: полный цикл диктовки с инжекцией в любое приложение, идентичный текущему.

### Фаза 4: редакторы и cloud STT (≈1 неделя)
`LocalEditor` (MLXLLM), `GeminiEditor`/`OpenAIEditor`, `CloudTranscriber` (оба бэкенда), vocab hints и misrecognitions в system prompt, `apply_replacements`, статусы refine в датасет, API Keys UI + Keychain.
Milestone: переключение stt_backend и ai_editor_backend из меню работает как сейчас.

### Фаза 5: словарь и аналитика (1–2 недели)
`VocabProvider`, `LogAnalyzer`, `CorrectionAnalyzer`, авто-анализ каждые N фраз (suggest/auto/disabled), `SuggestionsWindow`, `TermsWindow`, `ReplacementsWindow`, decay + maintenance, `MetricsService` + Statistics, Add to Dictionary (⌘D), синхронизация prompt-файлов + file watcher (DispatchSource).
Milestone: весь жизненный цикл словаря воспроизводит Python-версию на одних и тех же данных.

### Фаза 6: онбординг и обслуживание (≈1 неделя)
`PermissionsService`, `SetupWizard` (2 права), `LanguagePickerWindow`, autostart через `SMAppService`, стратегия прогрева (таблица из CLAUDE.md), `HealthMonitor`, `RuntimeTelemetry`, wake-observer.

### Фаза 7: обновления, загрузка моделей, файлы (≈1 неделя)
`UpdateChecker` + `AppUpdater` (DMG staging + swap-and-relaunch + staged-update при старте), `ModelDownloadService` + панель прогресса, `FileDropWindow` + транскрипция файлов (`refine_file_text`).

### Фаза 8: упаковка и приёмка паритета (≈1 неделя)
- codesign + notarytool, сборка DMG, аудит размера.
- Прогон чеклиста §6 и ручного чеклиста по каждому пункту меню/панели/флоу.
- Параллельная эксплуатация: Swift-версия в боевом режиме, Python-версия как эталон при расхождениях.
- Cutover: релиз через существующий update-канал GitHub Releases. Python-код остаётся в репо (каталог `legacy/` или тег) до стабилизации.

**Итого: 8–10 недель календарно** при плотной работе. Критический путь: фазы 0 → 2 → 3.

## 9. Риски

| # | Риск | Вероятность | Митигция |
|---|---|---|---|
| 1 | Оба движка дают WER хуже mlx-whisper на ru/uk | низкая | Bake-off фазы 0 это выявит до начала работ. Крайний fallback: тюнинг decoding-параметров whisper.cpp под референс, у него декодер ближе всего к OpenAI |
| 2 | ~~Первая ANE-компиляция CoreML~~ **СНЯТ**: выбран whisper.cpp (Metal), CoreML-путь не используется. Риск подтвердился на практике в фазе 0 — ANE на large-v3_turbo не стартовал вовсе — и стал одной из причин отклонить WhisperKit | — | — |
| 3 | Фильтры галлюцинаций калиброваны под mlx-whisper | средняя | Перекалибровка на golden-наборе в фазе 2 |
| 4 | Скрытое поведение в 17.8 K строк потеряется при порте | средняя | Построчный порт app.py/menu_bar.py, чеклист §6, порт тестов, параллельная эксплуатация в фазе 8 |
| 5 | TCC сбросит Accessibility при смене подписи | высокая | Штатная обработка wizard'ом, заметка в release notes |
| 6 | API churn MLX Swift / WhisperKit | низкая | Пин версий SPM, обновление осознанно |
| 7 | In-process крэш Metal/CoreML роняет всё приложение (раньше падал только child) | низкая | CoreML стабильнее MLX-child; крэш-репорты + auto-relaunch через существующий restart-механизм |

## 10. Тестирование

- CI на GitHub Actions (macOS runner): сборка, unit-тесты и отдельный job с golden-WER-регрессией на каждый PR. SwiftLint + swift-format в pre-commit (аналог текущего ruff).
- Порт логических тестов на Swift Testing: из 28 pytest-файлов ~20 не зависят от child-процессов и PyObjC (decay, метрики, анализаторы, канонизация, vocab, config-миграции, context builder, injector-логика через протоколы-моки).
- `test_process_watchdog.py` не портируется (нечего тестировать).
- Golden-набор: WAV-записи + эталонные транскрипты, сверка Python vs Swift на каждом релизе фазы 2+.
- Ручной чеклист паритета: каждый пункт меню, каждая панель, каждый сценарий state machine (включая append-to-popup, отмену, overdue, cold start).

## 11. Что НЕ переносится (осознанно)

- `process_watchdog.py`, вся multiprocessing-обвязка, py2app, `launcher.c`, numba_stub.
- Input Monitoring: право, fast-check через TCC.db, пункт меню, шаг wizard'а.
- Правило «не рестартовать listener на macOS 15» (проблема pynput).
- Задержка 0.3 s очереди главного потока (UI станет отзывчивее при том же поведении).
