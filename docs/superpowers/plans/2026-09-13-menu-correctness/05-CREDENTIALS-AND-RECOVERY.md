# Эпоха 05 — API-ключи и точное восстановление runtime

> Для исполнителя: применять `executing-plans`; читать 00-PLAN.md и выполнять только эту эпоху. Глобальные ограничения из общего плана обязательны, флажки отмечать по факту.

**Цель:** окно ключей правдиво описывает сохранение, а recovery открывает именно тот провайдер или модель, из-за которых возникла ошибка.

**Архитектура:** KeychainHelper остаётся владельцем доступа к ключам; UI получает только сведения об источнике. AppRuntimeCoordinator публикует типизированную команду восстановления с адресатом, MenuBarController её отображает.

**Стек:** Swift, Security.framework, AppKit; fake credential store в тестах.

**Спецификация:** [00-PLAN.md](00-PLAN.md), C05; сначала эпоха 02. Большая эпоха с независимой границей A/B.

## Исходная проблема

- `onGeminiApiKey` и `onOpenAIApiKey` проверяют локальный формат и записывают Keychain, хотя кнопка обещает «Сохранить и проверить». Подготовка клиента не доказывает работоспособность ключа.
- Gemini берёт `GOOGLE_API_KEY`, затем `GOOGLE_GENAI_API_KEY`, и лишь затем Keychain. Сохранение или очистка Keychain может не менять фактический ключ.
- `onRuntimeRecovery` выбирает окно ключа по desired STT, а ошибка может относиться к Gemini-редактору. При OpenAI STT + Gemini editor это разные адресаты.
- `recoverLocalModel` также восстанавливает предполагаемую модель вместо передачи точного ID из причины ошибки.

## Файлы

Изменить:

- `Packages/CNSCore/Sources/CNSCore/KeychainHelper.swift`.
- `Packages/CNSUI/Sources/CNSUI/MenuBarController.swift`.
- `Packages/CNSUI/Sources/CNSUI/MenuState.swift`: snapshot и общий тип recovery вместо дублирующего enum.
- `ClickNSpeak/Sources/ClickNSpeak/RuntimeServiceFactory.swift`.
- `ClickNSpeak/Sources/ClickNSpeak/AppRuntimeCoordinator.swift`.
- `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`.
- `ClickNSpeak/Tests/ClickNSpeakTests/AppRuntimeCoordinatorTests.swift`.
- `Packages/CNSUI/Tests/CNSUITests/MenuStateTests.swift` и `MenuStructureTests.swift`.
- Шесть JSON-файлов в `locales/`.

Создать:

- `Packages/CNSCore/Sources/CNSCore/CredentialMetadata.swift`.
- `Packages/CNSCore/Sources/CNSCore/RuntimeRecoveryCommand.swift`.
- `Packages/CNSCore/Tests/CNSCoreTests/CredentialMetadataTests.swift`.
- `Packages/CNSUI/Tests/CNSUITests/CredentialDialogTests.swift`.

## Блок A — честное сохранение и источник ключа

- [ ] Разделить результат локальной проверки формата, записи Keychain и фактической авторизации. В этой эпохе не делать сетевой запрос проверки.
- [ ] Заменить подпись кнопки на «Сохранить» во всех локалях; после записи показывать «Ключ сохранён. Работоспособность проверяется при обращении к сервису». Не показывать «Ключ проверен» или «API доступен».
- [ ] Ввести метаданные без секрета:

```swift
public enum CredentialSource: Sendable, Equatable {
    case none
    case keychain
    case environment(variable: String)
}

public struct CredentialMetadata: Sendable, Equatable {
    public let source: CredentialSource
    public let isConfigured: Bool
}
```

- [ ] Вычислять source и фактическое значение одним правилом приоритета. В тестах инъецировать lookup окружения и Keychain. Сохранить прежнюю обработку пустых значений; если она некорректна, сначала отдельный регрессионный тест.
- [ ] В UI отображать только источник и признак наличия. Не возвращать текущий секрет в текстовое поле, логи, telemetry, representedObject или Config.
- [ ] Если ключ задан окружением, показать имя переменной и объяснение, что изменение требует перезапуска процесса с обновлённым окружением. Отключить Save/Clear Keychain в этом состоянии: текущее окно управляет действующим ключом, редактирование неактивного fallback не входит в его контракт.
- [ ] При Keychain/none разрешить ввод нового ключа. Пустой ввод не удаляет существующий ключ; удаление только отдельной командой Clear. При ошибке записи/удаления показать ошибку и сохранить введённый текст для повторной попытки.
- [ ] `onCredentialsChanged(provider)` вызывать только после успешного изменения хранилища. Не вызывать для Cancel, ошибки, неизменённого значения или закрытия окна.
- [ ] Сохранить существующую quarantine/revalidation: новые активности не используют клиента со старым credential generation, уже начатая сессия завершает собственный snapshot. Не записывать секрет в recovery.

Проверить fake-тестами:

| Сценарий | Ожидание |
|---|---|
| Корректный по формату ввод | Одна запись, один provider callback, ни одного HTTP-запроса |
| Неподходящий формат | Нет записи и callback, понятная ошибка |
| Ошибка Keychain | Ввод сохранён, runtime не объявлен перевалидированным |
| Cancel / пустой ввод | Существующий ключ не меняется |
| Clear | Удаление только выбранного account; missing credentials сохраняются через retry |
| Две Gemini env variables | Приоритет GOOGLE_API_KEY, в UI только имя переменной |
| Только GOOGLE_GENAI_API_KEY | Указан этот источник; Keychain не выдаётся за действующий |
| OpenAI | Сохранена текущая политика Keychain; новый env override не добавлен |

**Граница A:** UI и credential metadata готовы, старый recovery ещё работает как раньше; целевые Core/UI/App tests проходят. Возможный коммит: `fix: clarify API key storage and credential sources`.

## Блок B — адресат команды восстановления

- [ ] Добавить общий тип в CNSCore, доступный приложению и CNSUI без циклического импорта executable target:

```swift
public enum RuntimeRecoveryKind: String, Sendable {
    case downloadModel, redownloadModel, openAPIKeys
    case selectCloudBackend, keepPreviousRuntime, retry
}

public enum RuntimeRecoveryTarget: Sendable, Equatable {
    case none
    case provider(String)
    case model(String)
}

public struct RuntimeRecoveryCommand: Sendable, Equatable {
    public let kind: RuntimeRecoveryKind
    public let target: RuntimeRecoveryTarget
    public let generation: Int
}
```

- [ ] Публичные memberwise initializers реализовать явно. Значения provider/model валидировать по существующим registry; эти строки — идентификаторы, не ошибки API и не пользовательский ввод.
- [ ] Заменить дублирующиеся app/UI recovery enums этим контрактом. Обновить `RuntimeCoordinatorState.degraded`, `MenuRuntimeSnapshot`, callback и все тестовые construction sites. Не потерять target при прежнем преобразовании через `.rawValue`.
- [ ] Создавать command там, где ещё доступен `RuntimePreparationError`: credentialMissing → provider; modelMissing/modelCorrupted → exact modelID. Для initializationFailed сохранять известный компонент подготовки и его target до преобразования в отображаемый текст.
- [ ] Различать ошибку подготовки STT и editor. Не восстанавливать target из текущего desired config: пользователь может уже выбрать другую конфигурацию.
- [ ] Заполнять generation текущим `desiredGeneration` владельца при публикации ошибки. Перед исполнением любой recovery-команды сравнивать generation с текущим владельцем, включая открытие диалога ключа/загрузки. Если меню устарело после нового выбора, отклонить старую команду и обновить меню; она не должна менять новый intent.
- [ ] Для `openAPIKeys` открыть диалог command.target.provider. Для download/redownload передавать точный ModelDescriptor из registry; неизвестный или более не подходящий target показать как недоступную команду.
- [ ] Для retry/keepPreviousRuntime/selectCloudBackend сохранить прежнюю транзакционность. Keep previous не разрешает использовать отозванный ключ и не снимает quarantine.
- [ ] При будущей интеграции эпохи 06 redownload проходит ту же защиту артефактов, что удаление; не добавлять новый прямой `removeItem` в recovery.

Регрессии обязательны: OpenAI STT + отсутствующий Gemini editor key открывает Gemini; сломанный Qwen не предлагает Whisper; смена desired во время recovery не применяет старый target; недостающий ключ не восстанавливается через keepPrevious; ошибочная подготовка editor не публикует наполовину новую пару.

## Проверки и завершение

```bash
source venv/bin/activate
swift test --package-path Packages/CNSCore
swift test --package-path Packages/CNSUI
swift test --package-path ClickNSpeak
```

- [ ] Тесты диалогов не обращаются к настоящему Keychain и не читают секреты из пользовательского окружения.
- [ ] Шесть локалей содержат одинаковый набор новых ключей; recovery labels остаются локализованными.
- [ ] Ошибка API при реальном использовании по-прежнему обрабатывается downstream; сохранение ключа не объявляется успешной авторизацией.
- [ ] Коммит блока B: `fix: route runtime recovery to the failed component`; обновить AGENTS.md через предусмотренный навык.

**Готово, когда:** сохранение имеет честную подпись и источник, а каждый recovery действует на проверенный адресат конкретного актуального отказа.
