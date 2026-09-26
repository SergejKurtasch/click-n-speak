# Конвенции Swift-кодовой базы Click-n-speak

Этот файл читается в начале КАЖДОЙ сессии кодинга по миграции, вместе с файлом текущей фазы `docs/migration/PHASE_N.md`. Он стабилен: меняется только осознанным решением, не по ходу задачи.

## Главный принцип

**Спецификация — это Python-код.** Файл фазы говорит, ЧТО портировать и по каким критериям принимать. КАК оно должно себя вести, определяет исходник в `src/*.py` и тесты в `tests/*.py`. Перед портированием модуля обязательно прочитай его Python-оригинал целиком. При любом расхождении между этим документом и Python-кодом поведение Python-кода первично (кроме пунктов, явно помеченных в плане как «осознанное отступление», см. SWIFT_MIGRATION_PLAN.md §11 и §4.5).

Если во время работы обнаруживаешь поведение Python-кода, которое не описано в фазовом файле и влияет на дизайн: не изобретай решение молча, зафиксируй находку в секции «Открытые вопросы» файла фазы и выбери вариант, наиболее близкий к текущему поведению.

## Структура проекта

```
ClickNSpeak/                    Xcode-проект, тонкий app-таргет
Packages/
  CNSCore/                      Config + миграции, i18n, Paths, FileLogger,
                                канонизация терминов, InitialPromptBuilder
  CNSAudio/                     AudioRecorder, ring buffer, VAD-чанкер
  CNSTranscription/             протокол Transcribing, движки (WhisperKit /
                                whisper.cpp / cloud), HallucinationFilter,
                                context builder
  CNSEditors/                   протокол Refining, MLXLLM, Gemini/OpenAI
  CNSDictionary/                vocab provider, анализаторы, decay, метрики,
                                phrase history, dataset logger
  CNSUI/                        панели, меню, wizard, picker
docs/migration/                 файлы фаз, этот файл, результаты bake-off
spikes/                         одноразовые harness'ы (не входят в app)
```

Зависимости пакетов направлены вниз: CNSUI → CNSDictionary/CNSEditors/CNSTranscription/CNSAudio → CNSCore. Циклов нет. App-таргет только собирает всё вместе (composition root, DI через init injection, без DI-фреймворков).

## Язык и стиль

- Swift 6, strict concurrency включён во всех пакетах с первого коммита. Ошибки concurrency чинятся правильной изоляцией (actor, @MainActor, Sendable), не `@unchecked Sendable` и не `nonisolated(unsafe)`. Эти два эскейпа допустимы только с комментарием-обоснованием.
- Код, комментарии, коммиты: английский.
- Ошибки: типизированные `enum ... : Error` на каждый домен. Никаких `try!` и force unwrap `!` вне тестов. `fatalError` только для programmer errors, недостижимых по контракту.
- Логирование: через `FileLogger` из CNSCore в тот же файл `~/Library/Logs/Click-n-speak.log` и в том же формате строк, что Python `setup_logging()` (см. `src/utils.py`). os.log не используем: пользовательская привычка и парсер `scripts/analyze_runtime_log.py` завязаны на текущий формат.
- Именование: как в окружающем Swift-коде. Имена концепций сохраняем из Python (session, chunk, refine, decay, pending suggestions и т.д.), чтобы grep по обеим кодовым базам находил парные места.

## Concurrency-модель (фиксирована)

- Весь AppKit только `@MainActor`.
- `TranscriptionPipeline` — actor, сериализует обработку чанков (роль бывшего child-процесса).
- Audio tap НЕ делает ничего, кроме записи в lock-free ring buffer. VAD и чанкинг живут в отдельной задаче-потребителе.
- Блокирующих вызовов на MainActor нет. Таймауты через structured concurrency (`Task` + отмена), не через `sleep` в цикле.
- Non-blocking lock редактора: `NSLock().try()`-семантика как в `ai_editor.py`, все статусы refine (`ok/unchanged/timeout/skipped/error/disabled`) сохраняются.

## Данные и безопасность разработки

- **До фазы 8 Swift-версия НЕ трогает боевые данные пользователя.** Все пути берутся из `Paths`, который в dev-сборке (`#if DEBUG` или env `CNS_DATA_DIR`) указывает на `~/Library/Application Support/Click-n-speak-dev/`. Боевой каталог `Click-n-speak/` подключается только в release-сборке фазы 8.
- Тесты работают только с fixtures во временных каталогах. Тест, который читает или пишет реальные пути пользователя, это баг.
- Форматы файлов (config.json v9, phrase_history TSV, corrections.json v2, dataset JSONL, metrics JSONL) байт-в-байт совместимы с Python-версией. Проверяется тестами на fixtures, снятых с реальных файлов.
- Ключи API только через Keychain (сервис `click-n-speak`) и env-переменные, как сейчас. Никаких ключей в config, логах, коде.

## Тесты

- Swift Testing (`import Testing`), не XCTest, для новых тестов.
- Каждый портированный Python-тест получает Swift-аналог с тем же именем-смыслом. Файл фазы перечисляет, какие pytest-файлы покрывают портируемый модуль.
- `swift test` каждого пакета зелёный перед завершением любой задачи. Сборка app-таргета без warnings.

## Git

- Conventional Commits (`feat:`, `fix:`, `refactor:`, `chore:`, `test:`, `docs:`).
- Коммит только по явной просьбе пользователя.
- Python-код (`src/`, `tests/`, `main.py`) в рамках миграции не редактируется, кроме задач, явно описанных в файле фазы (пример: debug-флаг дампа чанков в фазе 0).

## Definition of Done любой задачи фазы

1. Код собирается, `swift test` зелёный, strict concurrency без эскейпов.
2. Критерии приёмки задачи из файла фазы выполнены и проверены командами/действиями, указанными там же.
3. Инварианты фазы (секция «Инварианты» файла фазы) перечитаны, ни один не нарушен.
4. Ничего вне scope фазы не изменено. Секция «Вне scope» файла фазы — запрет, а не пожелание.
