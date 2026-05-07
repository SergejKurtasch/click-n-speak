# Этап 1 — Diff-сигнал из правок пользователя

## Цель

Превратить уже собираемый, но неиспользуемый dataset (`~/.clicknspeak_dataset.jsonl`) в основной источник кандидатов для словаря. Слово, которое пользователь руками вписал в попап после AI-редактора, — самый сильный сигнал «этого слова не было в распознавании, добавь его в initial_prompt».

После этапа: новый английский термин будет попадать в `pending_suggestions` после **2–3 ручных правок**, а не после 10 совпадений в истории.

---

## Что уже есть

- `src/dataset_logger.py:append_to_dataset()` — пишет JSONL с полями:
  ```json
  {"raw_whisper": "...", "ai_edited": "..." | null, "user_final": "...", "ai_status": "ok|skipped|...", "timestamp": "..."}
  ```
- `src/app.py:464` — вызывается на каждом подтверждённом попапе.
- `~/.clicknspeak_dataset.jsonl` — append-only, ничем не читается.

## Что НЕ работает

- `src/log_analyzer.py:get_prompt_candidates()` смотрит только `phrase_history.txt` — а это **финальный текст**, в нём правок уже нет, и слова вроде «GitHub» не появятся, если Whisper их распознал как «гитхаб».
- min_count=10, требование ≥2 сессий — рассчитано на «прорезание шума частотой», для diff-сигнала это абсурдно высокий порог.

---

## Архитектура решения

### Новый модуль `src/correction_analyzer.py`

Отвечает за: чтение dataset.jsonl → токенизация и diff триплетов → агрегированная статистика → выдача кандидатов.

#### Публичный API

```python
def update_corrections_index(
    dataset_path: Path = _DEFAULT_DATASET_PATH,
    index_path: Path = _DEFAULT_INDEX_PATH,
) -> dict:
    """Read new dataset records since last run, update corrections.json.

    Returns the updated index dict for callers that want to use it immediately.
    Reads only records whose timestamp > index['last_processed_ts'] — incremental.
    """

def get_correction_candidates(
    index: dict,
    existing_lower_by_lang: dict[str, set[str]],
    skipped_lower_by_lang: dict[str, dict[str, int]],
    current_phrase_count: int,
    min_correction_count: int = 2,
    cooldown_phrases: int = 100,
    max_per_lang: int = 20,
) -> dict[str, list[dict]]:
    """Same shape as get_prompt_candidates, but sourced from corrections index.

    Each candidate dict carries `source: "correction"` and `correction_count: int`
    so the merger downstream can prioritise it over frequency-only candidates.
    """
```

#### Алгоритм diff (token-level)

Для каждой записи `(raw_whisper, ai_edited, user_final)`:

1. **Нормализация**: NFKC, lowercase для сравнения, но сохранить оригинальное написание из `user_final`.
2. **Токенизация**: `re.findall(r"[A-Za-zА-Яа-яЁё][A-Za-zА-Яа-яЁё0-9+#._-]*", text)`.
3. **Сравнение `ai_edited` (если есть, иначе `raw_whisper`) против `user_final`** через `difflib.SequenceMatcher`:
   - `opcodes = matcher.get_opcodes()`
   - `equal` — пропускаем
   - `insert` — токены добавлены пользователем → **inserted_terms**
   - `replace` — токены заменены → пара `(from_tokens, to_tokens)` идёт в **replacement_pairs** (используется в этапе 4 для Gemini); сами `to_tokens` идут также в **inserted_terms**
   - `delete` — игнорируем (пользователь убрал лишнее)
4. **Дополнительно**: те же diff `raw_whisper` vs `user_final` — даёт «misrecognition pairs» даже если AI editor выключен.

#### Фильтры (важно — иначе будет шум):

- Длина токена ≥ 2.
- Не входит в `_TERM_STOPLIST` из `log_analyzer.py` (расшарить через импорт).
- Не входит в `_RUS_FUNCTION_WORDS`.
- Если `inserted` целиком является вырезанным фрагментом из `raw_whisper` — это, скорее всего, восстановление дропнутого Whisper'ом текста, а не «новый термин» (сохраняем, но с весом 0.5).
- Игнорировать только-цифровые токены и токены вида `1`, `2024`, и т. п.
- Длина пары для `replace` ≤ 4 токена с каждой стороны (длинные replace'ы — это не термин, а пересборка фразы).

### Файл `corrections.json`

Путь: `get_corrections_file_path()` (новая функция в `utils.py`):
- dev: `~/Click-n-speak/corrections.json`
- .app: `~/Library/Application Support/Click-n-speak/corrections.json`

Структура:

```json
{
  "schema_version": 1,
  "last_processed_ts": "2026-05-07T14:23:01+00:00",
  "inserted_terms": {
    "en": {
      "PCA":   {"count": 4, "first_seen": "2026-05-01T...", "last_seen": "2026-05-07T..."},
      "MLX":   {"count": 7, "first_seen": "...",            "last_seen": "..."}
    },
    "ru": {}
  },
  "replacement_pairs": {
    "en": [
      {"from": "питон",    "to": "Python", "count": 5, "last_seen": "..."},
      {"from": "гитхаб",   "to": "GitHub", "count": 3, "last_seen": "..."}
    ]
  }
}
```

Запись — атомарная (по образцу `save_config_to_disk` из `utils.py:629`): tmp-сосед + `os.replace` + `fsync`. Использовать готовый хелпер, если он там общий, иначе вынести.

### Определение языка токена

Простое правило:
- Только латиница → bucket `"en"`.
- Содержит кириллицу → bucket `"ru"`.
- Смешанные/прочие — игнор (шум).

Дальше `_run_prompt_analysis` (см. ниже) сам ремапит на активные языки пользователя по тому же принципу, что уже есть в `app.py:611-621`.

### Интеграция с существующим pipeline

Точка входа — `src/app.py:_run_prompt_analysis`. Сейчас там есть один источник — `get_prompt_candidates`. Делаем второй:

```python
# new — поверх существующего get_prompt_candidates
from .correction_analyzer import update_corrections_index, get_correction_candidates

corrections_index = update_corrections_index()  # incremental
correction_cands = get_correction_candidates(
    corrections_index,
    existing_lower_by_lang=existing,
    skipped_lower_by_lang=skipped,
    current_phrase_count=current_count,
    min_correction_count=2,
)

freq_cands = get_prompt_candidates(...)  # как сейчас, но с послабленными порогами в этапе 2

# merge: correction-источник всегда впереди по приоритету
candidates = _merge_candidate_sources(correction_cands, freq_cands)
```

Где `_merge_candidate_sources` — новая локальная функция в `app.py`:
- Слить по lower(term).
- Если термин есть в обеих — сложить веса, отметить `source: "correction+freq"`.
- Сортировка по итоговому скору: `correction_count * 10 + frequency_count`.
- Для каждого `pending_suggestions`-айтема добавить поле `source: "correction" | "frequency" | "both"` — в этапе 5 это покажем в UI.

### Триггер: показывать раньше при diff-сигнале

В `_maybe_trigger_prompt_analysis` (`app.py:520`) добавить fast-path:

```python
# Если за последние N=10 фраз появился хотя бы 1 повторяющийся inserted-token —
# триггерим анализ немедленно, не ждём auto_prompt_check_interval (50).
if _has_fresh_strong_correction_signal():
    self._run_prompt_analysis(...)
    return
```

`_has_fresh_strong_correction_signal()` — лёгкая проверка по corrections.json: есть ли в `inserted_terms` хоть один термин с `count ≥ 2` и `last_seen` в пределах последних 10 фраз. Без полного reanalysis dataset.

---

## Изменения по файлам

| Файл | Изменение |
|---|---|
| `src/correction_analyzer.py` | **Новый.** Описанный выше API. |
| `src/utils.py` | `get_corrections_file_path()` хелпер. |
| `src/dataset_logger.py` | Без изменений (формат уже подходит). Опционально — индекс позиции файла, но проще timestamp-based. |
| `src/app.py` | `_run_prompt_analysis` — добавить корректировочный источник + merge. `_maybe_trigger_prompt_analysis` — fast-path триггер. |
| `src/log_analyzer.py` | Экспортировать `_TERM_STOPLIST`, `_RUS_FUNCTION_WORDS`, `_TERM_PATTERN` (убрать подчёркивание у имён, либо завести публичные алиасы). |
| `tests/test_correction_analyzer.py` | **Новый.** См. ниже. |

---

## Тесты

Файл `tests/test_correction_analyzer.py`:

1. **test_pure_insert_collected** — `ai_edited="hello world"`, `user_final="hello PCA world"` → `PCA` попадает в `inserted_terms["en"]`.
2. **test_replacement_pair_collected** — `raw_whisper="hello питон"`, `user_final="hello Python"` → пара `("питон","Python")` в `replacement_pairs["en"]`.
3. **test_filler_words_filtered** — пустые правки (только пунктуация / стоп-слова) не создают кандидатов.
4. **test_incremental_update** — два прогона с разными timestamp в dataset, второй обрабатывает только новые записи.
5. **test_count_aggregates** — один и тот же inserted-term в трёх записях → `count == 3`.
6. **test_long_replacement_skipped** — replace на 6 токенов с каждой стороны игнорируется.
7. **test_min_correction_count** — `min_correction_count=2`, термин с count=1 не попадает в кандидаты.
8. **test_existing_terms_excluded** — токен уже в `existing_lower_by_lang["en"]` → не предлагается.
9. **test_cooldown_respected** — токен в `skipped` с недавним номером фразы → не предлагается.
10. **test_atomic_write** — kill процесса посреди записи corrections.json не оставляет битый файл (мокаем `os.replace`).

Существующие тесты `tests/test_log_analyzer.py` не должны сломаться — `get_prompt_candidates` не меняем сигнатурно.

---

## Риски и митигации

| Риск | Митигация |
|---|---|
| Шум от случайных правок (опечатка, переформулировка) | `min_correction_count=2` — нужен повтор. Плюс игнор замен >4 токенов. |
| Юзер случайно вставил мусор → попадёт в словарь | Pending-режим (suggest) уже даёт ревью перед добавлением. Auto-режим включает сам пользователь, осознанно. |
| Dataset разрастается, парсинг тормозит | Incremental: `last_processed_ts` в индексе. Полный reparse только при `schema_version` mismatch. |
| Старые правки 6-месячной давности продолжают тянуть устаревший термин | Решается этапом 3 (decay по `last_seen`). До него — добавить параметр `max_age_days=60` в `get_correction_candidates`. |
| Конфликт записи corrections.json из двух потоков | `_run_prompt_analysis` уже под `_analysis_lock` (см. `app.py:534`). Других писателей нет. |
| dataset.jsonl содержит битую строку | Try/except per-line; пропускать молча с `log_info`. |

---

## Критерии готовности

- [ ] `correction_analyzer.py` написан, все тесты проходят.
- [ ] При тесте «runtime»: набираю фразу с новым английским термином, исправляю руками 2 раза подряд, на 3-й раз термин появляется в pending_suggestions.
- [ ] Существующий частотный путь не сломался — старые сценарии работают.
- [ ] `corrections.json` создаётся атомарно, переживает kill -9.
- [ ] CLAUDE.md обновлён: новый раздел «correction-driven candidates» в Roadmap (Etap 11) и в Module map.

---

## Порядок коммитов

1. `feat(corrections): add correction_analyzer module with diff-based extraction`
2. `feat(corrections): persist corrections.json atomically + incremental update`
3. `feat(app): integrate correction candidates into prompt analysis pipeline`
4. `feat(app): fast-path trigger on fresh correction signal`
5. `test(corrections): coverage for correction_analyzer`
6. `docs(claude-md): document correction-driven candidate flow (Etap 11)`
