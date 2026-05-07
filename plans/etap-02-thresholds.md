# Этап 2 — Смягчение порогов частотного анализа

## Цель

Сейчас даже если этап 1 (diff-сигнал) не выделил термин (например, пользователь не правил руками, а просто часто диктует), частотный путь всё равно будет ждать **10 совпадений в ≥2 разных сессиях** — это субъективно «слишком долго». Снизить пороги для EN-токенов так, чтобы новый специфический термин предлагался после **5–6 повторов**, не превратив при этом suggestions в помойку.

После этапа: если я начал в новой неделе диктовать слово «MLX» — оно появится в подсказках после ~5 использований, а не 10.

---

## Что есть сейчас

`src/log_analyzer.py:get_prompt_candidates()`:
- `lookback=100` — окно последних фраз
- `min_count=5` (default параметра функции)

`src/app.py:_run_prompt_analysis()` переопределяет:
- В авто-режиме: `lookback=100`, `min_count=int(self.config.get("auto_prompt_check_min_count", 10))` ← **это и есть текущий порог: 10**
- В on-demand режиме: `lookback=500`, `min_count=10`

`_collect_english_terms` дополнительно требует **≥2 distinct sessions** (`term_sessions[lower] < 2 → skip`).

`_collect_russian_bigrams`: token-weighted threshold (`max(_whisper_token_count(w1,w2)) >= 3`), min_count=5.

Триггер: `_maybe_trigger_prompt_analysis` ждёт пока `current - last_check >= auto_prompt_check_interval` (default 50 фраз).

---

## Новые пороги

| Параметр | Сейчас | Новое значение | Комментарий |
|---|---|---|---|
| `auto_prompt_check_min_count` (EN) | 10 | **5** | Главное изменение |
| `auto_prompt_check_min_count` (RU bigrams) | 10 | **8** | RU — оставляем строже, биграмм-шум сильнее |
| `auto_prompt_check_interval` | 50 | **20** | Анализ чаще; стоит копейки |
| `lookback` (auto-режим) | 100 | **300** | Шире окно — больше сигнала |
| `lookback` (on-demand) | 500 | **1000** | Кнопка «проверить сейчас» — пусть копает глубже |
| `cooldown_phrases` | 100 | **150** | Чтобы при чаще-анализе один и тот же мусор не вылезал |
| `max_per_lang` | 20 | **15** | Меньше длинного списка для ревью |
| `_collect_english_terms`: ≥2 sessions | required | **required только если нет diff-сигнала** | См. ниже |

### Раздельные пороги: EN vs RU

`get_prompt_candidates` сейчас принимает один `min_count`. Меняем на dict:

```python
def get_prompt_candidates(
    lookback: int = 300,
    min_count: dict[str, int] | int = None,  # {"en": 5, "ru": 8}; int → одинаковый для всех
    ...
):
```

Совместимость: int → раскладываем в `{"en": x, "ru": x}`. В `app.py` — передаём dict.

### Снятие требования ≥2 сессий — только при наличии diff-сигнала

В `_collect_english_terms` добавить параметр `term_has_correction_signal: Callable[[str], bool] | None = None`. Если коллбек возвращает True — пропускаем session-фильтр для этого термина:

```python
for lower, variants in lower_to_variants.items():
    has_correction = term_has_correction_signal and term_has_correction_signal(lower)
    if not has_correction and len(term_sessions[lower]) < 2:
        continue
    ...
```

Где `term_has_correction_signal(lower)` строится из `corrections.json` (см. этап 1) — `lower in inserted_terms["en"]`.

**Зачем:** если пользователь руками поправил термин — нам не важно, повторил ли он его в разных сессиях. Один сильный сигнал перевешивает.

### Конфигурируемость

В `config.json`:

```json
{
  "auto_prompt_check_min_count": 5,
  "auto_prompt_check_min_count_ru": 8,
  "auto_prompt_check_interval": 20,
  "auto_prompt_lookback": 300
}
```

Дефолты — выше. Существующая ключ `auto_prompt_check_min_count` сохраняем, но семантика «для EN». Новый ключ `auto_prompt_check_min_count_ru`. Без миграции (старые конфиги получают новые дефолты автоматически через `.get(key, default)`).

---

## Изменения по файлам

| Файл | Изменение |
|---|---|
| `src/log_analyzer.py` | `get_prompt_candidates` — поддержка dict `min_count`; `_collect_english_terms` — параметр `term_has_correction_signal`. |
| `src/app.py` | `_run_prompt_analysis` — передавать новые пороги из config; собрать `term_has_correction_signal` из corrections.json (этап 1); понизить дефолты. |
| `src/utils.py` | Дефолты `auto_prompt_check_min_count=5`, `auto_prompt_check_interval=20` в любых местах, где есть `.get(...)` с дефолтом. |
| `tests/test_log_analyzer.py` | Скорректировать существующие тесты, у которых хардкод порогов. Добавить новые (см. ниже). |

---

## Тесты

В `tests/test_log_analyzer.py`:

1. **test_min_count_dict_per_lang** — `min_count={"en": 5, "ru": 8}`, EN-термин с count=5 проходит, RU-биграмма с count=5 — нет.
2. **test_correction_signal_bypasses_session_filter** — EN-токен в одной сессии, count=3, но `term_has_correction_signal=lambda t: t == "mlx"` → попадает в кандидаты.
3. **test_no_correction_signal_keeps_session_filter** — тот же токен без signal → не попадает.
4. **test_default_thresholds_relaxed** — параметры по умолчанию `min_count=None` → используются ослабленные дефолты.
5. **test_lookback_larger_window** — фразы старше 300 строк не учитываются (если в auto-режиме).

**Регрессия:** запустить весь существующий `tests/test_log_analyzer.py` и убедиться, что не упало (где упадёт — обновить хардкод порогов в тесте, **не** в коде).

---

## Риски и митигации

| Риск | Митигация |
|---|---|
| Резкий рост шума в `pending_suggestions` (терминов 50+ за день) | `max_per_lang=15` + cooldown=150 + ревью в режиме `suggest` остаётся обязательным. Auto-режим — на ответственность пользователя. |
| Whisper-галлюцинации (повторяющиеся фейковые слова) попадают как кандидаты | Уже фильтруются: `_filter_near_duplicates`, reverse-bigram filter, hallucination_phrases в transcriber. Дополнительно — стоп-листы. |
| Слишком частый анализ грузит CPU | Анализ запускается в daemon-thread, под non-blocking lock. На 1000 фразах SequenceMatcher отрабатывает за <100мс. Не критично. |
| RU-биграммы засоряют, потому что 8 — всё ещё мало | Добавить параметр `auto_prompt_check_min_count_ru` отдельно; пользователь может поднять. |
| Триггер каждые 20 фраз — слишком часто показываем алерт | Алерт показывается из `_show_suggestions_alert` уже только при стартовых проверках; внутри сессии добавляется только badge. Пользователя не дёргаем. |

---

## Критерии готовности

- [ ] Все новые/обновлённые тесты `test_log_analyzer.py` зелёные.
- [ ] При тесте «runtime»: задиктовал 5 раз слово «MLX» в течение одной короткой сессии — после очередной фразы термин появился в pending. Без diff-сигнала: чтобы сработало, нужно ≥2 сессий и count≥5 (старая логика, но порог ниже).
- [ ] CLAUDE.md обновлён: дефолты `auto_prompt_check_*` в разделе config schema.
- [ ] Никакой миграции config не нужно (новые ключи опциональны).

---

## Порядок коммитов

1. `feat(log-analyzer): per-language min_count and correction-signal bypass for session filter`
2. `feat(app): lower default thresholds; pass corrections-aware bypass to analyzer`
3. `test(log-analyzer): coverage for new thresholds and bypass`
4. `docs(claude-md): updated default analyzer thresholds`

---

## Зависимость от этапа 1

`term_has_correction_signal` опирается на `corrections.json` из этапа 1. Если этап 1 ещё не сделан — в этапе 2 параметр оставить `None`, всё работает как раньше + новые пороги. Полный эффект этапа 2 раскрывается только вместе с этапом 1.
