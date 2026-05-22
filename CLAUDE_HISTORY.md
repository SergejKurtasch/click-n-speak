# Click-n-speak — Development History

Хронология этапов разработки. Не загружается автоматически в контекст — читать явно при необходимости ретроспективы или написании changelog.

---

### ✅ Etap 1 — v2 Config Schema (commit fcd6e10)
- Новые поля: `user_terms`, `auto_terms`, `prompt_snapshots`, `pending_suggestions`,
  `skipped_terms`, `prompt_update_mode`, `auto_prompt_check_interval`, `last_analysis_phrase_count`
- `migrate_config_to_v2()` в `utils.py` — однократная миграция из v1 (парсит `custom_prompts`)
- `build_initial_prompt()` включает термины всех активных языков

### ✅ Etap 2 — Фильтры log_analyzer (anti-error-loop)
- `_TERM_PATTERN` начинается с буквы; `_TERM_STOPLIST` (http/the/and/…)
- `_levenshtein()` с early-exit при расстоянии > 2
- `_collect_english_terms()`: требует ≥2 сессий, нормализует регистр, фильтрует URL-токены
- `_filter_near_duplicates()`: убирает пары с расстоянием ≤1, оставляет более частый
- `_collect_russian_bigrams()`: только биграммы (не триграммы), порог ≥3
- `blacklist` параметр в `get_frequent_terms()`

### ✅ Etap 3 — Авто-анализ каждые N фраз
- `get_prompt_candidates()` в log_analyzer: топ кандидатов из последних 100 фраз, мин. 5 вхождений,
  cooldown 100 фраз для отклонённых, cap 20 на язык, раздельные бакеты EN/RU
- `_apply_candidates_to_auto_terms()` helper в app.py; `_maybe_trigger_prompt_analysis()` +
  `_run_prompt_analysis()` в `SVoiceRecApp`; триггер после каждого `append_phrase`
- `SuggestionsPanel` (`src/suggestions_panel.py`): NSWindow, чекбоксы + badge-счётчик,
  пагинация "Показать ещё 10", 3 кнопки (Авто / Позже / Добавить)
- `menu_bar.py`: `_suggest_item` с badge, `_check_pending_suggestions_on_startup()`,
  `_show_suggestions_alert()` (NSAlert, 3 кнопки), `_open_suggestions_panel()`,
  `update_suggest_menu_badge()`

---

### ✅ Etap 4 — UI управления режимом + просмотр auto_terms
- "Update from History" убран из меню (метод оставлен до Etap 6)
- "Auto-update Mode ▶" подменю с 3 checkmark-items: Suggest / Auto / Disabled;
  клик вызывает `_on_set_update_mode(mode)` → меняет `prompt_update_mode`, сохраняет config
- `_update_mode_submenu_state()` синхронизирует checkmarks при init и смене режима
- "Manage Auto Terms…" → NSAlert показывает `auto_terms[lang]` по языкам;
  кнопка "Очистить всё" сбрасывает все `auto_terms[lang] = []` и перестраивает `initial_prompt`
- Файл: `src/menu_bar.py`

---

### ✅ Etap 5 — Редактирование терминов для дополнительных языков
- `_edit_prompt_for_lang(lang)` — общий helper; `edit_initial_prompt` вызывает его для primary
- `_rebuild_edit_terms_item()` — переключает "Edit…" (single) ↔ "Edit Terms ▶" submenu (multi)
  через rumps `.hidden`; вызывается при init, смене primary, добавлении/удалении additional
- `_watch_prompt_file` — итерирует все активные языки, `_prompt_mtimes` dict вместо single-var
- `_apply_primary_language` / `_apply_additional_language` — вызывают `_rebuild_edit_terms_item()`
- Файл: `src/menu_bar.py`

---

### ✅ Etap 6 — Удаление legacy-кода
- `generate_terms_hint_from_history()` удалена из `log_analyzer.py`
- `_migrate_old_prompt()` (stub `pass`) и вызов удалены из `menu_bar.py`
- `update_initial_prompt_from_history()` удалена из `menu_bar.py` (убрана из меню ещё в Etap 4)
- Legacy-ветка `else: legacy = config.get("initial_prompt")` удалена из `build_initial_prompt()` в `utils.py`
- `assets/prompts/` (sample `.txt`) удалены; запись в File paths обновлена на runtime-путь config-dir
- **Файлы:** `src/log_analyzer.py`, `src/menu_bar.py`, `src/utils.py`, `CLAUDE.md`

---

### ✅ Etap 8 — Надёжность и производительность (9 fixes, commit b16618b)
- `hallucination_phrases` используют word-boundary regex — реальные слова больше не дропаются
- `preview_panel`: убран глобальный `NSEvent` монитор; `activateIgnoringOtherApps_` гарантирует фокус
- `save_config_to_disk()`: атомарная запись через tmp + `os.replace` + `fsync`
- `phrase_history._phrase_count` cache — O(1) вместо O(n) скана файла в hotpath инжекции
- `recorder`: `del vad_buffer[:n]` вместо slice-assignment — O(1) в real-time callback
- `build_initial_prompt()`: обрезка по BPE-токенам (лимит 200/224) вместо символов — Whisper больше не переполняется Кириллицей
- `transcribed_parts.append` перенесён после проверки `session_id` — stale-worker не загрязняет новую сессию
- mlx_whisper сигнатура зондируется один раз через `inspect` вместо повторного вызова на `TypeError`
- **Файлы:** `src/app.py`, `src/log_analyzer.py`, `src/phrase_history.py`, `src/preview_panel.py`, `src/recorder.py`, `src/transcriber.py`, `src/utils.py`

---

### ✅ Etap 9 — Дренаж очереди + RMS pre-filter + subword-repeat (commit 92ca336)
- `app.py`: все накопленные non-final чанки обрабатываются при stop — больше не дропаются
- `transcriber.MIN_FINAL_CHUNK_SAMPLES`: 4800 → 8000 (0.3s → 0.5s); `<` → `<=` — граничный артефакт не достигает Whisper
- `_is_audio_silent()`: RMS pre-filter для коротких (<3s) non-final чанков — отклоняет за микросекунды вместо 14-22s
- `_SUBWORD_REPEAT_RE`: стрипает внутрисловные петли (oiseoiseoiseoise...) — то, что `_collapse_consecutive_word_repetition` пропускает
- **Файлы:** `src/app.py`, `src/transcriber.py`

---

### ✅ Etap 10 — Pre-warm skip + AI editor status tracking (commit 46cc6b4)
- `TranscriberProcessWrapper._last_transcribe_returned_at`: `pre_warm()` пропускается если последняя транскрипция < 45s назад — устраняет 15-22s штраф при быстром повторе
- Child `_run_loop`: prewarm проверяет `input_queue.empty()` — реальный чанк не блокируется за прогревом
- `_REFINE_TIMEOUT_SECONDS`: 15.0 → 8.0 — успешные рефайны занимают 0.7-3s; 8s достаточно
- `AiEditor.last_refine_status`: устанавливается во всех путях (`ok`/`unchanged`/`timeout`/`skipped`/`error`/`disabled`)
- `dataset_logger`: новое поле `ai_status` в JSONL записях
- **Файлы:** `src/ai_editor.py`, `src/app.py`, `src/dataset_logger.py`, `src/transcriber.py`

---

### ✅ Etap 7 — Унификация auto_terms + качество Initial Prompt
- `auto_terms` удалён: принятые кандидаты теперь идут в `user_terms[lang]`; `migrate_config_to_v3()` мёржит существующие `auto_terms`
- `migrate_config_to_v4()` в `utils.py`: чистит артефакт v2-миграции (языковые хинты внутри термина)
- `LANG_DEFAULT_CONTEXT` в `utils.py`: дефолтные стилевые фразы для каждого языка (ru/en/de/es/fr); включаются в `build_initial_prompt()` когда `user_terms` пуст
- `process_chunk()` в `app.py`: скользящее окно — vocab_prompt всегда полный, недавние чанки добавляются целиком (newest-first) в рамках бюджета ~700 символов
- **Файлы:** `src/utils.py`, `src/app.py`, `CLAUDE.md`

---

### ✅ Etap 3b — Ротация словаря: schema v5 + decay (commit a8826de)
- `migrate_config_to_v5()`: `user_terms[lang]` list[str] → list[dict] с полями `term/source/added_at/last_seen/use_count`; старые строки → `source="manual"` (защищены от decay)
- `_term_str()` / `_term_is_active()` — хелперы прозрачного доступа к str и dict записям; используются везде где итерируется `user_terms`
- `build_initial_prompt()`: пропускает `inactive=True`; сортировка manual < correction < auto (use_count desc)
- `update_term_usage(config, phrase)`: обновляет `last_seen`/`use_count`, снимает `inactive`; планируется с потока инжекции на главный поток (`_apply_term_usage_on_main`); dirty-flag `_config_usage_dirty`
- `apply_decay(config, max_age_days)`: помечает устаревшие auto/correction термины inactive; manual — вечны
- `run_decay_if_due()` + `_decay_tick(@rumps.timer(3600))`: раз в 24 h
- `_apply_candidates_to_user_terms()`: вставляет dict-записи вместо строк (с source/added_at/last_seen)
- `_watch_prompt_file()`: при редактировании .txt сопоставляет строки с существующими dict-объектами (метаданные сохраняются); новые строки → `source="manual"`
- `_revert_for_lang()`: нормализует list[str] снэпшоты в dict при откате
- «Manage Terms…» в меню: статистика + «Удалить неактивные»
- **Файлы:** `src/utils.py`, `src/app.py`, `src/menu_bar.py`, `tests/test_decay.py` (12 тестов)

---

### ✅ Etap 11 — Correction-driven candidates from popup edits
- Добавлен `src/correction_analyzer.py`: инкрементально читает `~/.clicknspeak_dataset.jsonl`, строит `corrections.json` и извлекает `inserted_terms`/`replacement_pairs` через token-level diff (`ai_edited|raw_whisper` vs `user_final`)
- `corrections.json` пишется атомарно (tmp + `os.replace` + `fsync`), включает `last_processed_ts` и `processed_rows` для cheap incremental updates
- `_run_prompt_analysis()` в `app.py` теперь мерджит два источника кандидатов: correction + frequency; приоритет correction задаётся скором `correction_count * 10 + frequency_count`, поле `source` = `correction|frequency|both`
- `_maybe_trigger_prompt_analysis()` fast-path: сильный correction-сигнал в последних подтверждениях + рост `processed_rows` относительно `_last_fast_path_processed_rows` → анализ сразу; тот же `corrections_index` передаётся в `_run_prompt_analysis` — без повторного `update_corrections_index()`; порог `min_correction_count` для correction-кандидатов задаётся по скрипту (как у frequency), не фиксированная двойка
- Экспортированы публичные алиасы `TERM_STOPLIST`, `RUS_FUNCTION_WORDS`, `TERM_PATTERN` в `log_analyzer.py` для единых фильтров шума
- **Файлы:** `src/correction_analyzer.py`, `src/app.py`, `src/log_analyzer.py`, `src/utils.py`, `tests/test_correction_analyzer.py`, `CLAUDE.md`

---

### ✅ Etap 12 — Language-agnostic analyzer thresholds (script buckets)
- Анализаторы используют script-based buckets **`latin`** / **`cyrillic`** (не путать с ISO-кодами); legacy `corrections.json` v1 (`en`/`ru`) мигрирует в v2 при загрузке
- Пороги частоты: `auto_prompt_check_min_count_primary` (default 10, primary script — stricter) vs `auto_prompt_check_min_count_additional` (default 5, additional script — more permissive), плюс `auto_prompt_lookback` 300, интервал проверки **20** фраз, on-demand lookback **1000**, cooldown **150**, cap **15** кандидатов на bucket при merge
- `_collect_english_terms`: опциональный bypass фильтра «≥2 сессий» для латинских токенов, если переданный `term_has_correction_signal(lower)` истинен (в `app.py` это совпадение с любым ключом в `inserted_terms` индекса corrections)
- `get_language_script()`, `target_lang_for_script_bucket()`, `existing_terms_union_for_script()`, `skipped_phrases_merge_for_script()` в `utils.py`
- **Файлы:** `src/correction_analyzer.py`, `src/log_analyzer.py`, `src/app.py`, `src/utils.py`, `tests/test_log_analyzer.py`, `tests/test_correction_analyzer.py`, `CLAUDE.md`

---

### ✅ Etap 13 — Metrics UI, vocab for API editors, Add to Dictionary, threading fixes
- `src/metrics.py` + `metrics_history.jsonl`: `compute_metrics`, тренды, acceptance, prompt token budget; `append_metrics_history` / ротация; меню **Statistics…** (`get_metrics_snapshot(force=True)`), опциональное открытие файла истории; `scripts/print_metrics.py` — JSON в stdout для отладки
- `run_daily_maintenance_if_due()` — decay + фоновый `run_metrics_if_due`; деградация edit-score → редкое уведомление (`notify_on_metrics`, throttle 30 дней)
- `src/vocab_provider.py` — `collect_known_terms` / `collect_misrecognitions` / `add_term_to_user_terms`; `ExternalApiEditor` в `ai_editor.py` + расширенные system prompts для Gemini (realtime + file)
- Попап: `DictionaryAwareTextView`, тосты по строке заголовка; `_apply_candidates` для auto-терминов берёт `frequency_count` в `use_count`
- Главный поток: `update_term_usage` через очередь; сброс `_config_usage_dirty` каждые 60 s и перед рестартом транскрайбера; коммиты авто-анализа через `_main_thread_queue`; `write_text_atomic` для `.txt` терминов
- **Файлы:** `src/metrics.py`, `src/vocab_provider.py`, `src/ai_editor.py`, `src/app.py`, `src/menu_bar.py`, `src/preview_panel.py`, `src/suggestions_panel.py`, `src/utils.py`, `src/correction_analyzer.py`, `scripts/print_metrics.py`, тесты `test_metrics.py`, `test_vocab_provider.py`

---

### ✅ Etap 14 — Canonical term identity across analyzers/merge/metrics
- Добавлены `canonicalize_term()` и `canonical_term_key()` в `utils.py` для единой identity-модели термов
- Boundary punctuation схлопывается (`GitHub.` == `GitHub`), но внутренние символы терма сохраняются (`C++`, `C#`, `node.js`, `v2.1`, `foo_bar`, `x-y`)
- Сохранены семантически значимые leading-префиксы (`.NET`, `@mention`) при канонизации display-формы
- Ключи dedupe/merge/cooldown переведены на canonical-key в `app.py` и `menu_bar.py`; канонизация внедрена до агрегации в `log_analyzer.py` и `correction_analyzer.py`
- `vocab_provider.py` использует canonical-key для add/dedupe; `metrics.py` использует canonical-key на dictionary side для hit-rate
- Покрытие: `tests/test_term_normalization.py` + апдейты в `tests/test_log_analyzer.py`, `tests/test_correction_analyzer.py`, `tests/test_vocab_provider.py`, `tests/test_metrics.py`

---

### ✅ Etap 16 — Stability: PortAudio auto-restart, native memory pressure, SuggestionsPanel height

- **PortAudio stream-close hang recovery** (`recorder.py`): `start()` detects stuck `_close_thread` after 5 s timeout → calls `_on_fatal_error` callback → `SVoiceRecApp._on_recorder_fatal_error()` posts `restart_application()` to `_main_thread_queue`; `_device_id_from_config` flag enables per-start device re-scan for Bluetooth/USB reconnections
- **Native macOS memory pressure** (`app.py`): `_is_memory_pressure_high()` reads `kern.memorystatus_vm_pressure_level` via sysctl (Critical=4 only, not psutil percent); sysctl runs in a daemon thread (`_refresh_memory_pressure_cache` / `_memory_pressure_refresh_thread`) so chunk_worker is never blocked; cache TTL 5 s; memory-pressure notifications throttled to once per 30 min (`_last_memory_pressure_notification_ts`)
- **SuggestionsPanel window height** (`suggestions_panel.py`): height formula corrected to `min(max(desired_h, fixed_h + _MIN_LIST_H), max_h)` — window always tall enough for minimum list area even with one term
- **Файлы:** `src/app.py`, `src/recorder.py`, `src/suggestions_panel.py`, `tests/test_stability_fixes.py`

---

### ✅ Etap 15 — Direct replacement pairs pipeline + ReplacementsPanel
- `src/replacements_panel.py` (новый): NSWindow для редактирования ручных пар замены (from→to); auto-пары из corrections index; enable/disable per-row
- `src/vocab_provider.py`: `normalize_replacement_side`, `manual_replacement_tuples`, `list_replacement_rows_for_ui`, `apply_replacements`, `apply_replacements_sequential`, `collect_replacement_pairs_for_apply`, `_merge_misrecognition_pairs`, `_compile_replacement_pattern`
- `src/app.py`: `_apply_ai_and_replacements_for_buffered` — новый worker-метод; `_should_apply_direct_replacements_after_refine` — пропускает замену если AI уже имел vocab hints и вернул `ok`/`unchanged`; `_finalize_buffered_transcription_on_main`
- `src/utils.py`: `migrate_config_to_v6()` — добавляет `manual_replacements: []`; schema_version → **6**
- `src/menu_bar.py`: `_on_edit_replacements` → открывает `ReplacementsPanel`; `_PromptTermsPanelDelegate` + `_open_prompt_terms_editor` — inline NSPanel для редактирования терминов
- **Файлы:** `src/replacements_panel.py`, `src/vocab_provider.py`, `src/app.py`, `src/utils.py`, `src/menu_bar.py`, `src/correction_analyzer.py`, `src/recorder.py`, `src/ai_editor.py`, `scripts/clean_corrections.py`, тесты `test_vocab_provider.py`, `test_chunk_drain_on_stop.py`, `test_suggestions_startup.py`


---

### ✅ Etap 17 — Initial prompt quality: _build_chunk_context, vocab cleanup

- **`_build_chunk_context()` в `src/app.py`** (новая функция): заменяет inline-логику в `process_chunk`; гарантирует `≤ 220 BPE токенов` И `≤ 700 символов`; recent_text ≤ 50% char budget, ≤ 3 чанков; vocab сохраняется целиком
- **`_WHISPER_PROMPT_TOKEN_LIMIT=220`, `_RECENT_CHARS_RATIO=0.5`, `_MAX_RECENT_CHUNKS=3`** — новые модульные константы
- **Ручная чистка `config.json`**: удалены мусорные RU-глаголы (напиши, проверь, …) и generic EN-слова (API, code, Data, …); оставлено 19 нишевых терминов (Claude, Whisper, Gemini, TF-IDF, XGBoost, MCP, Qwen, ADK, LLM, …)
- **`tests/test_app_context.py`** (новый): 15 тестов на token/char гарантии, chunk-cap, 50%-бюджет, edge cases
- **Файлы:** `src/app.py`, `tests/test_app_context.py`, `config.json`

---

### ✅ Etap 18 — Fast-decay for zero-use auto terms

- **`apply_fast_decay(config)` в `src/utils.py`** (новая функция): деактивирует auto-термины с `use_count=0` старше 14 дней (`_FAST_DECAY_AGE_DAYS`); correction и manual не трогает; idempotent
- **`apply_decay`** теперь вызывает `apply_fast_decay` как первый (fast) проход перед стандартным 60-дневным (slow) проходом; возвращает суммарное число
- **Тесты** (`tests/test_decay.py`): 9 новых тестов — source guards (manual/correction пропускаются), age threshold (14d граница), edge cases (missing added_at, missing use_count, idempotency), комбинированный fast+slow сценарий
- **Файлы:** `src/utils.py`, `tests/test_decay.py`

---

### ✅ Etap 19 — A2: Per-term hit tracking in dataset_logger

- **`_find_terms(text, terms)` в `src/dataset_logger.py`** (новая функция): case-insensitive поиск активных терминов словаря в тексте; обрабатывает `C++`, `.NET` и прочие нестандартные токены через `_WORD_RE`
- **`append_to_dataset`** расширен keyword-only аргументами: `lang`, `user_terms_for_lang`, `prompt_hash`; каждая запись теперь содержит `vocab_terms_in_raw`, `vocab_terms_in_final`, `lang`, `prompt_hash`
- **`src/transcriber.py`**: `WhisperTranscriber._last_detected_language` — захватывает язык после `_call_mlx_transcribe` (включая retry-путь); `_run_loop` пробрасывает `"language"` в output_queue; `TranscriberProcessWrapper.last_detected_language` — публичный атрибут, доступный после каждого `transcribe()`
- **`src/app.py`**: `self._detected_transcription_lang` — заполняется при финальном чанке из `transcriber.last_detected_language`; call-site `append_to_dataset` передаёт detected lang, активные термины и prompt_hash
- **`scripts/term_effectiveness.py`** (новый): отчёт `in_raw / in_final / help_ratio` по всем терминам из датасета
- **`tests/test_dataset_logger.py`** (новый): 10 тестов — case-insensitive matching, `C++`, пустые аргументы, кириллица, record shape, backward compat
- **Файлы:** `src/dataset_logger.py`, `src/transcriber.py`, `src/app.py`, `scripts/term_effectiveness.py`, `tests/test_dataset_logger.py`

---

### ✅ Etap 20 — C1: Script-aware ⌘D routing + multi-word dictionary phrases

- **`detect_term_script(term)` в `src/utils.py`** (новая функция): считает Latin vs Cyrillic символы в термине; возвращает `'latin'`, `'cyrillic'` или `None` (tied / no alpha). Заменяет грубый `any(0x0400 <= ord(ch) <= 0x052F)` в `_on_add_to_dictionary`
- **`src/app.py:_on_add_to_dictionary`**: использует `detect_term_script()` для точного определения целевого языка; при `None` (смешанный скрипт) — fallback на primary lang вместо всегда-latin
- **`src/preview_panel.py:_is_valid_term`**: убран `if " " in candidate: return False`; добавлен лимит `_MAX_TERM_WORDS=4`, `_MAX_TERM_CHARS=60`; валидация переработана per-word; TERM_STOPLIST проверяется только для однословных кандидатов — выделение нескольких слов теперь работает
- **`tests/test_vocab_dictionary.py`** (новый): 29 тестов — `detect_term_script` (latin/cyrillic/tied/None/mixed-script phrase), script→lang routing, `_is_valid_term` (single-word regression + multi-word), `add_term_to_user_terms` с фразами
- **Файлы:** `src/utils.py`, `src/app.py`, `src/preview_panel.py`, `tests/test_vocab_dictionary.py`

---

### ✅ Etap 21 — B2 + B3 + A3: SuggestionsPanel help text, ⌘D lang toast, failed_pairs in Statistics

- **B2 — SuggestionsPanel explanatory text** (`src/suggestions_panel.py`): добавлена help-строка под заголовком («Добавленные слова помогут Whisper лучше их узнавать. Удалить можно позже в Manage Terms.»); `_HELP_H=32`, `_LABEL_H` уменьшен до 22; `fixed_h` и y-координаты пересчитаны; label с `setWraps_(True)` и `secondary=True`
- **B3 — Toast с языком после ⌘D** (`src/utils.py`, `src/app.py`, `src/preview_panel.py`): `LANG_NAMES` — новый публичный dict `{lang_code: display_name}`; `_on_add_to_dictionary` теперь возвращает `str` (formatted toast: `„term" → Язык`) вместо `bool`; `_add_selection_to_dictionary` использует returned string если это `str`, иначе fallback на шаблон
- **A3 — failed_pairs в Statistics** (`src/menu_bar.py`): `_show_statistics_alert` читает `snapshot["failed_pairs"]`; показывает top-5 пар «Whisper упорно не узнаёт»; `✓` если пара уже в `manual_replacements`; добавляет кнопку «Open Replacements…» (только когда есть пары) → вызывает `_on_edit_replacements`
- **Файлы:** `src/utils.py`, `src/app.py`, `src/preview_panel.py`, `src/menu_bar.py`, `src/suggestions_panel.py`


### ✅ Etap 22 — B1 + B5 + B4: Grouped suggestions, statistics effectiveness card, TermsPanel

**B1 — SuggestionsPanel language grouping** (`src/suggestions_panel.py`):
- Section headers `── Русский (8) ──` when candidates span >1 language
- Per-section "выбрать" / "снять" buttons (NSButton inside doc view, tag = lang_idx)
- `_get_ordered_langs()` — sorts langs by total candidate count desc
- `_do_select_section(idx)` / `_do_deselect_section(idx)` — toggle checkboxes for one section
- `_ordered_langs` stored on panel for delegate lookup; `selectSection_` / `deselectSection_` added to `_PanelDelegate`
- `desired_h` accounts for header rows; badge shows only count (lang redundant when sectioned)
- Single-language: no headers, behaviour unchanged

**B5 — Statistics effectiveness card** (`src/metrics.py`, `src/menu_bar.py`):
- `top_helping_terms(dataset_path, limit=5)` — reads last 1000 dataset records; computes recognition_rate = min(1.0, n_raw / n_final); returns [] when no records with vocab tracking
- `dead_weight_terms(config, days=30)` — active terms with use_count=0 added >N days ago; skips inactive; sorted by age desc
- `_show_statistics_alert` extended: "Whisper узнаёт без правок" section (or "недостаточно данных"); "Мёртвый груз" section; button "Удалить мёртвый груз (N)" when dead>0
- `_delete_dead_weight_terms(dead)` — bulk delete, rebuild prompt, sync .txt, notify
- Button routing via `button_actions` list (index-based) so OK/history/delete_dead/replacements don't hard-code result codes

**B4 — TermsPanel** (`src/terms_panel.py` new, `src/menu_bar.py`):
- `TermsPanel` — NSWindow 600×480 with NSSegmentedControl (lang filter) + NSScrollView/NSTableView + stats label + delete/close buttons
- `_TermsDataSource(NSObject)` — cell-based datasource, columns: term/lang/source/use_count/last_seen/status
- `_TermsPanelDelegate(NSObject)` — handles deleteSelected_/closePanel_/langChanged_/tableViewSelectionDidChange_
- Delete: NSAlert confirmation → removes from `_all_rows` → calls `on_delete` callback → menu_bar removes from config + rebuilds prompt + syncs .txt
- `_on_manage_terms` in `ClickNSpeakApp` replaced: opens `TermsPanel` instead of text editor
- `self._terms_panel` (lazy init) added to `ClickNSpeakApp.__init__`
- **Файлы:** `src/terms_panel.py` (new), `src/suggestions_panel.py`, `src/metrics.py`, `src/menu_bar.py`, `tests/test_metrics.py`
