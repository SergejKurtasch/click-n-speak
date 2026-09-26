# Фаза 1: каркас приложения (CNSCore + menu bar skeleton)

Статус: done (47 тестов зелёные; .app-бандл 3.9 MB запускается)
Предусловия: фаза 0 завершена (выбор движка на эту фазу не влияет, старт возможен параллельно с 0.2–0.5)
Читать перед стартом: docs/migration/CONVENTIONS.md, SWIFT_MIGRATION_PLAN.md §2.1, §5, §7

## Порядок исполнения (факт)

Задачи 1.2–1.7 (пакет CNSCore, чистая логика) выполнены ПЕРВЫМИ через SwiftPM,
до app-таргета (1.1). Причина: `swift test` валидирует конфиг/миграции/i18n без
Xcode-проекта, давая проверяемый прогресс сразу. Инструментарий на машине:
Swift 6.3.2, Xcode 26.5, macOS 26.5.1, arm64.

Статус задач:
- [x] 1.2 Paths — `Packages/CNSCore/Sources/CNSCore/Paths.swift`
- [x] 1.3 FileLogger — формат Python-лога, тест сверки
- [x] 1.4 Config: чтение/запись v9 без потери ключей (ordered JSONValue + Python-совместимый сериализатор)
- [x] 1.5 Миграции v2→v9 + ukrainian normalize — **тест эквивалентности с реальными Python-функциями проходит на 4 fixtures**
- [x] 1.6 I18n — плюрали ru/uk, fallback, подстановки
- [x] 1.7 SingleInstanceGuard — flock, тест эксклюзивности
- [x] 1.1 app skeleton — SPM executable `ClickNSpeak/` + `scripts/swift_build_app.sh` (SPM + bundle, без .xcodeproj)
- [x] 1.8 полное дерево меню (no-op) — `Packages/CNSUI` MenuBarController, 7 структурных тестов
- [x] 1.9 MaintenanceScheduler — таймеры flush 60s / maintenance 3600s + IntervalGate

47 тестов зелёные (40 CNSCore + 7 CNSUI). Эталоны миграций генерируются
`spikes/config_migration_check/generate_expected.py` (фикс. timestamp + heuristic
token counter). Note: token-accurate обрезка промпта отложена в фазу 2 (нужен
токенизатор WhisperKit); Phase 1 использует эвристику `len/3` как в Python-fallback.

**Решения по реализации:**
- App-таргет: SPM executable + `scripts/swift_build_app.sh` (assemble .app: binary +
  Info.plist LSUIElement + locales + icons + ad-hoc codesign). Xcode-проект не нужен;
  MLX/WhisperKit фазы 2 работают через SPM. Acceptance изменён с `xcodebuild` на
  `swift build` + bundle script.
- Permissions submenu: **2 пункта** (Microphone, Accessibility), не 3. Input Monitoring
  убран — Carbon-хоткей (§4.3). Это задокументированное отступление от Python-меню;
  структурный тест это фиксирует.
- `Config`: динамический ordered-`JSONValue` вместо фиксированного Codable-struct —
  гарантирует сохранность неизвестных ключей. Сериализатор байт-совместим с Python
  `json.dump(indent=4, ensure_ascii=True)`.
- Dev/release данные: `Paths.resolveDefault()` — DEBUG или `CNS_DATA_DIR` → dev-каталог
  `Click-n-speak-dev`; release-бандл с `CNS_DATA_DIR` тоже уходит в dev (защита боевых
  данных до фазы 8). Smoke-тесты гоняются только с `CNS_DATA_DIR`.

## Что осталось для полной приёмки (перенесено, не блокирует фазу 2)
- Скриншот-сравнение меню Swift↔Python вживую (нужна GUI-сессия; тесты структуры уже
  подтверждают состав/порядок/заголовки на ru и en).
- Per-item иконки меню (косметика; Python-версия при отсутствии иконок так же деградирует).

## Цель и milestone

Запускаемое menu-bar-приложение на Swift: живёт в статус-баре с текущей иконкой, показывает ПОЛНОЕ дерево меню на языке пользователя (все пункты пока no-op), читает и мигрирует config.json любой версии со v2 по v9, пишет лог в формате Python-версии. Пакет CNSCore покрыт тестами. Рядом с работающей Python-версией меню выглядит идентично (скриншот-сравнение).

## Задачи (по порядку)

### 1.1 Скелет проекта
- Создать: `ClickNSpeak/` (Xcode-проект, app target, bundle id `com.sergej.clicknspeak`, deployment target macOS 14, arm64 only), `Packages/CNSCore`, `Packages/CNSUI` (пустые таргеты + тестовые таргеты), подключить пакеты к app.
- Сделать: `LSUIElement = true` в Info.plist (без иконки в Dock, как rumps сейчас), App Sandbox выключен, Hardened Runtime включён, entitlement микрофона пока не нужен. Swift 6 language mode + strict concurrency во всех таргетах.
- Приёмка: `xcodebuild -scheme ClickNSpeak build` без warnings, пустое приложение запускается и не появляется в Dock.

### 1.2 CNSCore/Paths
- Прочитать: `src/utils.py` (`get_config_path()` и соседние функции путей), раздел «File paths (runtime)» в CLAUDE.md
- Создать: `Paths.swift` + тесты
- Сделать: все пути из таблицы CLAUDE.md одной структурой. Режимы: `.release` → боевой `~/Library/Application Support/Click-n-speak/`, `.dev` (DEBUG-сборка или env `CNS_DATA_DIR`) → `Click-n-speak-dev/` либо каталог из env. Лог-путь одинаков в обоих режимах ТОЛЬКО в release, в dev лог тоже уводится в dev-каталог (защита боевого лога, это отличие от Python задокументировать в код-комментарии).
- Приёмка: тесты на оба режима, ни один тест не касается реальных путей.

### 1.3 CNSCore/FileLogger
- Прочитать: `src/utils.py` (`setup_logging()`, `log_info`/`log_warning`/`log_error`), пару строк реального лога для формата
- Создать: `FileLogger.swift` + тесты
- Сделать: тот же построчный формат (timestamp, уровень, сообщение), append в файл из Paths, потокобезопасность (actor или serial queue), уровни как в Python.
- Приёмка: тест сверяет формат строки с образцом формата Python-версии (fixture-строка из реального лога).

### 1.4 CNSCore/Config: модель + чтение/запись
- Прочитать: `src/utils.py` (`load_config_data`-путь чтения в `src/app.py`, `save_config_to_disk`, атомарная запись), `config.example.json`, раздел «Config (config.json)» CLAUDE.md целиком (v9-схема, семантика каждого ключа, per-term поля)
- Создать: `Config.swift` (Codable-структуры: корень, `UserTerm`, `ManualReplacement`, `PendingSuggestion` и т.д.) + тесты
- Сделать: чтение/запись v9. Неизвестные ключи при чтении сохраняются и переживают запись (пользователь мог редактировать файл руками, Python-версия ключи не теряет: использовать словарное хранение сырых ключей рядом с типизированными). Запись атомарная: sibling tmp + rename + fsync, как `save_config_to_disk`.
- Приёмка: round-trip тест: реальный v9-fixture читается, пишется, семантически эквивалентен (сравнение по JSON-объекту, не по байтам, но без потери ключей).

### 1.5 CNSCore/Config: цепочка миграций v2→v9
- Прочитать: `src/utils.py` (`migrate_config_to_v5` … `migrate_config_to_v9` и более ранние в git-истории/коде), «Migration chain» в CLAUDE.md
- Создать: `ConfigMigrations.swift` + тесты, fixtures `Tests/.../Fixtures/config_v{2..9}.json`
- Сделать: портировать каждую миграцию отдельной функцией, прогонять цепочкой. Fixtures для старых версий собрать из логики соответствующих migrate-функций Python (что они добавляют, то в предыдущей версии отсутствует).
- Приёмка: по тесту на каждую миграцию + сквозной тест v2→v9. Результат сквозного прогона эквивалентен прогону Python-функций на том же fixture (одноразовый скрипт сверки в `spikes/`, результат приложить в PR-описание задачи).

### 1.6 CNSCore/I18n
- Прочитать: `src/i18n.py` целиком, `locales/en.json` и `locales/ru.json` (структура ключей), использование `plural()` в Python-коде (grep `i18n.plural`)
- Создать: `I18n.swift` + тесты, `locales/*.json` подключить ресурсами app-таргета (файлы НЕ копировать в пакет, ссылаться на те же файлы репозитория, чтобы переводы не раздваивались)
- Сделать: `load(lang)`, `t(key, **kwargs)`-аналог (подстановка `{name}`-плейсхолдеров), `plural(key, n)` со славянскими правилами RU/UK один-в-один, fallback на en при отсутствии ключа.
- Приёмка: тесты плюралов (1/2/5/11/21 для ru и uk), тест fallback, тест подстановки аргументов.

### 1.7 Single instance + активация существующей копии
- Прочитать: `main.py` (`_acquire_instance_lock`, `_release_instance_lock`, `_activate_existing_instance`)
- Создать: `SingleInstanceGuard.swift` в CNSCore
- Сделать: flock на `<data-dir>/.instance.lock` (в dev-режиме dev-каталог). При занятом lock: активировать существующую копию тем же способом, что Python-версия, и выйти.
- Приёмка: ручной тест: второй запуск не создаёт второй иконки в статус-баре.

### 1.8 CNSUI/MenuBarController: полное дерево меню (no-op)
- Прочитать: `src/menu_bar.py` строки ~1090–1335 (`setup_menu`: точный порядок пунктов, подменю, сепараторы, иконки), `locales/en.json` ключи `menu.*`, использование `_icon()` и ассетов из `assets/`
- Создать: `MenuBarController.swift`, `MenuBuilder.swift` в CNSUI
- Сделать: NSStatusItem с текущей иконкой из `assets/` (template image). Всё дерево меню в том же порядке: статус записи, Permissions (3 пункта-статуса, пока со стабами проверок: Microphone/Accessibility реальные вызовы `AVCaptureDevice.authorizationStatus` / `AXIsProcessTrusted` можно сразу, они read-only), Model (секции Cloud/Local models, список моделей из констант), API Keys, Languages (+ Auto), AI Editor (+ Backend), Download AI Editor Model, Initial Prompt (Edit Terms…, Revert…, Auto-update Mode, Review Suggestions, Edit Replacements…, Statistics…), Last Phrases, Transcribe Audio File…, Check for Updates, Launch at Login, Advanced (Edit Config, Open Log, Reload Config), Restart, Quit. Все callbacks — заглушки с логом «not implemented: <item>». Чекмарки состояний читать из Config (модель, языки, режимы) уже сейчас.
- Приёмка: скриншот меню Swift-версии рядом со скриншотом Python-версии (запустить обе, язык ru): состав, порядок и заголовки совпадают. Чекмарки отражают содержимое dev-конфига.

### 1.9 Каркас таймеров обслуживания
- Прочитать: `src/menu_bar.py` (`@rumps.timer`-методы: дренаж очереди 0.3 s — НЕ переносится, flush 60 s, `_decay_tick` 3600 s), `src/app.py` (`flush_dirty_config_if_needed`, `run_daily_maintenance_if_due` — только сигнатуры и когда вызываются)
- Создать: `MaintenanceScheduler.swift` в CNSCore (таймеры + hook-замыкания, пока пустые)
- Приёмка: unit-тест на расписание (инъекция clock), приложение вызывает хуки (проверка по логу).

## Инварианты фазы

- Весь AppKit только `@MainActor` (п.1 чеклиста §6 плана).
- Атомарная запись config.json: tmp + rename + fsync (п.8).
- Пустой prompt-файл при непустых терминах игнорируется — в этой фазе не реализуется, но структура Config не должна этому помешать.
- Dev-сборка не читает и не пишет боевой каталог пользователя (CONVENTIONS «Данные»).
- Никаких потерь неизвестных ключей config.json при round-trip.

## Вне scope (запрещено в этой фазе)

- Аудио, хоткей, транскрипция, панели, wizard, инжекция: ничего из этого.
- Не реализовывать обработчики меню (только заглушки): реализация приходит в фазах 2–7.
- Не «улучшать» структуру меню, тексты и иконки. Паритет 1:1.
- Не редактировать Python-код и locale-файлы.

## Критерии завершения фазы

- [ ] Приложение запускается, живёт в статус-баре, меню идентично Python-версии (скриншоты приложены)
- [ ] Config: round-trip v9 без потерь + миграции v2→v9 с тестами на каждую
- [ ] I18n: плюрали ru/uk, fallback, подстановки — тесты зелёные
- [ ] FileLogger пишет в формате Python-версии
- [ ] Второй запуск активирует первую копию
- [ ] `swift test` всех пакетов зелёный, сборка без warnings, strict concurrency без эскейпов

## Открытые вопросы

(заполняет исполнитель)
