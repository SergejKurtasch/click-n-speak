# Этап 6 — Метрики качества словаря

## Цель

Без измерений нельзя понять, помогли ли этапы 1–5. Нужен компактный набор показателей, которые сами собираются по dataset.jsonl + corrections.json и показывают **тренд** во времени:

- Падает ли число правок на 100 фраз? (хорошо)
- Растёт ли «hit rate» — % фраз, где термин из словаря реально встретился? (хорошо)
- Сколько активных терминов? Какой возраст самого старого активного?
- Сколько кандидатов отклонено / принято?

После этапа: одна команда из меню или CLI выдаёт сводку, и эта же сводка опционально показывается раз в месяц как уведомление.

---

## Что есть сейчас

- `~/.clicknspeak_dataset.jsonl` — все триплеты (неиспользуется аналитикой).
- `~/Library/Application Support/Click-n-speak/phrase_history.txt` — финальный текст.
- `config.json` — `user_terms`, `pending_suggestions`, `skipped_terms`.
- `corrections.json` (этап 1) — diff-сигналы.
- Лог `~/Library/Logs/Click-n-speak.log`.

---

## Метрики

### 1. Edit distance per phrase (главная)

«Насколько сильно пользователь правит финальный текст?» — единственная метрика, прямо измеряющая качество для пользователя.

```python
edit_score = levenshtein(ai_edited, user_final) / max(len(ai_edited), len(user_final), 1)
```

Или, если хочется пословно — token-level edit distance.

Агрегация: среднее за последние N=100 фраз vs предыдущие 100. Тренд: ↑ / ↓ / →.

### 2. Dictionary hit rate

«Сколько фраз содержит хотя бы один термин из словаря?» — индикатор «попадают ли наши термины в живую речь».

```python
hit_rate = sum(1 for ph in last_100 if any(t in tokens(ph) for t in active_terms)) / 100
```

Если близко к 0% — словарь оторван от реальности (наполнен мусором или устарел). Если высокий — пользователь активно говорит то, что он же добавил.

### 3. Terms catalogue health

- `active_terms_count` — сколько активных в `user_terms` (не inactive).
- `manual_terms_count` / `auto_terms_count` / `correction_terms_count` — разбивка по source.
- `oldest_active_age_days` — возраст самого долгоиспользуемого.
- `inactive_terms_count` — кандидаты на удаление.

### 4. Candidate funnel

Воронка предложений из `pending_suggestions` + `skipped_terms`:

- `proposed_total` — сколько всего предложили (cumulative).
- `accepted_total` — сколько добавлено в `user_terms` через ревью.
- `rejected_total` — `len(skipped_terms[...])`.
- `pending_now` — `len(pending_suggestions[...])`.
- `acceptance_rate` = accepted / (accepted + rejected). Если <30% — анализатор шумит, пороги слишком слабые.

### 5. Initial prompt budget utilisation

- `prompt_tokens_used` — текущий size of `initial_prompt` в BPE-токенах.
- `prompt_tokens_max` — 224 (или текущий `_MAX_PROMPT_TOKENS`).
- `utilisation_pct` — first-warning ≥80%, critical ≥95%.

Подсказывает: пора чистить словарь? Decay (этап 3) работает?

### 6. Correction recurrence

«Сколько раз пользователь повторно правил уже исправленную пару?» — если `питон → Python` всё ещё всплывает после того, как Gemini получает её в misrecognitions (этап 4), значит, замена не работает.

```python
for pair, count in replacement_pairs:
    if pair in current_misrecognitions and count_in_last_30days > 3:
        flag as "не работает"
```

---

## Где хранить и как считать

### Модуль `src/metrics.py` (новый)

```python
def compute_metrics(
    dataset_path: Path,
    corrections_path: Path,
    config: dict,
    window_size: int = 100,
) -> dict:
    """Read recent dataset records and compute current snapshot of metrics.

    Returns a dict with all the metrics described above. Pure function — does
    not write to disk. Caller decides whether to log/notify/show.
    """
```

Реализация:
- Читать tail dataset.jsonl (последние 200 строк) — `deque(maxlen=200)`.
- Считать metrics 1, 2 на этих записях.
- Metrics 3, 4 — из config.
- Metric 5 — вызвать `build_initial_prompt` + tokenize.
- Metric 6 — пройтись по corrections.json `replacement_pairs`, посмотреть `last_seen` за 30 дней.

### Снапшоты во времени

Файл `~/Library/Application Support/Click-n-speak/metrics_history.jsonl`:

Append-only, одна запись в день:

```json
{
  "ts": "2026-05-07T...",
  "edit_score_avg": 0.082,
  "hit_rate": 0.34,
  "active_terms": 27,
  "acceptance_rate": 0.62,
  "prompt_utilisation": 0.71
}
```

Триггер: при первом запуске за сутки (как и decay из этапа 3 — можно объединить в общий «daily maintenance» tick).

Хранить ~365 дней, дальше log-rotate (>1MB → переименование в `.1`, выкидываем старее).

---

## UI / поверхности

### A. Меню «Statistics…»

В `menu_bar.py` добавить пункт под «Manage Terms…»:

```
Statistics…
```

При клике — открывает NSAlert с форматированной сводкой:

```
Recent dictionary performance (last 100 phrases)

Edit corrections per phrase    8.2%   ↓ from 11.4% (good)
Dictionary hit rate            34%    ↑ from 28%  (good)
Active terms                   27     (12 manual / 9 auto / 6 correction)
Acceptance rate                62%    (19 accepted, 12 rejected)
Prompt utilisation             71%    (158 of 224 tokens)

Inactive terms ready to clean: 4
Open Manage Terms to review.

[OK]  [Open metrics history]
```

«Open metrics history» — открывает `metrics_history.jsonl` в дефолтном редакторе (`open` команда).

### B. Логи

При каждом снапшоте `metrics.py` пишет однострочный summary в основной лог:

```
[INFO] Daily metrics: edit=8.2% (-3.2%), hit=34% (+6%), active=27, acceptance=62%
```

### C. Опциональное notification

Раз в месяц, если `edit_score_avg` сильно вырос (>50% относительно лучшего за квартал) — мягкое уведомление: «Dictionary may need attention. Open Statistics for details.»

Throttled: не чаще 1 в 30 дней.

### D. CLI / debug

В `scripts/print_metrics.py`:

```python
#!/usr/bin/env python3
from src.metrics import compute_metrics
from src.utils import load_config_data, get_corrections_file_path
...
print(json.dumps(compute_metrics(...), indent=2, default=str))
```

Полезно для разработки — быстро посмотреть текущее состояние без перезапуска приложения.

---

## Изменения по файлам

| Файл | Изменение |
|---|---|
| `src/metrics.py` | **Новый.** `compute_metrics`, `_edit_score`, `_hit_rate`, и т. д. |
| `src/app.py` | Daily maintenance tick: вызов `compute_metrics` + `append_to_metrics_history`. Объединить с decay-tick этапа 3. |
| `src/menu_bar.py` | Меню «Statistics…», обработчик `_show_statistics_alert`. |
| `scripts/print_metrics.py` | **Новый.** CLI-обёртка. |
| `tests/test_metrics.py` | **Новый.** Юнит-тесты на каждую метрику с фикстурой dataset/config/corrections. |

---

## Тесты

В `tests/test_metrics.py`:

1. **test_edit_score_zero_if_identical** — `ai_edited == user_final` → 0.0.
2. **test_edit_score_one_if_completely_different** — диаметрально разный текст → 1.0.
3. **test_hit_rate_counts_distinct_phrases** — 30 из 100 фраз содержат хоть один term → 0.30.
4. **test_active_terms_count_excludes_inactive** — 5 active + 3 inactive → 5.
5. **test_acceptance_rate** — 10 accepted, 5 rejected → 0.667.
6. **test_acceptance_rate_handles_zero** — нет ни принятых, ни отклонённых → None или 0.
7. **test_prompt_utilisation** — синтезированный prompt в 100 токенах из 224 → 0.446.
8. **test_correction_recurrence_flags_failed_pair** — пара с count=10 за 30 дней → попадает в «failed».
9. **test_metrics_window_respects_size** — `window_size=50` → читает только 50 последних записей dataset.
10. **test_metrics_history_appends_atomic** — fault inject mid-write, файл остаётся валидным JSONL.

---

## Риски и митигации

| Риск | Митигация |
|---|---|
| Чтение всего dataset тормозит | Tail-only через `deque(maxlen=200)` или offset-based. На 10к записей — <50 мс. |
| Метрики путают пользователя цифрами | Краткий формат + явные «↓ good» / «↑ bad» индикаторы. Не показываем все, только 5 главных. |
| Пользователь воспринимает уведомление как навязчивое | Throttled, отключается флагом `notify_on_metrics: false`. |
| Edit-score искажён длинными правками AI editor (не только по словарю) | Это понимается. Метрика общая по качеству; для словаря-специфики используем `hit_rate` и correction recurrence. |
| `metrics_history.jsonl` растёт бесконечно | Rotate >1MB, хранить максимум год. |
| Levenshtein на длинных текстах медленный | Используем `_levenshtein` с early-exit (есть в log_analyzer.py); для очень длинных — character-trim до первых 1000 символов. |

---

## Критерии готовности

- [ ] `compute_metrics` возвращает dict с всеми описанными полями.
- [ ] Меню «Statistics…» открывает NSAlert с цифрами и тренд-стрелками.
- [ ] Daily-tick дописывает строку в `metrics_history.jsonl` ровно раз в сутки.
- [ ] CLI `scripts/print_metrics.py` выдаёт JSON.
- [ ] Все тесты `test_metrics.py` зелёные.
- [ ] CLAUDE.md обновлён: раздел «Metrics» в Module map + «Daily maintenance» в lifecycle.

---

## Порядок коммитов

1. `feat(metrics): compute_metrics module with edit-score, hit-rate, funnel`
2. `feat(metrics): persist daily snapshots in metrics_history.jsonl`
3. `feat(menu-bar): Statistics… alert with trend arrows`
4. `feat(scripts): print_metrics CLI helper`
5. `feat(metrics): throttled notification on degraded edit-score`
6. `test(metrics): coverage for all metrics + history rotation`
7. `docs(claude-md): document metrics module and daily tick`

---

## Зависимости

- Этап 1 (corrections.json) — нужен для метрики 6 (correction recurrence). Без него — метрика просто отсутствует в выводе.
- Этап 3 (decay + active/inactive) — нужен для разбивки terms catalogue. Без него — `active_terms_count == total_terms_count`.
- Этап 4 (Gemini vocab) — без него `correction recurrence` показывает естественный шум, не «не работает».

Этап 6 имеет смысл делать **последним**, когда есть что измерять. Делать его раньше можно, но половина метрик будет константно пустой.

---

## Бонус: когда смотреть на метрики

- После добавления нового сценария использования (новый домен — например, начал диктовать научные тексты): через неделю проверить, упал ли `edit_score`.
- При жалобах «приложение стало хуже распознавать» — открыть статистику, посмотреть тренд.
- При выпуске новой версии Whisper или Gemini-модели — A/B сравнение по `edit_score` между неделями.
