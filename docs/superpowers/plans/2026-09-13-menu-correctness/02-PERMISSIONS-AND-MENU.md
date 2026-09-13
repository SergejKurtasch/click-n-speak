# Эпоха 02. Разрешения, мастер и однозначные команды

> Для исполнителя: `executing-plans`; прочитать 00-PLAN.md. Реализация только этой эпохи.

**Цель:** восстановление доступности записи после выдачи разрешений, видимый результат ручного мастера и явное выключение AI.

**Архитектура:** текущие PermissionServicing, AppLaunchCoordinator и MenuState остаются владельцами. Добавить тестируемую функцию согласования готовности hotkey и явно различать автоматический и ручной вход в setup.

**Стек:** Swift 6, AppKit, Carbon, существующая локализация.

**Спецификация:** C02, C10; пункты 1, 4, 5, 10, регрессии остальных простых команд.

## Файлы

- Изменить `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`, `AppLaunchCoordinator.swift`.
- Изменить `Packages/CNSUI/Sources/CNSUI/SetupWizard.swift`, `MenuBarController.swift`.
- Создать `ClickNSpeak/Tests/ClickNSpeakTests/PermissionActivationTests.swift`.
- Дополнить `Packages/CNSUI/Tests/CNSUITests/SetupWizardTests.swift`, `MenuStructureTests.swift`, `MenuStateTests.swift`.
- Изменить все шесть `locales/*.json`.

## A. Разрешения → регистрация hotkey

- [ ] Воспроизвести через fake permission/hotkey: startup без прав, wizard skipped, STT ready, grant обоих прав, menu refresh. До исправления startCount остаётся 0; ожидается 1.
- [ ] Сделать регистрацию инъецируемой для AppDelegate: замыкание `@MainActor () -> Bool` вызывает текущий `hotkey.start()`. Не тестировать настоящую Carbon-регистрацию в unit tests.
- [ ] Использовать единый метод `reconcileHotkeyAvailability()` после свежего снимка разрешений, завершения wizard и перехода runtime в ready/degraded-with-ready-STT. Повторные вызовы идемпотентны.

```swift
@MainActor
func shouldStartHotkey(
    permissionsGranted: Bool,
    runtimeCanRecord: Bool,
    alreadyStarted: Bool,
    terminating: Bool
) -> Bool {
    permissionsGranted && runtimeCanRecord && !alreadyStarted && !terminating
}
```

- [ ] Это условие — общий gate, но интеграционные тесты должны проверять реальные точки вызова AppDelegate, а не только truth table функции.
- [ ] Не регистрировать hotkey во время termination и до готовности runtime. На ошибке регистрации не ставить `hotkeyStarted = true`; показать локализованное уведомление и разрешить повтор при следующем осмысленном событии.
- [ ] Проверить denied → granted, только один granted, повторный refresh, STT unavailable, failure первого start и успех следующего. При отзыве прав не показывать ложную готовность; не уничтожать уже полученный черновик.

## B. Ручной запуск мастера всегда видим

Добавить `SetupInvocation: Sendable { case automatic, manual }` и параметр `run(invocation:)` с default `.automatic` в SetupWizard. AppLaunchCoordinator передаёт `.manual` из `runPermissionSetup(force: true)` только для команды меню; первый запуск передаёт `.automatic` явно, чтобы `force` не путал происхождение вызова.

- [ ] Написать тест: все разрешения granted, manual invocation → presenter получает один информационный экран; automatic invocation → экранов 0.
- [ ] На ручном входе при всех разрешениях показать «Разрешения уже настроены» и кнопку «Закрыть». Не сбрасывать TCC, setup_done или language_picker_done.
- [ ] При недостающих правах сохранить текущие асинхронные шаги и timeout; статический guard `SetupWizard.isActive` оставить. Повторный вход не создаёт второго мастера.
- [ ] Назвать пункт «Мастер разрешений…» во всех локалях: его фактический охват становится очевидным. Не строить новый мастер моделей/ключей.
- [ ] После завершения мастера обновить permission snapshot и согласовать hotkey через блок A.

## C. Явное выключение AI и точные подписи языка

- [ ] Добавить первым вариантом AI-подменю «Выключен» и `onAIBackendDisabled()`. Он отправляет `ai_editor_enabled=false` через существующий onConfigChanged.
- [ ] Изменить Local/Gemini: всегда выбрать backend и включить редактор; повторный выбор уже желаемого backend не выключает его и не начинает лишнюю загрузку.
- [ ] Галочка `.on` отражает активное состояние, `.mixed` — выбранное ожидающее. При отключении во время занятой сессии старый snapshot продолжает работу; UI не объявляет выключение активным раньше commit.
- [ ] Обновить тест, который сейчас закрепляет выключение повторным выбором. Новые сценарии: disabled → local, local → same local, local → gemini, gemini → disabled, pending → disabled.
- [ ] Удалить литеральный `▶` из `menu.ai_backend`: системная стрелка submenu уже есть.
- [ ] Уведомление смены языка: «Язык распознавания изменён. Язык интерфейса изменится после перезапуска». Сохранить reducer LanguageSettings и шесть языков без новой модели локализации.

## Проверки и готовность

```bash
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSUI
source venv/bin/activate && swift test --disable-index-store --package-path ClickNSpeak
source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSCore --filter I18nTests
```

- [ ] Проверить locale key parity и русское меню с одной стрелкой.
- [ ] В ручном smoke подтвердить вызов мастера при зелёном индикаторе; реальные TCC менять только в согласованной тестовой установке.
- [ ] Коммиты по независимым блокам: `fix: reconcile hotkey readiness after permission changes`, `fix: make setup and editor menu actions explicit`.

**Готово:** после выдачи прав hotkey запускается один раз; ручной мастер не молчит; AI имеет явный disabled-вариант; текущие языковые и runtime snapshots сохранены.
