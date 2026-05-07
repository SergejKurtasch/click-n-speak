# Этап 3 — Ротация словаря (decay + бюджет токенов)

## Цель

Убрать «вечный рост» словаря. Сейчас принятые термины живут в `user_terms` неограниченно. Initial prompt Whisper'a ограничен **224 BPE-токенами** (см. `_MAX_PROMPT_TOKENS` логику в `utils.py:build_initial_prompt`); при переполнении — обрезается. Через несколько месяцев активного использования старые редко-нужные термины будут вытеснять новые актуальные.

Решение: «возраст и употребление» для каждого авто-добавленного термина. Термины, не появлявшиеся в истории фраз дольше N дней, помечаются устаревшими и исключаются из initial_prompt (но не удаляются физически — пользователь может вернуть).

После этапа: словарь самоподдерживается. Постоянно используются ~активные 30–50 терминов. Manual-термины пользователя не удаляются никогда.

---

## Что есть сейчас

`config.json` v4 (`src/utils.py:migrate_config_to_v4`):

```json
{
  "user_terms": {"ru": ["термин1"], "en": ["PCA", "GitHub"]},
  ...
}
```

Каждый термин — просто строка. Нет метаданных:
- когда добавлен,
- когда последний раз использовался,
- руками или авто-анализом.

`build_initial_prompt(config)` (`src/utils.py`):
- Берёт `user_terms[primary] + user_terms[additional...]`.
- `deduplicate_prompt_terms()`.
- Обрезает по BPE до ~224 токенов.

---

## Новая структура — schema_version=5

Каждый термин — объект:

```json
{
  "schema_version": 5,
  "user_terms": {
    "en": [
      {"term": "PCA",    "source": "manual", "added_at": "2025-12-01T...", "last_seen": "2026-05-07T...", "use_count": 12},
      {"term": "GitHub", "source": "auto",   "added_at": "2026-01-15T...", "last_seen": "2026-04-30T...", "use_count": 47},
      {"term": "MLX",    "source": "correction", "added_at": "2026-05-01T...", "last_seen": "2026-05-06T...", "use_count": 5}
    ]
  }
}
```

### Поля

| Поле | Тип | Назначение |
|---|---|---|
| `term` | str | Само слово (с регистром) |
| `source` | enum: `"manual"` / `"auto"` / `"correction"` | Откуда пришло. Влияет на decay-политику. |
| `added_at` | ISO datetime | Когда впервые добавлено |
| `last_seen` | ISO datetime | Последнее обнаружение в `phrase_history` |
| `use_count` | int | Количество появлений в фразах. Для тай-брейка при сортировке initial_prompt. |

### Совместимость / миграция

`migrate_config_to_v5(config)` в `src/utils.py`:

```python
def migrate_config_to_v5(config: dict) -> dict:
    if config.get("schema_version", 1) >= 5:
        return config
    now_iso = datetime.now(timezone.utc).isoformat()
    new_user_terms: dict[str, list[dict]] = {}
    for lang, terms in (config.get("user_terms") or {}).items():
        new_user_terms[lang] = []
        for t in terms:
            if isinstance(t, str):
                # Старые термины помечаем как manual — самое безопасное;
                # они будут защищены от decay
                new_user_terms[lang].append({
                    "term": t,
                    "source": "manual",
                    "added_at": now_iso,
                    "last_seen": now_iso,
                    "use_count": 0,
                })
            elif isinstance(t, dict):
                # Уже в новом формате — не трогаем
                new_user_terms[lang].append(t)
    config["user_terms"] = new_user_terms
    config["schema_version"] = 5
    return config
```

Все читатели `user_terms` должны уметь работать с обоими форматами на время отладки. Хелпер `_term_str(item) -> str`:

```python
def _term_str(item) -> str:
    return item if isinstance(item, str) else item["term"]
```

Использовать его везде, где сейчас итерация по `user_terms[lang]`. Места:
- `src/utils.py:build_initial_prompt` (несколько строк)
- `src/utils.py:deduplicate_prompt_terms`
- `src/menu_bar.py` — submenu «Edit Terms», «Manage Auto Terms»
- `src/app.py:_apply_candidates_to_user_terms`
- `src/log_analyzer.py:get_prompt_candidates` — `existing_lower_by_lang` строится в `app.py`, там и патчим

---

## Алгоритм decay

### Когда запускается

- **Один раз в день**, через rumps-таймер. Триггер по `last_decay_run_ts` в config.
- **При старте**, если `now - last_decay_run_ts > 24h`.
- **Ручной** через меню: «Refresh Dictionary» (опционально, не критично).

### Что делает

```python
def apply_decay(config: dict, max_age_days: int = 60) -> int:
    """Mark stale auto-terms inactive in initial_prompt.

    Returns number of terms deactivated.
    """
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=max_age_days)
    deactivated = 0
    for lang, terms in config.get("user_terms", {}).items():
        for item in terms:
            if isinstance(item, str):
                continue  # legacy, не трогаем
            if item.get("source") == "manual":
                continue  # manual вечны
            last_seen = datetime.fromisoformat(item.get("last_seen") or item.get("added_at"))
            if last_seen < cutoff and item.get("use_count", 0) < 3:
                if not item.get("inactive"):
                    item["inactive"] = True
                    deactivated += 1
    return deactivated
```

`build_initial_prompt` пропускает `inactive=True` термины:

```python
active_terms = [t for t in lang_terms if not (isinstance(t, dict) and t.get("inactive"))]
```

**Не удаляем** физически — пользователь может «реактивировать» через UI. Удаление только из меню «Manage Terms» (как сейчас «Очистить всё»).

### Обновление `last_seen` / `use_count`

Где-то в hot-path надо отмечать «термин встретился». Варианты:

**A) В `_run_injection`** (`app.py:464`), после `append_phrase`:

```python
update_term_usage(self.config, user_text)  # tokenize, find matches, bump counters
```

— Плюс: гарантированно работает.
— Минус: микро-латентность в hot-path (но операция дешёвая, ~1 мс на 100 терминов).

**B) В фоновом scan'е раз в час** — просканить последние N фраз и обновить статистику.

— Плюс: hot-path чистый.
— Минус: задержка обновления, риск «пропустить» термин при крэше.

**Рекомендация: вариант A.** Реализация:

```python
def update_term_usage(config: dict, phrase: str) -> None:
    tokens = set(_tokenize_lower(phrase))
    now_iso = datetime.now(timezone.utc).isoformat()
    for lang, terms in config.get("user_terms", {}).items():
        for item in terms:
            if isinstance(item, str):
                continue
            if item["term"].lower() in tokens:
                item["last_seen"] = now_iso
                item["use_count"] = item.get("use_count", 0) + 1
                if item.get("inactive"):
                    item.pop("inactive")  # вернулся к жизни
    # save_config_to_disk вызывается уже в _run_injection? проверить — иначе добавить
```

Сохранение конфига — реже, чем после каждой фразы (чтобы не дёргать диск). Стратегия: dirty-флаг + сохранение раз в 30 секунд через таймер. Либо: при каждом `_maybe_trigger_prompt_analysis` (он и так пишет config).

---

## Порядок терминов в initial_prompt

Текущий: алфавитный или порядок добавления (зависит от `deduplicate_prompt_terms`). Делаем приоритезацию для случая обрезки по токенам:

1. Все `manual` термины — первыми (юзер их явно добавил).
2. Затем `correction` — сильный сигнал.
3. Затем `auto` — сортировка по `use_count` desc, затем `last_seen` desc.

Если бюджет токенов исчерпан — обрезаются с конца (то есть редко-используемые auto-термины).

---

## UI

### Меню «Manage Terms» (расширение существующего)

В `src/menu_bar.py` уже есть «Manage Auto Terms…». Расширяем до универсального диалога:

- Список с колонками: term, source (значок), use_count, last_seen («3 дня назад»), статус (active / inactive).
- Действия: «Activate», «Deactivate», «Delete», «Convert to manual».

NSAlert не справится — нужен NSWindow с NSTableView. Опционально для этого этапа: если сложно — оставляем простой NSAlert «Очистить все inactive», полноценный UI откладываем.

### Уведомление о ротации

Раз в 30 дней, если apply_decay deactivated >0:
- `rumps.notification("Click-n-speak", "Cleaned dictionary", f"{n} unused terms deactivated. Open Manage Terms to review.")`.

---

## Изменения по файлам

| Файл | Изменение |
|---|---|
| `src/utils.py` | `migrate_config_to_v5`. `_term_str` хелпер. `build_initial_prompt` — учёт `inactive`, приоритизация по source/use_count. `deduplicate_prompt_terms` — работа с dict. Дефолт `max_dictionary_age_days = 60`. |
| `src/app.py` | `update_term_usage()` функция + вызов в `_run_injection`. Таймер `_decay_tick()` раз в 24h. Сохранение config через dirty-flag. |
| `src/menu_bar.py` | `_term_str` для всех итераций. Расширение «Manage Auto Terms» до общего «Manage Terms». Уведомление о ротации. |
| `src/log_analyzer.py` | `existing_lower_by_lang` строится из dict-объектов (через `_term_str`). |
| `tests/test_utils.py` | Тесты миграции v4→v5. |
| `tests/test_decay.py` | **Новый.** Тесты apply_decay, update_term_usage. |

---

## Тесты

Файл `tests/test_decay.py`:

1. **test_v4_to_v5_migration** — старый строковый формат → новый dict с `source="manual"`.
2. **test_v5_idempotent** — повторная миграция не меняет ничего.
3. **test_apply_decay_marks_old_auto_terms_inactive** — auto-термин с last_seen 90 дней назад и use_count<3 → inactive=True.
4. **test_apply_decay_keeps_manual_terms** — manual-термин с last_seen 90 дней назад → остаётся active.
5. **test_apply_decay_keeps_recently_used** — auto с last_seen 10 дней назад → active.
6. **test_apply_decay_keeps_high_use_count** — auto с last_seen 90 дней, но use_count=10 → active.
7. **test_update_term_usage_bumps_counter** — фраза содержит термин → use_count++, last_seen=now.
8. **test_update_term_usage_reactivates** — inactive термин снова встретился → inactive снят.
9. **test_inactive_terms_excluded_from_prompt** — `build_initial_prompt` пропускает inactive.
10. **test_term_priority_in_prompt** — manual > correction > auto-by-use_count.

---

## Риски и митигации

| Риск | Митигация |
|---|---|
| Сломать чтение старого config v4 | Расширенная миграция + хелпер `_term_str` для всех читателей. |
| `update_term_usage` тормозит hot-path | На 100 терминах — ~1 мс. Если беспокоит — можно перенести в daemon-thread. |
| Удалили нужный термин по ошибке | Только `inactive`, не delete. Реактивация автоматическая (при следующем употреблении). Manual вообще не трогаем. |
| Юзер хочет настроить срок 30/90/180 дней | `max_dictionary_age_days` в config; UI-настройка опциональна. |
| Конфликт с этапом 1 (correction-сигнал создаёт термины) | Корректировочные термины добавляются с `source="correction"`. Defaults для них — те же decay-правила. |
| Дополнительные writes config.json | Dirty-flag, batched flush раз в 30 сек или при критических точках (suggestion accept/reject). |

---

## Критерии готовности

- [ ] Старый config v4 (с строковыми терминами) корректно мигрирует в v5 без потерь.
- [ ] `build_initial_prompt` работает идентично для v4 и v5 при только что мигрированном словаре.
- [ ] Тест на runtime: подменить `last_seen` у auto-термина в config, перезапустить → термин помечен inactive, в Whisper-промпте его нет.
- [ ] Manual-термины никогда не уходят в inactive.
- [ ] Все старые тесты зелёные.
- [ ] CLAUDE.md обновлён: schema v5, разделы про decay и source.

---

## Порядок коммитов

1. `feat(config): introduce v5 schema with per-term metadata + migration`
2. `refactor(read-paths): use _term_str helper for legacy/v5 transparency`
3. `feat(decay): apply_decay() marks stale auto terms inactive`
4. `feat(app): update_term_usage() + 24h decay tick`
5. `feat(menu-bar): extend Manage Terms UI for source/usage/inactive`
6. `test(decay): coverage for migration, decay, usage updates`
7. `docs(claude-md): document v5 schema and dictionary rotation`
