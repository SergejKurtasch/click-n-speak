# Эпоха 06 — Диагностика, доказательства паритета и итоговая приёмка

> Для исполнителя: использовать `executing-plans`; сначала подтвердить gates эпох 01–05. Не считать manual/model skips завершёнными задачами.

**Цель:** закрыть R15, устранить противоречия статусов миграции и вынести проверяемое решение о стабильности конкретной сборки.

**Архитектура:** runtime events отправляются в единый content-free sink с identity запуска. Acceptance связывает каждый результат с commit, binary/DMG hash и условиями испытания; итог строится из реальных результатов.

**Стек:** CNSCore/ClickNSpeak, Python из `venv`, существующие acceptance/soak scripts и release tooling.

**Спецификация:** [00-REVIEW-AND-PLAN.md](00-REVIEW-AND-PLAN.md), R15, все незакрытые external проверки прежних эпох. Глобальные ограничения обязательны.

## Задача 1 — Runtime events в штатном логе и корректные метрики

**Файлы:** `Packages/CNSCore/Sources/CNSCore/RuntimeTelemetry.swift`, `FileLogger.swift`, `ClickNSpeak/Sources/ClickNSpeak/AppDelegate.swift`, `scripts/analyze_swift_soak.py`, `scripts/compare_swift_parity_metrics.py`; tests `RuntimeTelemetryTests.swift`, создать `tests/parity/test_swift_soak_metrics.py`.

**Интерфейсы:** configurable telemetry sink с method `emit(event:fields:)`; identity содержит `run_id: UUID`, `session_id: Int`, для chunk events — `chunk_index`. App composition root устанавливает sink один раз до первого runtime event. Test sink хранит JSON в памяти/временном файле; production sink направляет строку `runtime_event ...` в FileLogger. Shutdown drain включает telemetry writes.

- [ ] Red integration: SessionController выполняет synthetic recording, а тест читает **файл штатного sink**, не захваченный stdout. В нём есть session_start/chunk_processed/popup/session_end. Проверить отсутствие transcript/prompt/clipboard/key и selected term как в JSON, так и в обычных diagnostic logs.
- [ ] Перестать логировать сам термин в `handleAddToDictionary`; оставить language/source/length. Проверять вложенные поля payload либо использовать закрытые typed event schemas вместо только substring-фильтра ключей.
- [ ] Добавить Python fixtures: два запуска, каждый с session_id=1; один local editor 100 ms и один Gemini editor 10 s; partial chunk failure; duplicated outcome; noSpeech session. Ожидаемые ключевые проверки:

```python
def test_relaunch_sessions_are_distinct() -> None:
    events = [
        {"event": "session_start", "run_id": "run-a", "session_id": 1, "monotonic": 0.0},
        {"event": "session_start", "run_id": "run-b", "session_id": 1, "monotonic": 10.0},
    ]
    assert summarize(events)["session_count"] == 2


def test_local_editor_latency_excludes_cloud() -> None:
    events = [
        {"event": "editor_refine", "backend": "local", "duration_ms": 100.0},
        {"event": "editor_refine", "backend": "gemini", "duration_ms": 10000.0},
    ]
    assert summarize(events)["local_editor_p95_seconds"] == 0.1
```

Импорт `summarize` оформить тем же способом, которым tests/parity импортируют соседние scripts; не добавлять абсолютный sys.path пользователя.

- [ ] Считать sessions по `(run_id, session_id)`; дополнительно проверять starts/outcomes/incomplete flags/chunk sequence, а не только количество start IDs. Длительность soak определять с учётом реальных run boundaries и wall-clock metadata; не складывать несовместимые monotonic эпохи после reboot.
- [ ] Local editor p95 фильтровать по backend; no local events → metric отсутствует, а не ноль и не Gemini percentile. Peak/growth RSS считать по сопоставимым workload и запуску, не как `last minus first` произвольно объединённого лога. Callback metric обозначить как распределение session maxima, если события не содержат histogram настоящих callback durations.
- [ ] Green: `source venv/bin/activate && swift test --disable-index-store --package-path Packages/CNSCore`; `source venv/bin/activate && python -m pytest -q tests/parity`. Коммит `fix: persist runtime telemetry and correct soak metrics`.

## Задача 2 — Acceptance, привязанная к проверенному кандидату

**Файлы:** `scripts/swift_acceptance.py`, `tests/parity/test_parity_contract.py`, `tests/parity/manual_evidence.template.json`, `tests/parity/swift_parity_scenarios.json`, `tests/parity/fixtures/config_schemas.json`, release templates/runbooks.

**Интерфейс:** evidence schema v2 включает candidate git revision, app/DMG SHA-256, version, model revisions, OS/hardware, completed_at, operator, artifact path + checksum. Автоматический result содержит те же candidate identifiers. Gate execution сохраняет отдельный log/artifact, а не только имя `swift_fast`.

- [ ] Red tests: passed evidence на отсутствующий путь отклоняется; mismatch commit/hash отклоняется; старый candidate_version не подходит; corrupt artifact checksum отклоняется; одинаковый valid evidence подходит; manual skipped не становится passed.
- [ ] Автоматический build gate явно сохраняет TCC:

```python
environment = os.environ.copy()
environment["CNS_PRODUCTION_RELEASE"] = "1" if args.production else "0"
environment["CNS_RESET_TCC_AFTER_BUILD"] = "0"
```

- [ ] Проверить mock subprocess invocation: переменная передаётся именно build gate. Не менять default dev-build policy в `swift_build_app.sh` без отдельного решения. Acceptance не должен пересобирать и заменять установленный production target.
- [ ] Добавить regression scenario IDs по R01–R15. Для каждого автоматического сценария перечислить тесты/fixtures, а не присваивать успех всем сценариям от факта одной общей компиляции. Сохранить общий fast gate как обязательный prerequisite.
- [ ] `audit_data_copy` должен проверять реальные имена dataset копии (`clicknspeak_dataset.jsonl` для dev и согласованное имя backup manifest), не только `dataset.jsonl`. Пустой каталог не считается успешной проверкой полноценного набора пользовательских данных. Добавить v10 approval/rejection fixture и Python↔Swift roundtrip.
- [ ] Проверять model gates отдельно от агрегированного fast exit: failure модели не должен выглядеть как «job skipped». Missing prerequisite, failed test и passed evidence — разные статусы.
- [ ] Green Python parity и `source venv/bin/activate && bash scripts/swift_acceptance.sh --validate-only`. Коммит `test: bind acceptance evidence to candidate artifacts`.

## Задача 3 — Полная проверка исправленной сборки

**Файлы:** использовать существующие `scripts/swift_verify.sh`, `swift_acceptance.sh`, `analyze_swift_soak.py`, `compare_swift_parity_metrics.py`, `docs/releases/SWIFT_SOAK_PROTOCOL.md`; обновить `docs/swift_implementation_epochs/IMPLEMENTATION_STATUS.md`, `docs/releases/SWIFT_1.1.0_RC_GO_NO_GO.md` либо создать report для фактической новой версии, AGENTS.md только при изменении архитектуры.

**Вход:** прошедшие regression tests всех эпох; собранный кандидат с зафиксированным commit/hash. **Выход:** GO только для проверенного hash либо NO-GO с точным перечнем незакрытых gates.

- [ ] Полный deterministic gate: `source venv/bin/activate && bash scripts/swift_verify.sh` и `source venv/bin/activate && python -m pytest -q tests/parity`. Исходные 11 audit probes должны быть перенесены в постоянные tests и проверять исправленное ожидаемое поведение.
- [ ] Выполнить real Whisper gate на существующем sanitized golden corpus с явными `CNS_RUN_MODEL_TESTS=1`, `CNS_WHISPER_MODEL` и golden dir. Выполнить реальный Qwen gate с `CNS_RUN_EDITOR_MODEL_TESTS=1`, `CNS_QWEN_MODEL_DIR`; соблюдать предусмотренную scripts двухфазную установку metallib. Не переиспользовать прошлые цифры bake-off как новые результаты.
- [ ] На тестовых данных проверить local/local, local/Gemini, cloud/disabled, cloud/Gemini; offline/429/5xx; смену ключа/модели во время записи; быстрые Enter/hotkey; append с тишиной/ошибкой; длинный файл cancel/reopen; clipboard race и missing target. Живые платные API — только с доступными разрешёнными тестовыми credentials и ограниченным набором фраз.
- [ ] Physical matrix: Microphone/Accessibility clean install, revoke/regrant, restart, sleep/wake, отключение input device; RU/EN/DE, VoiceOver, Retina и два монитора; Launch at Login. App запускается как `.app`, не только raw executable из терминала.
- [ ] Signed distribution matrix эпохи 05: два последовательных signed releases, TCC после update, interrupted download, rollback на failed launch/ack, приложение вне `/Applications`, нехватка диска. Отсутствие signing identity или clean-user среды фиксируется как незакрытый gate.
- [ ] Провести 8-hour/100-session soak по существующему протоколу на исправленном telemetry sink. Сохранить consented sanitized evidence; проверить frozen thresholds, объём памяти, отсутствие incomplete/duplicate records и сохранность словаря после restart.
- [ ] Исправить документы: старые эпохи «code complete» не означают принятый текущий релиз; TCC policy должна совпадать с текущим build script/AGENTS.md; обозначить Swift shipping status и доступный Python rollback artifact без противоречий.
- [ ] Итоговый `swift_acceptance.sh --production --manual-evidence ...` запускается только для согласованных candidate hashes. Коммит документации `docs: record verified Swift release readiness` после фактических результатов.

## Итоговые критерии

- Нет потери исходного config, draft, подтверждённых history/dataset строк и replacement decisions.
- Нет скрытой потери chunk, runtime swap в активной операции и late UI publication после shutdown.
- Fault recovery ограничен по времени и честно отражает невозможность кооперативно прервать зависший native runtime.
- Форматы, API-ключи, language prompt и active descriptors соответствуют реальному поведению.
- Evidence существует, проверено и относится к одному кандидату; каждый critical skip оставляет решение NO-GO.
- Подробный результат сообщается в чат; отдельные произвольные summary-файлы не создавать.
