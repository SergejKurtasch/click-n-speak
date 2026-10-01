# Эпоха 10 — приёмка всех пунктов меню

> Для исполнителя: применять `executing-plans`; читать 00-PLAN.md и выполнять только эту эпоху. Глобальные ограничения из общего плана обязательны, флажки отмечать по факту.

**Цель:** проверить полную цепочку menu action → owner → изменение состояния/файлов → отображаемый результат для всех пунктов скриншота.

**Архитектура:** существующие unit/integration suites дополняются только недостающими сквозными регрессиями. Ручная приёмка проверяет собранное приложение и системные диалоги, которые fake-тесты не доказывают.

**Стек:** SwiftPM, существующие shell gates, Python venv для acceptance utilities; тестовый профиль и disposable bundle.

**Спецификация:** [00-PLAN.md](00-PLAN.md), C01–C10; эпохи 01–09 завершены и проверены.

## Объём эпохи и файлы

Основные тестовые файлы: `Packages/CNSUI/Tests/CNSUITests/MenuStructureTests.swift`, `MenuStateTests.swift`, `AppResourcesTests.swift`, `UIPanelsTests.swift`; новые regression suites предыдущих эпох; `ClickNSpeak/Tests/ClickNSpeakTests/AppDelegateStartupTests.swift` и `AppRuntimeCoordinatorTests.swift`.

При необходимости создать `ClickNSpeak/Tests/ClickNSpeakTests/MenuWorkflowTests.swift` для сквозных owner transitions. Тестовые вспомогательные скрипты — только `scripts/`, например `scripts/verify_menu_plan_coverage.py`, если повторяемая проверка действительно нужна. Отдельный framework UI-автоматизации и новый отчётный сервис не создавать.

Это эпоха проверки и небольших исправлений обнаруженных регрессий. Новую архитектурную проблему оформить как конкретный остаток следующей эпохи; не прятать её в зелёном результате и не растягивать текущую эпоху без границы.

## Шаг 1 — зафиксировать проверяемый кандидат

- [ ] Прочитать текущие AGENTS.md и флажки эпох 01–09. Незавершённые критерии — препятствие общей приёмке, а не повод считать их пройденными по наличию файла.
- [ ] Зафиксировать git revision, dirty diff, версии Swift/macOS и способ запуска в чате. Отделить изменения пользователя, которые уже были в исходном снимке.
- [ ] Использовать isolated `CNS_DATA_DIR` и синтетические config/history/dictionary fixtures для изменяющих сценариев. Не копировать реальные API-ключи, clipboard и историю в fixtures.
- [ ] Fake adapters покрывают ошибки сети, Keychain, записи диска, процесса и TCC. Само ручное открытие System Settings не является доказательством успешной работы hotkey/инъекции.

## Шаг 2 — матрица по скриншоту

В каждой строке проверить действие, наблюдаемый результат и отрицательный сценарий. Для исправленных путей обязательна автоматическая регрессия; для уже рабочих простых команд достаточно существующих подходящих тестов и ручного smoke, без тестов, повторяющих строку реализации.

| № / пункт | Проверяемое поведение | Ошибка или пограничный сценарий | Где закрывается |
|---|---|---|---|
| 1. Разрешения | Microphone и Accessibility открывают свои системные разделы; индикатор отражает свежий snapshot; hotkey стартует один раз после готовности | Отказ/частичная выдача, grant после skipped wizard, повтор refresh, runtime ещё не готов, shutdown | Эпоха 02, PermissionActivationTests |
| 2. Модель — Local | Выбор установленной Whisper модели приводит к подготовке и единому runtime commit; active/desired различимы | Missing/corrupt model, подготовка в фоне, отменённый intent, старая запись ещё работает | AppRuntimeCoordinatorTests, эпохи 05–06 |
| 2. Модель — Cloud | Gemini/OpenAI выбираются и активируются с нужным провайдером и cloud model | Отсутствующий ключ, смена ключа при активной сессии, ошибка editor при рабочем STT | Эпоха 05 |
| 2. Загрузка модели | Правильный ID/размер, progress, cancel/retry, checksum до активации | Late callback, invalid range, checksum failure, cancel на validation; старые transfer policy tests проходят | ModelDownloaderNetworkTests, эпоха 06 |
| 3. API-ключи | Save/Clear меняют только выбранный account; источник виден; Cancel сохраняет всё | Env override, Keychain failure, формат, missing credential после Clear; никаких заявлений о server validation | Эпоха 05 |
| 4. Основной язык | Выбранный язык один, исключён из дополнительных; uk нормализован; следующий session snapshot согласован | Смена во время подготовки/записи, persistence failure, pending backend не теряется | LanguageSettings tests, эпохи 02/07 |
| 4. Дополнительные / autodetect | Включение/выключение сохраняется; allowedLanguages соответствуют reducer; пустой набор трактуется по прежнему контракту | Дубликаты, основной в extras, переход detect on/off; UI restart wording относится только к интерфейсу | Core/UI/App tests |
| 5. AI-редактор | Disabled / Local / Gemini имеют явные действия и active/pending states | Повтор selected не выключает, missing key/model, выключение во время file/recording, retry не ломает STT | Эпохи 02/05/08 |
| 6. Удалить локальные модели | Свободная выбранная модель удаляется, размер/наличие обновляются | Active/preparing/retired/transfer/validation защищены; состояние изменилось после открытия диалога; disk failure | Эпоха 06 |
| 7. Словарь — термины | Add/edit/delete/reactivate сохраняются и влияют на prompt; фильтр языка сохраняется | Refresh/новая фраза не стирают draft; изменение/удаление той же строки извне показывает conflict; ошибка save | Эпохи 03–04 |
| 7. Словарь — режим | Disabled/Suggest/Auto сохраняются и выполняют именно свой режим | Disabled подавляет on-demand results; Auto может сразу добавить термины и не создавать pending panel; уведомление это объясняет | CNSDictionary tests, эпоха 04 |
| 7. Словарь — предложения | Review/Accept/Reject/Accept all сохраняют selection и один undo snapshot на язык | Пустой список, stale analysis, языковая смена, partial persistence failure не оставляет половину batch | Эпохи 03–04 |
| 7. Словарь — prompt/import/undo | Редактирование prompt/import синхронизированы; undo выбирает язык и восстанавливает также пустое состояние | Не тот primary language, первый add/import, пакет, metrics tick, внешняя правка, write rollback | Эпоха 04 |
| 7. Словарь — замены | Manual/approved pairs влияют на replacement; rejected tombstones сохраняются | Редактирование двух строк и сохранение одной, rebuild corrections, low-count/stale observations не применяются напрямую | Эпоха 03, CNSDictionary tests |
| 7. Словарь — статистика | Loading → фактические metrics; history открывается; timestamp/ack согласованы | Ошибка не даёт fake zeros; старый task не перезаписывает новый; отмена не обрывает уже принятое persistence acknowledgement | Эпоха 03 |
| 8. Последние фразы | Общий count, первые 5, «Показать ещё» добавляет 5, выбирается полный текст | 0/1/5/6 записей, длинный title, кириллица/emoji/newlines, refresh count; clipboard изменяется только по выбору | History/Menu tests и ручной smoke |
| 9. Распознать аудиофайл | Picker/drop согласованы с MediaFormatCapabilities; STT/refinement исходы отдельны, текст редактируется | Unsupported Ogg/Opus не рекламируются; content magic; partial cancel, editor timeout/disabled, reopen, Save failure | Эпоха 08 и текущие media/session suites |
| 10. Мастер разрешений | Ручной вызов всегда показывает результат; автоматический не мешает при all granted | Повторный вход, timeout, skipped step; setup flags и язык не сбрасываются | Эпоха 02 |
| 11. Проверить обновления | Check single-flight; отдельный progress; Later → install staged; настоящий error state | Model download одновременно, cancel/retry/late callback, missing helper, отказ shutdown, wrong ack/rollback | Эпоха 09 |
| 12. О Click-n-speak | Окно показывает название, версию/build и icon из собранного bundle | Dev fallback не выдаёт неверную release version; метаданные соответствуют Info.plist | AppResourcesTests и bundle smoke |
| 13. Запускать при входе | Галочка следует фактическому SMAppService.status после действия | requiresApproval/notFound/register failure/unregister failure; persisted config не является единственным источником истины | AutostartTests, MenuStateTests |
| 14. Дополнительно — config/log | Открывается правильный файл тестового профиля; не происходит неявного overwrite | Отсутствующий файл, отказ доступа, неправильный JSON; config bytes сохранены | Core/UI tests, эпоха 07 |
| 14. Перечитать конфигурацию | Валидация прежде adoption; четыре chunking settings действуют со следующей записи | Запись уже идёт, append, runtime prepare, invalid thresholds, prompt repair failure; нет частичного adoption | Эпоха 07 |
| 15. Перезапустить | Один новый процесс после полного выхода текущего, профиль и lock согласованы | Двойной click, missing helper, failed drain, launch failure, поздний обычный Quit после отмены restart | Эпоха 01 |
| 16. Завершить | Остановлены producer tasks, drained persistence/runtime/telemetry, lock освобождён последним | Файловая работа/injection/confirmation в процессе, timeout удерживает lock; нет restart/update side effect | Session/App tests, эпохи 01/09 |

- [ ] Сверить фактическое дерево меню с этой матрицей. Если текущая ревизия добавила вложенную команду, добавить строку и пройти её; не ограничиваться историческим снимком.
- [ ] Пройти все шесть локалей на отсутствие missing keys, двойных стрелок и пустых labels. Ручной визуальный smoke минимум ru/en; остальные — ресурсы и структура меню.

## Шаг 3 — взаимодействия нескольких пунктов

Обязательные последовательности, потому что независимый click-test не проверяет владельцев общего состояния:

- [ ] Открыть Terms → изменить две строки → новая запись добавляет историю → сохранить одну строку. Второй draft не исчезает; undo возвращает правильную языковую операцию.
- [ ] Начать file job с Gemini editor → выбрать Disabled → дождаться job. Текущий job сохраняет captured runtime; следующая работа показывает новое состояние.
- [ ] Выбрать локальную модель → при suspended prepare открыть удаление → попытка отклонена → завершить prepare. Runtime не остаётся наполовину переключённым.
- [ ] Отозвать выбранный cloud key → выполнить Retry/Keep previous → новый job не использует отозванный client. Старый начатый snapshot завершает собственную работу.
- [ ] Запись активна → reload аудиопорогов и языка → завершить/append. Старые samples обработаны прежними настройками; новая generation получает согласованный config.
- [ ] Загружать модель и update одновременно → отменить один → второй завершить. Панели, tasks, leases и cleanup относятся к правильным UUID.
- [ ] Restart или install во время confirmation persistence → drain ждёт запись; отказ отменяет соответствующий handoff; обычный Quit позднее не запускает отложенную операцию.

## Шаг 4 — автоматические и bundle gates

Полный fast gate один раз после завершения целевых исправлений:

```bash
source venv/bin/activate
bash scripts/swift_verify.sh
```

Он включает восемь пакетов и ClickNSpeak. Суммировать XCTest и Swift Testing; не считать отсутствие выбранных real-model suites их успешным прохождением.

Для согласованного bundle smoke после сохранения пользовательской работы:

```bash
source venv/bin/activate
CNS_RESET_TCC_AFTER_BUILD=0 bash scripts/swift_build_app.sh release
bash scripts/swift_verify_bundle.sh
```

- [ ] Проверить наличие/подпись/архитектуру CNSRestartHelper и CNSUpdateHelper, locale/resources и CNSGitRevision. Bundle должен соответствовать кандидату, по которому выполнены tests; dirty build явно обозначать как таковой.
- [ ] Build не устанавливает приложение автоматически. Ручной запуск и проверки TCC/autostart/update проводить в согласованном тестовом окружении; не сбрасывать пользовательские разрешения и не заменять рабочую app без отдельного запроса.
- [ ] Real-model suites нужны, если изменён путь inference либо fake-проверки оставляют конкретный вопрос о native shutdown/lease. Использовать уже подготовленные pinned model paths и явные opt-in команды проекта; не скачивать гигабайты и не вызывать cloud API ради галочки меню.
- [ ] `scripts/swift_acceptance.sh` — отдельная release acceptance с clean commit и готовыми app/DMG/manifest/evidence. `--validate-only` не является прохождением живой приёмки. Не объявлять release-ready по одному fast gate.

## Критерий завершения всей серии

- [ ] Все 16 верхних пунктов и фактические submenu имеют пройденные строки матрицы.
- [ ] Все дефекты из эпох 01–09 имеют наблюдаемую регрессию и проверенное исправление; нет тихих failure/false success в затронутых путях.
- [ ] Полный fast gate зелёный на финальном коде; bundle verification зелёный на соответствующей сборке.
- [ ] Ручные сценарии, которые действительно выполнены, отделены от автоматических и от невыполненных. Если доступ к live TCC/реальному процессу не был предоставлен, общую приёмку не объявлять полностью завершённой.
- [ ] Нет удаления пользовательских моделей, изменения ключей или обновления установленной app как побочного эффекта тестов.
- [ ] Изменения эпох закоммичены избирательно, AGENTS.md соответствует финальным контрактам, несвязанные пользовательские изменения сохранены.
- [ ] В чате дать краткий итог по-русски: исправленные поведения, проверенные команды, фактические ограничения и оставшиеся конкретные пункты. Отдельный summary-файл не создавать.

Возможный последний коммит для добавленных сквозных регрессий: `test: cover complete menu workflows and lifecycle boundaries`. Если новые тесты не потребовались, пустой коммит не делать.
