# Initial Prompt & Vocabulary — Roadmap & Implementation Plans

Документ собирает все идеи по улучшению системы `initial_prompt` для Whisper и сопутствующего словаря,
с **детальным планом реализации** для каждого пункта.

Источник: разговор 2026-05-17, после ручной чистки словаря (config.json.bak-20260517-014945).

Для каждого пункта: **описание**, **где править**, **критерий приёмки**, **оценка** + **План реализации**
(пошаговый порядок, контракты функций, тесты, edge cases, definition-of-done).

Приоритет:
- **P0** — баг или прямой негативный эффект
- **P1** — высокая отдача / низкие трудозатраты
- **P2** — нужно, но можно отложить
- **P3** — экспериментальное / опциональное

---

## A. Алгоритм и бюджет prompt

### A1. Проверка суммарного 224-токенного лимита Whisper в `process_chunk` — **P0**

Сейчас `build_initial_prompt` уважает только свой бюджет (200 ток.).
В `process_chunk` финальный `context = instruction + vocab_prompt + recent_text` может суммарно
превысить 224 токена Whisper'а → модель **молча обрежет с начала**, выкинув instruction и часть словаря.

- **Где:** `src/app.py:1330-1347` (формирование `context`), `src/utils.py:_count_prompt_tokens`.
- **Что делать:** перед передачей в transcriber пересчитать `_count_prompt_tokens(context)`.
  Если > 220 — урезать `recent_text` (по чанкам с конца), пока не уместится.
- **Acceptance:** unit-тест: 30 чанков по 30 chars каждый — `context` ≤ 220 токенов всегда.
- **Оценка:** ~1 час.

#### План реализации

**Шаг 1.** Вынести построение `context` в новую функцию `_build_chunk_context` (чисто для тестируемости).

```python
# src/app.py
_WHISPER_PROMPT_TOKEN_LIMIT = 220  # Whisper hard cap = 224, оставляем запас

def _build_chunk_context(
    instruction: str,
    vocab_prompt: str,
    transcribed_parts: list[str],
    char_budget: int = 700,
    token_limit: int = _WHISPER_PROMPT_TOKEN_LIMIT,
) -> str:
    """Build the initial_prompt context for one chunk transcription.
    Guarantees: result <= token_limit BPE tokens AND <= char_budget chars.
    vocab_prompt is preserved as a whole; recent_text is trimmed first."""
    base = instruction + vocab_prompt
    base_tokens = _count_prompt_tokens(base)
    available_chars = max(0, char_budget - len(base) - 1)
    available_tokens = max(0, token_limit - base_tokens)

    recent: list[str] = []
    used_chars = 0
    used_tokens = 0
    for chunk in reversed(transcribed_parts):
        sep = 1 if recent else 0
        needed_chars = len(chunk) + sep
        if used_chars + needed_chars > available_chars:
            break
        chunk_tokens = _count_prompt_tokens((" " if sep else "") + chunk)
        if used_tokens + chunk_tokens > available_tokens:
            break
        recent.append(chunk)
        used_chars += needed_chars
        used_tokens += chunk_tokens
    recent.reverse()

    if recent:
        return base + " " + " ".join(recent)
    return base
```

**Шаг 2.** Заменить inline-логику в `process_chunk` на вызов новой функции (`src/app.py:1330-1347`).

**Шаг 3.** Тесты — `tests/test_app_context.py`:
- `test_short_session_fits()` — 1 chunk × 20 chars → context содержит все парты
- `test_long_session_trims_recent()` — 30 chunks × 30 chars → последние влезли, ранние выкинуты
- `test_huge_vocab_leaves_no_room()` — vocab_prompt = 200 токенов, recent выкинут полностью
- `test_token_limit_respected()` — кириллический recent_text, проверяем `_count_prompt_tokens(result) <= 220`
- `test_char_budget_respected()` — `len(result) <= 700`

**Edge cases:**
- `transcribed_parts == []` → return `base` без trailing пробела
- `instruction == ""` → не падает (LANG_PROMPTS могут отсутствовать в edge config)
- `vocab_prompt` сам > 220 ток — не должно произойти (`build_initial_prompt` гарантирует), но логировать warning

**Definition of Done:**
- `process_chunk` использует `_build_chunk_context`
- Все тесты зелёные
- В логах нет warning'ов про token overflow на типичной 5-минутной сессии

---

### A2. Per-term hit tracking в `dataset_logger` — **P1**

Без этого невозможно ответить на вопрос «работает ли термин X».

- **Где:** `src/dataset_logger.py:append_to_dataset`, вызывается из `src/app.py` после транскрипции.
- **Что добавить в JSONL запись:**
  - `lang` — определённый Whisper'ом язык (берётся из transcribe result)
  - `vocab_terms_in_raw: list[str]` — токены `user_terms[lang]`, реально встретившиеся в `raw_whisper`
  - `vocab_terms_in_final: list[str]` — то же для `user_final`
  - `prompt_hash: str` — md5(initial_prompt) на момент транскрипции (см. N6)
- **Acceptance:** через 200 фраз можно построить отчёт «топ-10 терминов по hit-rate».
- **Оценка:** ~2-3 часа.

#### План реализации

**Шаг 1.** Расширить сигнатуру `append_to_dataset` (`src/dataset_logger.py:19`):

```python
def append_to_dataset(
    raw_text: str,
    ai_text: str,
    user_final_text: str,
    ai_status: str,
    *,
    lang: str | None = None,
    user_terms_for_lang: list[str] | None = None,
    prompt_hash: str | None = None,
) -> None:
    ...
    record = {
        "timestamp": ...,
        "raw_whisper": raw_text,
        "ai_edited": ai_text,
        "ai_status": ai_status,
        "user_final": user_final_text,
        "lang": lang,
        "prompt_hash": prompt_hash,
        "vocab_terms_in_raw": _find_terms(raw_text, user_terms_for_lang or []),
        "vocab_terms_in_final": _find_terms(user_final_text, user_terms_for_lang or []),
    }
```

**Шаг 2.** Реализовать `_find_terms(text, terms) -> list[str]`:

```python
# src/dataset_logger.py
import re
_WORD_RE = re.compile(r"[\w\-.+#]+", re.UNICODE)

def _find_terms(text: str, terms: list[str]) -> list[str]:
    """Return canonical_term_key of each user term found in text (case-insensitive)."""
    if not text or not terms:
        return []
    tokens = {canonical_term_key(t) for t in _WORD_RE.findall(text)}
    return sorted({canonical_term_key(t) for t in terms if canonical_term_key(t) in tokens})
```

**Шаг 3.** Обновить call-sites в `src/app.py` (поиск через `grep -n append_to_dataset src/app.py`):

```python
prompt_hash = hashlib.md5(self.config.get("initial_prompt", "").encode()).hexdigest()[:12]
detected_lang = transcribe_result.get("language") or primary_lang
user_terms = [_term_str(t) for t in self.config.get("user_terms", {}).get(detected_lang, []) if _term_is_active(t)]
append_to_dataset(
    raw_text=raw_whisper,
    ai_text=ai_edited,
    user_final_text=user_final,
    ai_status=ai_status,
    lang=detected_lang,
    user_terms_for_lang=user_terms,
    prompt_hash=prompt_hash,
)
```

Внимание: `transcriber.transcribe()` сейчас возвращает только `text: str`. Для `lang` нужно расширить
return type на `dict | tuple[str, str]`. Это **бьёт обратную совместимость** — обновить все call-sites.

**Шаг 4.** Скрипт анализа `scripts/term_effectiveness.py`:

```python
"""Compute per-term hit-rate from dataset JSONL."""
from collections import Counter
import json
from pathlib import Path

DATASET = Path.home() / ".clicknspeak_dataset.jsonl"
in_raw, in_final, total = Counter(), Counter(), 0

for line in DATASET.read_text().splitlines():
    rec = json.loads(line)
    if "vocab_terms_in_raw" not in rec:  # старые записи
        continue
    total += 1
    in_raw.update(rec.get("vocab_terms_in_raw") or [])
    in_final.update(rec.get("vocab_terms_in_final") or [])

print(f"{'term':<25} {'in_raw':>8} {'in_final':>10} {'help_ratio':>12}")
for term, n_final in in_final.most_common():
    n_raw = in_raw.get(term, 0)
    ratio = n_raw / n_final if n_final else 0
    print(f"{term:<25} {n_raw:>8} {n_final:>10} {ratio:>12.2%}")
```

`help_ratio` ≈ 1.0 → Whisper узнал термин сам (prompt помогает).
`help_ratio` < 0.3 → user всегда дописывает руками → prompt не работает / нужна замена.

**Шаг 5.** Тесты — `tests/test_dataset_logger.py`:
- `test_find_terms_case_insensitive()`
- `test_find_terms_punctuation()` — `C++` найти в "Я люблю C++ программирование"
- `test_record_shape()` — все ключи присутствуют

**Edge cases:**
- Запись без `lang` (старые) — поля `vocab_terms_in_*` будут пустые
- `transcribe_result` без `language` — fallback на `primary_lang`
- HUGE term list (>200) — `_find_terms` linear, OK

**Definition of Done:**
- Новые поля в каждой записи после деплоя
- `scripts/term_effectiveness.py` запускается и даёт осмысленный отчёт
- Старые записи не сломаны

---

### A3. Промо `failed_pairs` как активный сигнал — **P1**

В `metrics._correction_recurrence` уже считаются пары `from→to` (count ≥ 3 за 30 дней).
Сейчас они **нигде не показываются пользователю**.

- **Где:** новый UI-блок в Statistics (`src/menu_bar.py:_show_statistics`); опционально — toast после транскрипции.
- **Что показать:** «Whisper упорно слышит „виспер" → „Whisper" (7×). [Добавить в manual_replacements]».
- **Acceptance:** клик по предложению добавляет пару в `manual_replacements` без открытия панели.
- **Оценка:** ~2 часа.

#### План реализации

**Шаг 1.** API для получения top-N failed pairs (новая функция в `src/metrics.py`):

```python
def get_top_failed_pairs(
    corrections_path: Path,
    limit: int = 5,
    min_count: int = 3,
    lookback_days: int = 30,
) -> list[dict]:
    """Return [{"from": str, "to": str, "count": int, "bucket": str}, ...]
    отсортированный по count desc, для UI."""
    data = _read_corrections(corrections_path)
    rec = _correction_recurrence(data, lookback_days, min_count)
    return rec["failed_pairs"][:limit]
```

**Шаг 2.** UI-блок в `_show_statistics` (`src/menu_bar.py`). Добавить секцию после метрик:

```python
failed = get_top_failed_pairs(corrections_path(), limit=5)
if failed:
    msg += "\n\n🔴 Whisper упорно не узнаёт:\n"
    for fp in failed:
        msg += f"  • „{fp['from']}" → „{fp['to']}" ({fp['count']}×)\n"
    msg += "\nДобавить как manual_replacement в Replacements…"
```

В кнопках NSAlert добавить третью «Открыть Replacements…» → открывает существующую панель.

**Шаг 3.** Опционально (если время есть): метод одного клика —
`apply_failed_pair_as_replacement(from_text, to_text)`:

```python
# src/vocab_provider.py
def apply_failed_pair_as_replacement(config: dict, from_text: str, to_text: str) -> bool:
    items = list(config.get("manual_replacements") or [])
    for item in items:
        if item.get("from") == from_text and item.get("to") == to_text:
            return False  # уже есть
    items.append({
        "from": from_text,
        "to": to_text,
        "enabled": True,
        "added_at": datetime.now(timezone.utc).isoformat(),
    })
    config["manual_replacements"] = items
    return True
```

**Шаг 4.** Тесты:
- `test_get_top_failed_pairs_sorted()` — корректная сортировка
- `test_apply_failed_pair_idempotent()` — двойной вызов не дублирует
- `test_get_top_failed_pairs_empty_corrections()` — пустой `corrections.json` → []

**Edge cases:**
- `corrections.json` отсутствует → пустой список
- Failed pair уже в `manual_replacements` — UI должен это отметить («✓ уже добавлено»)

**Definition of Done:**
- Статистика показывает top-5 failed_pairs
- Можно открыть Replacements одним кликом
- (Опционально) кнопка «Добавить все» добавляет недостающие пары

---

### A4. Жёсткая чистка мусорных auto-терминов — **P1**

Сейчас `apply_decay` срабатывает только через 60 дней.
Термин `Large` с `use_count=0` живёт месяц зря, занимая токены.

- **Где:** `src/utils.py:apply_decay`.
- **Правило:** если `source=auto` AND `use_count=0` AND возраст > 14 дней → `inactive=True`.
- **Acceptance:** unit-тест: 5 auto-терминов, разные `added_at` и `use_count`, проверить корректную деактивацию.
- **Оценка:** ~1 час.

#### План реализации

**Шаг 1.** Добавить в `src/utils.py`:

```python
_FAST_DECAY_AGE_DAYS = 14
_FAST_DECAY_MIN_USE_COUNT = 1  # use_count < 1 = 0

def apply_fast_decay(config: dict) -> int:
    """Aggressive decay for auto-terms that never proved useful.
    Returns number of deactivated terms."""
    now = datetime.now(UTC)
    cutoff = now - timedelta(days=_FAST_DECAY_AGE_DAYS)
    count = 0
    for lang, items in (config.get("user_terms") or {}).items():
        for item in items:
            if not isinstance(item, dict):
                continue
            if item.get("source") != "auto":
                continue
            if item.get("inactive"):
                continue
            if item.get("use_count", 0) >= _FAST_DECAY_MIN_USE_COUNT:
                continue
            added = _parse_iso(item.get("added_at"))
            if added is None or added > cutoff:
                continue
            item["inactive"] = True
            count += 1
    return count
```

**Шаг 2.** Встроить в `apply_decay` (уже вызывается раз в 24h из `run_daily_maintenance_if_due`):

```python
def apply_decay(config: dict, max_age_days: int = 60) -> int:
    """Existing decay + fast-decay for auto/use_count=0."""
    n_fast = apply_fast_decay(config)
    n_slow = _existing_decay_logic(config, max_age_days)
    return n_fast + n_slow
```

**Шаг 3.** Тесты — `tests/test_apply_decay.py`:
- `test_fast_decay_skips_manual()` — manual+use_count=0+old → НЕ inactive
- `test_fast_decay_skips_correction()` — same
- `test_fast_decay_old_unused_auto()` — auto+use_count=0+age=15d → inactive
- `test_fast_decay_recent_unused()` — auto+use_count=0+age=5d → НЕ inactive
- `test_fast_decay_used_auto()` — auto+use_count=2+age=30d → НЕ inactive (по fast), но slow decay может тронуть
- `test_fast_decay_already_inactive()` — idempotent

**Edge cases:**
- `added_at` отсутствует/невалидный → skip (не помечаем inactive — нет данных судить)
- `use_count` отсутствует (legacy) → considered 0 → подлежит fast decay через 14 дней
- Реактивация: если `update_term_usage` встретит слово → inactive снимется автоматически (это уже работает)

**Definition of Done:**
- Лог `daily maintenance` показывает «fast-decay: deactivated N auto-terms»
- `metrics_history.jsonl` показывает рост `inactive_terms_count` после первого запуска

---

### A5. Конфликт `condition_on_previous_text` vs наш vocab — **P2**

`condition_on_previous_text=True` заставляет Whisper подмешивать предыдущие segments.
Это **дублирует** часть нашей логики с `recent_text` и может вытеснять словарь.

- **Что сделать:** выяснить экспериментально — выключить `condition_on_previous_text` и сравнить edit_score за неделю.
- **Где:** `src/transcriber.py:_call_mlx_transcribe`.
- **Оценка:** 1 день (эксперимент + замеры).

#### План реализации

**Шаг 1. Подготовка к A/B (день 0):**
- Закоммитить текущее значение `condition_on_previous_text=True` (или какое в коде).
- Создать снапшот `metrics_history.jsonl` для baseline: последние 7 дней.

**Шаг 2. Эксперимент (день 1-7):**
- Поменять на `condition_on_previous_text=False` (одним коммитом с тегом `exp/no-cot`).
- Жить неделю с обычным использованием.
- Каждый вечер сохранять `metrics_history.jsonl` в `experiments/cot_off/day_N.jsonl`.

**Шаг 3. Анализ:**
- Сравнить `edit_score_avg` baseline vs experiment.
- Сравнить `hit_rate` baseline vs experiment.
- Субъективное ощущение (есть/нет ухудшение).

**Шаг 4. Решение:**
- Если edit_score ↓ на ≥5% → оставить `False`, закоммитить с обоснованием.
- Если edit_score ↑ или нейтрально → вернуть `True`, занести в `experiments/cot_off/README.md` как «попробовали, не сработало».
- Если результат шумный — продлить ещё на 2 недели или измерить per-сценарий (короткие фразы vs длинные диктовки).

**Дополнительно:** имеет смысл сделать вариант **гибридного** режима — `condition_on_previous_text=True` только для первого чанка
(когда `recent_text` пуст), потом `False`. Это требует minor refactor в `_call_mlx_transcribe` (новый параметр).

**Definition of Done:**
- В `docs/experiments/cot_off.md` записан результат с цифрами и решением
- Код в `main` отражает решение (True/False/гибрид)

---

### A10. Урезание `recent_text` в `process_chunk` — **P1**

В длинной диктовке `recent_text` может занять весь 700-char бюджет, вытеснив vocab.
Идёт в паре с A1.

- **Где:** `src/app.py:1330-1347`.
- **Правило:** `recent_text` ≤ 50% от `_WHISPER_PROMPT_BUDGET` И ≤ 3 последних чанка.
- **Acceptance:** vocab всегда полностью присутствует в context, даже после 10+ чанков.
- **Оценка:** ~30 минут (когда A1 уже сделан).

#### План реализации

Делается в той же функции `_build_chunk_context`, что в A1. Добавить два жёстких предела:

```python
_MAX_RECENT_CHUNKS = 3
_RECENT_CHARS_RATIO = 0.5  # recent_text занимает не более 50% бюджета

def _build_chunk_context(...):
    # ... base + budgets как в A1 ...
    available_chars = min(
        available_chars,
        int(char_budget * _RECENT_CHARS_RATIO),
    )
    parts = list(transcribed_parts[-_MAX_RECENT_CHUNKS:])  # хвост
    recent: list[str] = []
    for chunk in reversed(parts):
        # ... тот же fit-loop ...
```

**Тесты (добавить к A1):**
- `test_recent_text_max_3_chunks()` — 10 чанков, в context влезли только последние 3
- `test_recent_text_max_50pct_budget()` — 1 длинный chunk (500 chars) при бюджете 700 → recent ≤ 350 chars

**Edge cases:**
- `_MAX_RECENT_CHUNKS=0` (если когда-то захотим выключить) → context = base
- chunk сам > 50% бюджета → выкидывается полностью (мы НЕ режем чанк посередине — это уже инвариант)

**Definition of Done:**
- В worst-case сценарии (длинная сессия) `prompt_utilisation` в metrics ≤ 90%

---

## B. UI/UX — диалог с пользователем

### B1. Группировка `SuggestionsPanel` по языкам — **P1**

Сейчас все языки flatten в один список по count. Пользователь не понимает структуру.

- **Где:** `src/suggestions_panel.py:_build_window` (140, 253-264).
- **Что делать:** секции с заголовками `── Русский (8) ──` и `── English (3) ──`,
  кнопка «выбрать всё в секции» для каждой.
- **Acceptance:** скриншот с двумя секциями, чекбоксы независимы.
- **Оценка:** ~3 часа (NSView layout).

#### План реализации

**Шаг 1.** Изменить внутреннее представление `_items` — не плоский список, а dict-by-lang:

```python
# src/suggestions_panel.py
self._items_by_lang: dict[str, list[dict]] = {}  # lang -> sorted items

def show(self, candidates_by_lang, ...):
    self._items_by_lang = {}
    for lang, cands in candidates_by_lang.items():
        sorted_cands = sorted(cands, key=lambda c: -c["count"])
        self._items_by_lang[lang] = [
            {"term": c["term"], "count": c["count"], "lang": lang, "checkbox": None}
            for c in sorted_cands
        ]
```

**Шаг 2.** Языковые имена — добавить в `src/utils.py:UI_STRINGS` или новый `LANG_NAMES`:

```python
LANG_NAMES = {
    "ru": "Русский",
    "en": "English",
    "uk": "Українська",
    "de": "Deutsch",
    ...
}
```

**Шаг 3.** Header-row + section-select buttons. Внутри `_build_window`:

```python
# Iterate languages, render section per language
for lang in sorted(self._items_by_lang.keys()):
    items = self._items_by_lang[lang]
    if not items:
        continue
    # Section header
    header_y = current_y
    lang_name = LANG_NAMES.get(lang, lang.upper())
    header_label = self._make_label(
        f"── {lang_name} ({len(items)}) ──",
        NSRect(NSPoint(8, header_y), NSSize(list_w - 100, _ROW_H)),
        font_size=13.0,
        bold=True,
    )
    doc.addSubview_(header_label)
    # Per-section select-all
    sel_btn = self._make_button(
        "✓ all", header_y, list_w - 90, 80, height=_ROW_H - 4,
    )
    sel_btn.setTarget_(self._delegate)
    sel_btn.setAction_(f"selectSection_{lang}:")
    doc.addSubview_(sel_btn)
    current_y += _ROW_H
    # Items in section
    for item in items:
        # ... existing checkbox+badge rendering ...
        current_y += _ROW_H
```

**Шаг 4.** ObjC actions для per-section select — динамика через `responds_to_selector`:

Проще: один общий action `selectSection:` который читает `sender.tag()` (NSButton.tag хранит index секции).

```python
sel_btn.setTag_(section_index)  # section_index = list(self._items_by_lang.keys()).index(lang)
sel_btn.setAction_("selectSection:")

# в _PanelDelegate:
def selectSection_(self, sender):
    if self._owner:
        self._owner._do_select_section(sender.tag())
```

**Шаг 5.** `_do_select_section(idx)` — выставить чекбоксы только секции `idx`.

**Шаг 6.** `_do_accept` обновить — теперь обходим `_items_by_lang.values()`:

```python
def _do_accept(self):
    accepted, rejected = [], []
    for lang_items in self._items_by_lang.values():
        for item in lang_items[:self._visible_count]:  # pagination by total
            ...
```

**Шаг 7.** Тесты — частично визуальные, но логику можно покрыть:
- `test_items_grouped_by_lang()` — show с 2 языками → `_items_by_lang` имеет 2 ключа
- `test_section_select_only_one_lang()` — `_do_select_section(0)` отмечает только первую секцию

**Edge cases:**
- 1 язык → header всё равно показывать (для консистентности) или скрыть (для минимализма) — **скрывать**
- Языки больше 3 → высота окна растёт; cap по `_MAX_SCREEN_H_RATIO=0.85` уже есть
- Pagination через «Показать ещё» — теперь должна работать **в пределах языка**, иначе сложно. Альтернатива: pagination по общему списку, секции рендерятся «как есть» в pageе. **Решение:** оставить pagination глобальной по count desc, но физически рендерить с заголовками — это компромисс между UX и сложностью.

**Definition of Done:**
- Скриншот в `docs/screenshots/suggestions_panel_grouped.png`
- При смешанных RU+EN кандидатах виден явный разрыв и метка языка

---

### B2. Объясняющая строка в шапке `SuggestionsPanel` — **P1**

Одна строка курсивом: *«Эти слова часто встречаются в ваших фразах.
Если добавить — Whisper будет лучше их слышать. Можно удалить позже в Manage Terms.»*

- **Где:** `src/suggestions_panel.py:_build_window` (218-222).
- **Оценка:** ~15 минут.

#### План реализации

**Шаг 1.** В `UI_STRINGS` добавить ключ `suggestions_panel_help`.

**Шаг 2.** В `_build_window` (после description label):

```python
help_text = UI_STRINGS["suggestions_panel_help"]
help_label = self._make_label(
    help_text,
    NSRect(NSPoint(_MARGIN, label_y - _HELP_H), NSSize(_WIN_W - 2*_MARGIN, _HELP_H)),
    font_size=11.0,
    secondary=True,  # серый цвет
    italic=True,     # добавить параметр italic в _make_label
)
content.addSubview_(help_label)
```

**Шаг 3.** Расширить `_make_label` параметром `italic: bool = False`:

```python
if italic:
    label.setFont_(NSFont.fontWithName_size_("HelveticaNeue-Italic", font_size)
                    or NSFont.systemFontOfSize_(font_size))
```

**Шаг 4.** Подкорректировать высоту окна: `_HELP_H = 32`, прибавить к `fixed_h`.

**Definition of Done:**
- Видна объясняющая строка над списком
- Текст не обрезается на стандартной ширине окна (480px)

---

### B3. Toast после ⌘D «Add to Dictionary» — **P1**

Сейчас добавление молча. Показать в попапе на 2 секунды:
*«„Whisper" добавлено в English словарь»* (язык — после N1+C1).

- **Где:** `src/preview_panel.py:DictionaryAwareTextView` (добавить вызов update_status).
- **Acceptance:** toast виден ~2 сек, не мешает редактированию.
- **Оценка:** ~1 час.

#### План реализации

**Шаг 1.** В `DictionaryAwareTextView` (метод `addToDictionary_`) после успешного `add_term_to_user_terms`:

```python
def _show_toast(self, term: str, lang: str) -> None:
    lang_name = LANG_NAMES.get(lang, lang.upper())
    msg = f"„{term}" → словарь {lang_name}"
    self._panel.update_status(msg, self._main_queue)  # update_status уже thread-safe
    # Автоскрытие через 2с
    self._panel.schedule_status_clear(2.0)
```

**Шаг 2.** `TranscriptionPreviewPanel.schedule_status_clear(seconds)` — новый метод:

```python
def schedule_status_clear(self, seconds: float) -> None:
    """Clear status label after N seconds. Cancels previous schedule."""
    if self._status_clear_timer:
        self._status_clear_timer.invalidate()
    self._status_clear_timer = NSTimer.scheduledTimerWithTimeInterval_repeats_block_(
        seconds, False, lambda t: self.update_status("", self._main_queue),
    )
```

**Шаг 3.** Хранить `_status_clear_timer` в `__init__`, инвалидировать при `close()`.

**Шаг 4.** Тестировать вручную: ⌘D → видим toast → через 2с он исчезает.

**Edge cases:**
- Если пользователь сразу набирает текст после ⌘D — status не должен моргать; либо ставим status только если он сейчас пуст.
- Если несколько ⌘D подряд (5 терминов) — последний toast перебивает; OK.

**Definition of Done:**
- Видимый feedback после ⌘D на 2 секунды
- Status автоматически чистится

---

### B4. Manage Terms — вкладки/секции по языкам с `use_count` — **P1**

Сейчас Manage Terms показывает только общий счётчик + кнопку «удалить inactive».
Нужен табличный вид: term / source / use_count / last_seen / [✕].

- **Где:** `src/menu_bar.py:_show_manage_terms` или новая `terms_panel.py`.
- **Acceptance:** видны все термины, можно удалить руками, сортируется по use_count.
- **Оценка:** ~1 день (новая NSWindow с tableview).

#### План реализации

**Шаг 1.** Новый файл `src/terms_panel.py` — `TermsPanel` (по образцу `SuggestionsPanel`, но с `NSTableView`).

**Шаг 2.** Структура окна:
- Header: сегментированный контрол выбора языка (`NSSegmentedControl` с `[Все] [RU 8] [EN 19]`)
- Body: `NSScrollView` с `NSTableView` — колонки:
  - Term (250px)
  - Source (80px, цветной badge: manual=зелёный, correction=жёлтый, auto=синий)
  - Use count (60px, right-aligned)
  - Last seen (100px, формат "5d ago")
  - Status (40px, ⛔ = inactive, иначе пусто)
  - Actions (60px, "✕" delete button)
- Footer:
  - Кнопка «Удалить выбранные (N)»
  - Кнопка «Удалить inactive (M)»
  - Total: «Всего: 27 активных / 3 неактивных»

**Шаг 3.** Datasource:

```python
# src/terms_panel.py
class _TermsTableDataSource(NSObject):
    def init(self):
        ...
        self._rows: list[tuple[str, dict]] = []  # (lang, item)
        return self

    def setRows_(self, rows): self._rows = rows
    def numberOfRowsInTableView_(self, tv): return len(self._rows)

    def tableView_objectValueForTableColumn_row_(self, tv, col, row):
        lang, item = self._rows[row]
        cid = col.identifier()
        if cid == "term": return item.get("term", "")
        if cid == "source": return item.get("source", "manual")
        if cid == "use_count": return item.get("use_count", 0)
        if cid == "last_seen": return _format_relative(item.get("last_seen"))
        if cid == "status": return "⛔" if item.get("inactive") else ""
        return ""
```

**Шаг 4.** Action handlers:
- `deleteSelected_:` — собрать selected rows, спросить confirm NSAlert, удалить из `config["user_terms"][lang]`, перестроить prompt, sync .txt.
- `deleteInactive_:` — то же, но фильтр `inactive=True`.

**Шаг 5.** Sorting — `NSTableView` поддерживает sortDescriptors из коробки. Сделать sortable все колонки.

**Шаг 6.** Интеграция в меню: в `src/menu_bar.py` заменить вызов `_show_manage_terms` на открытие новой `TermsPanel`.

**Шаг 7.** Тесты:
- `test_terms_panel_loads_all_langs()` — конфиг с 2 языками → видны все термины
- `test_delete_one_term()` — удаление одного → config обновился + .txt пересинхрился

**Edge cases:**
- 100+ терминов — NSTableView и так хорошо скейлит
- Удаление inactive с use_count > 0 (после реактивации) → не удалять, использовать корректный фильтр `item.get("inactive") is True`
- Двойной клик по строке → in-place edit term — **опционально на v2**, сначала только просмотр + delete

**Definition of Done:**
- TermsPanel открывается, видны все термины с метаданными
- Удаление работает с подтверждением
- Sync с .txt и rebuild prompt после изменений

---

### B5. Карточка эффективности в Statistics — **P1**

Помимо edit_score добавить:
- топ-5 терминов с максимальным hit_rate (раздел «работает»)
- топ-5 терминов с `use_count=0` за 30 дней (раздел «мёртвый груз» + кнопка «удалить»)
- топ-5 `failed_pairs` (раздел «Whisper не понимает»)

- **Где:** `src/menu_bar.py:_show_statistics` (расширить NSAlert или сделать NSWindow).
- **Зависит от:** A2 (per-term tracking).
- **Оценка:** ~3 часа.

#### План реализации

**Шаг 1.** Поскольку информации много, **NSAlert уже мал** — сделать новую `StatisticsPanel` (NSWindow + NSScrollView с разделёнными секциями) либо использовать NSAlert с `setInformativeText_` и большим многострочным текстом.

Прагматичный путь — **multi-line NSAlert** на v1, отдельная панель — на v2.

**Шаг 2.** Вычислительная часть — новые функции в `src/metrics.py`:

```python
def top_helping_terms(dataset_path: Path, limit: int = 5) -> list[dict]:
    """[(term, help_ratio, n_final), ...] sorted by help_ratio desc."""
    in_raw, in_final = Counter(), Counter()
    for rec in _read_dataset_tail(dataset_path, 1000):
        if "vocab_terms_in_raw" not in rec:
            continue
        in_raw.update(rec.get("vocab_terms_in_raw") or [])
        in_final.update(rec.get("vocab_terms_in_final") or [])
    out = []
    for term, n_final in in_final.most_common():
        n_raw = in_raw.get(term, 0)
        ratio = n_raw / n_final if n_final else 0
        out.append({"term": term, "help_ratio": ratio, "n_final": n_final, "n_raw": n_raw})
    out.sort(key=lambda x: -x["help_ratio"])
    return out[:limit]

def dead_weight_terms(config: dict, days: int = 30) -> list[dict]:
    cutoff = datetime.now(UTC) - timedelta(days=days)
    out = []
    for lang, items in (config.get("user_terms") or {}).items():
        for item in items:
            if not isinstance(item, dict): continue
            if item.get("inactive"): continue
            if item.get("use_count", 0) > 0: continue
            added = _parse_iso(item.get("added_at"))
            if added is None or added > cutoff: continue
            out.append({"lang": lang, "term": item["term"], "age_days": (datetime.now(UTC) - added).days})
    out.sort(key=lambda x: -x["age_days"])
    return out
```

**Шаг 3.** Расширить `_show_statistics`:

```python
helping = top_helping_terms(dataset_path)
dead = dead_weight_terms(self.config)
failed = get_top_failed_pairs(corrections_path)
msg = "📊 Статистика словаря\n\n"
msg += _format_basic_metrics(metrics)
msg += "\n\n✅ Работают (Whisper узнаёт сам):\n"
for t in helping:
    msg += f"  • {t['term']:15} {t['help_ratio']:.0%} ({t['n_raw']}/{t['n_final']})\n"
msg += "\n💀 Мёртвый груз (не использовались за 30 дней):\n"
for t in dead[:5]:
    msg += f"  • [{t['lang']}] {t['term']:15} ({t['age_days']}d)\n"
msg += "\n🔴 Whisper не понимает (см. A3):\n"
for fp in failed:
    msg += f"  • „{fp['from']}" → „{fp['to']}" ({fp['count']}×)\n"
```

**Шаг 4.** Кнопки NSAlert: «Закрыть», «Удалить мёртвый груз», «Открыть Replacements…».

**Шаг 5.** Тесты:
- `test_top_helping_terms_empty_dataset()` → []
- `test_top_helping_terms_with_data()` — синтетический dataset, проверка сортировки
- `test_dead_weight_skips_recent()` — added=5d ago, use_count=0 → не в списке

**Edge cases:**
- Старые записи без `vocab_terms_in_raw` пропускаются (получим []) — нужно сообщение «недостаточно данных, нужны новые транскрипции»
- `dataset.jsonl` отсутствует → []
- Терминов в словаре нет → пустые секции, не падать

**Definition of Done:**
- Статистика в одном окне с тремя секциями
- Кнопки работают (удаление мёртвого груза = bulk delete с подтверждением)

---

### B6. Стартовый алерт с примерами по языкам — **P2**

Вместо «6 новых терминов» → «Русский: нейросеть, датасет / English: MLX, Whisper, PCA».

- **Где:** `src/menu_bar.py:_check_pending_suggestions_on_startup` (2412-2460).
- **Оценка:** ~30 минут.

#### План реализации

**Шаг 1.** В существующей функции — пересобрать сообщение с группировкой:

```python
pending = self.config.get("pending_suggestions") or {}
total = sum(len(v) for v in pending.values())
if total == 0:
    return

# Top-3 per lang, sorted by count desc within lang
parts = []
for lang in sorted(pending.keys()):
    items = sorted(pending[lang], key=lambda i: -i["count"])[:3]
    if not items:
        continue
    lang_name = LANG_NAMES.get(lang, lang.upper())
    examples = ", ".join(i["term"] for i in items)
    parts.append(f"  {lang_name}: {examples}")

msg = f"Click-n-speak обнаружил {total} новых терминов:\n\n" + "\n".join(parts)
```

**Шаг 2.** Кнопки остаются те же: «Посмотреть список / Напомнить позже / Авто».

**Шаг 3.** Тесты — preview-style (запустить руками + visual check).

**Definition of Done:**
- Алерт показывает термины по языкам с метками

---

## C. Корректность раскладки по языкам

### C1. Script detection в `add_term_to_user_terms` — **P0**

Сейчас ⌘D пишет термин в `user_terms[primary]` без проверки скрипта.
Латинский термин при русском primary улетает в русский словарь → смешение языков в prompt.

- **Где:** `src/vocab_provider.py:add_term_to_user_terms`.
- **Логика:**
  1. Определить скрипт термина (`utils.get_language_script` по символам).
  2. Найти в `{primary} ∪ additional` язык того же скрипта.
  3. Если нашёлся — добавить туда.
  4. Если не нашёлся (например, latin термин при `primary=ru, additional=[]`) →
     `AskUserQuestion` NSAlert: «Это похоже на English. Добавить в English словарь?»
- **Acceptance:** при `primary=ru, additional=[en]` — латинский термин уходит в `en`.
- **Оценка:** ~2 часа.

#### План реализации

**Шаг 1.** Добавить `detect_term_script(term: str) -> str | None` в `src/utils.py`:

```python
def detect_term_script(term: str) -> str | None:
    """Return 'latin' / 'cyrillic' / None for the dominant script of the term.
    None if no alphabetic chars (digits/punct only) or mixed equally."""
    latin = sum(1 for c in term if c.isalpha() and c.isascii())
    cyrillic = sum(1 for c in term if c.isalpha() and "Ѐ" <= c <= "ӿ")
    if latin == 0 and cyrillic == 0:
        return None
    if latin > cyrillic:
        return "latin"
    if cyrillic > latin:
        return "cyrillic"
    return None
```

**Шаг 2.** Утилита: `_find_lang_for_script(script, primary, additional) -> str | None`:

```python
def find_lang_for_script(
    script: str,
    primary: str,
    additional: list[str],
) -> str | None:
    """Return first lang code matching script, prefer primary."""
    if get_language_script(primary) == script:
        return primary
    for code in additional:
        if get_language_script(code) == script:
            return code
    return None
```

(может уже есть `target_lang_for_script_bucket` — переиспользовать, но изменить семантику на возврат `None` при отсутствии).

**Шаг 3.** Изменить сигнатуру `add_term_to_user_terms`:

```python
def add_term_to_user_terms(
    config: dict,
    term: str,
    source: str = "manual",
    lang: str | None = None,  # явно или auto-detect
) -> tuple[bool, str | None, str | None]:
    """Returns (added, lang_used, error_or_prompt).
    If lang is None — auto-detect by script.
    If no language matches script — returns (False, None, "needs_user_choice:<script>")
    """
    primary = get_primary_language(config)
    additional = list(config.get("additional_languages") or [])
    if lang is None:
        script = detect_term_script(term)
        if script is None:
            lang = primary  # цифры/символы — кладём в primary
        else:
            matched = find_lang_for_script(script, primary, additional)
            if matched is None:
                return (False, None, f"needs_user_choice:{script}")
            lang = matched
    # ... existing add logic ...
    return (True, lang, None)
```

**Шаг 4.** В `preview_panel.DictionaryAwareTextView.addToDictionary_` — обработать responses:

```python
ok, used_lang, err = add_term_to_user_terms(self._app.config, term)
if ok:
    self._show_toast(term, used_lang)  # B3
    return
if err and err.startswith("needs_user_choice:"):
    script = err.split(":", 1)[1]
    self._ask_lang_choice(term, script)
    return
```

**Шаг 5.** `_ask_lang_choice(term, script)` — модальный NSAlert с вариантами:
- «Добавить в [Russian]» (primary)
- «Включить [English] и добавить туда» (suggest enabling additional)
- «Отмена»

**Шаг 6.** Тесты — `tests/test_vocab_provider.py`:
- `test_detect_script_latin()` → "latin"
- `test_detect_script_cyrillic()` → "cyrillic"
- `test_detect_script_mixed_returns_none()` → None
- `test_detect_script_digits_only()` → None
- `test_add_term_auto_routes_to_en()` — `primary=ru, additional=[en]`, term=`Whisper` → в `user_terms[en]`
- `test_add_term_needs_user_choice()` — `primary=ru, additional=[]`, term=`Whisper` → `(False, None, "needs_user_choice:latin")`

**Edge cases:**
- Термин `C++` — alpha=1 latin → script=latin → en
- Термин `123` — no alpha → script=None → fallback primary
- Термин `MCP-сервер` — equal latin+cyrillic → None → fallback primary (или диалог? пока fallback)

**Definition of Done:**
- ⌘D на латинском термине при ru-primary с en в additional → попадает в `user_terms[en]`
- ⌘D на латинском при ru-primary без additional → диалог пользователю
- Тесты зелёные

---

### C2. Fix fallback в `target_lang_for_script_bucket` — **P0**

Если `additional=[]`, всё чужого скрипта молча падает в primary.

- **Где:** `src/utils.py:target_lang_for_script_bucket` (369-386) +
  call site в `src/app.py:_run_prompt_analysis` (843-859).
- **Правило:** если bucket-скрипт не покрыт ни primary, ни additional —
  **не добавлять кандидата** (вернуть `None` или skip). С логом.
- **Acceptance:** unit-тест: `primary=ru, additional=[]`, latin bucket — кандидаты выпадают, не в `user_terms[ru]`.
- **Оценка:** ~1 час.

#### План реализации

**Шаг 1.** Изменить `target_lang_for_script_bucket` (сигнатура остаётся, но возврат может быть `None`):

```python
def target_lang_for_script_bucket(
    script: str,
    primary: str,
    additional: list[str],
) -> str | None:
    if get_language_script(primary) == script:
        return primary
    for code in additional:
        if get_language_script(code) == script:
            return code
    return None  # было: return primary
```

**Шаг 2.** В `_run_prompt_analysis` (`src/app.py:843-859`) — обработать `None`:

```python
remapped: dict[str, list[dict]] = {}
dropped_buckets = []
for bucket, items in candidates.items():
    if bucket in ("latin", "cyrillic"):
        target = target_lang_for_script_bucket(bucket, primary_lang, additional_list)
        if target is None:
            dropped_buckets.append((bucket, len(items)))
            log_info(f"prompt_analysis: dropped {len(items)} {bucket} candidates (no matching language)")
            continue
    else:
        target = bucket if bucket in active_langs else primary_lang
    # ... merge logic ...
if dropped_buckets:
    log_info(f"prompt_analysis dropped buckets: {dropped_buckets}")
```

**Шаг 3.** Все остальные потребители `target_lang_for_script_bucket` — пройтись через grep и проверить:

```bash
grep -rn target_lang_for_script_bucket src/
```

Каждый caller должен обработать `None` (skip or fallback).

**Шаг 4.** Тесты — `tests/test_utils.py`:
- `test_bucket_routing_primary_match()` — `("cyrillic", "ru", [])` → "ru"
- `test_bucket_routing_additional_match()` — `("latin", "ru", ["en"])` → "en"
- `test_bucket_routing_no_match_returns_none()` — `("latin", "ru", [])` → None
- `test_bucket_routing_legacy_calls_dont_crash()` — пройти по всем call-sites

**Edge cases:**
- Старые call-sites, которые ожидают `str` → могут крашнуть на `.lower()` от `None`. Покрываем тестами.
- Юзер с `primary=ru, additional=[]` после фикса перестанет получать английские pending — может удивиться. **Лучше**: дать одну подсказку при первом drop: «Замечены латинские термины в речи. Включить English в дополнительные языки?» (см. N9).

**Definition of Done:**
- `target_lang_for_script_bucket` возвращает `None` при отсутствии match
- Все callers обрабатывают `None`
- Тесты зелёные

---

### C3. Валидация при сохранении словаря через `.txt` — **P2**

В `_watch_prompt_file`: если в `initial_prompt_ru.txt` появляются latin-токены — warning в лог + (опционально) уведомление пользователю.

- **Где:** `src/app.py:_watch_prompt_file`.
- **Оценка:** ~30 минут.

#### План реализации

**Шаг 1.** В `_watch_prompt_file` после парсинга файла:

```python
parsed_terms = [...]  # уже парсится
expected_script = get_language_script(lang)
mismatched = [
    t for t in parsed_terms
    if detect_term_script(t) and detect_term_script(t) != expected_script
]
if mismatched:
    log_warning(f"prompt_{lang}.txt has {len(mismatched)} mismatched-script terms: {mismatched[:5]}")
    # Опционально:
    self._notify(f"⚠️ В словаре {lang} есть термины не того алфавита: {', '.join(mismatched[:3])}")
```

**Шаг 2.** `send_notification` уже есть в `src/utils.py`.

**Шаг 3.** Тест — синтетический: создать `initial_prompt_ru.txt` с латинским термином, проверить что warning в логах.

**Definition of Done:**
- При сохранении `initial_prompt_ru.txt` с латинскими терминами есть warning в лог
- Уведомление пользователю не чаще раза в сессию (throttle)

---

## D. Защита от человеческого фактора

### D1. Жёсткая валидация ручного ввода термина — **P0**

Решает первопричину «Чаще всего я пишу…» в твоём prompt.

- **Где:** `src/vocab_provider.py:_sanitize_term` (есть, но слабый).
- **Правила:**
  - `len(term) ≤ 30 chars`
  - max 3 слова (по пробелам)
  - нет символов `:;!?`
  - auto-trim leading/trailing punctuation (уже делается `canonicalize_term`)
- **Acceptance:** unit-тест: 10 валидных + 10 невалидных входов.
- **Оценка:** ~1 час.

#### План реализации

**Шаг 1.** Новая функция `validate_term_for_dict` в `src/vocab_provider.py`:

```python
_MAX_TERM_LEN = 30
_MAX_TERM_WORDS = 3
_FORBIDDEN_CHARS = set(":;!?\n\t\"'")

def validate_term_for_dict(raw: str) -> tuple[str | None, str | None]:
    """Returns (clean_term, error_message). If clean_term is None — rejected."""
    term = canonicalize_term(raw or "")
    if not term:
        return None, "empty term"
    if len(term) > _MAX_TERM_LEN:
        return None, f"too long (max {_MAX_TERM_LEN} chars)"
    if len(term.split()) > _MAX_TERM_WORDS:
        return None, f"too many words (max {_MAX_TERM_WORDS})"
    if any(c in _FORBIDDEN_CHARS for c in term):
        return None, "contains forbidden punctuation"
    return term, None
```

**Шаг 2.** Использовать в `add_term_to_user_terms` **до** существующей логики:

```python
clean, err = validate_term_for_dict(term)
if not clean:
    log_info(f"rejected term {term!r}: {err}")
    return (False, None, f"validation:{err}")
```

**Шаг 3.** Использовать в `_watch_prompt_file` для каждой строки файла — невалидные **пропускать** с warning'ом.

**Шаг 4.** В UI ⌘D — отображать причину отказа в toast («Слишком длинный термин (max 30)»).

**Шаг 5.** Тесты — `tests/test_vocab_provider.py`:

```python
@pytest.mark.parametrize("term,expected", [
    ("Whisper", ("Whisper", None)),
    ("C++", ("C++", None)),
    ("Node.js", ("Node.js", None)),
    (".NET", (".NET", None)),
    ("code review", ("code review", None)),
    ("", (None, "empty term")),
    ("Чаще всего я пишу в повелительном наклонении", (None, "too long (max 30 chars)")),
    ("один два три четыре", (None, "too many words (max 3)")),
    ("hello: world", (None, "contains forbidden punctuation")),
    ("a"*31, (None, "too long (max 30 chars)")),
])
def test_validate_term(term, expected):
    assert validate_term_for_dict(term) == expected
```

**Edge cases:**
- Юникод-длина vs байт-длина — используем `len(term)` (codepoints, для русского это символы, корректно)
- Дефис как разделитель: `C-Index` — это 1 «слово» по `.split()`. OK.
- Многозначная пунктуация: `,` точно отбрасывается canonicalize, не нужно дублировать

**Definition of Done:**
- Все 10 кейсов в тесте зелёные
- ⌘D с длинным термином показывает понятную ошибку
- `_watch_prompt_file` молча пропускает невалидные строки

---

### D2. Stop-list общих английских слов для auto-кандидатов — **P0**

`Data, Code, API, Large, Mac, Score, HTML, CSV, Production, Science, Scientist, …` не должны
попадать в кандидаты вообще.

- **Где:** новый файл `src/stop_words.py` (frozen set ~200 слов);
  использовать в `src/log_analyzer.py:get_prompt_candidates` (фильтрация перед возвратом).
- **Acceptance:** unit-тест: список из 50 фраз с «Data» 10× — `Data` НЕ в кандидатах.
- **Оценка:** ~2 часа.

#### План реализации

**Шаг 1.** Создать `src/stop_words.py`:

```python
"""Stop-word lists for auto-candidate filtering.

Source: combined top-1000 English by frequency (Google ngram) +
tech-generic terms that consistently produce false-positive candidates.
"""

# Top English common words (subset, lowercase)
EN_COMMON = frozenset({
    "the", "and", "for", "are", "but", "not", "you", "all",
    "can", "had", "her", "was", "one", "our", "out", "day",
    "get", "has", "him", "his", "how", "man", "new", "now",
    "old", "see", "two", "way", "who", "boy", "did", "its",
    "let", "put", "say", "she", "too", "use", "with", "have",
    "this", "that", "from", "they", "know", "want", "been",
    "good", "much", "some", "time", "very", "when", "come",
    "here", "just", "like", "long", "make", "many", "more",
    "such", "take", "than", "them", "well", "were", "your",
    "about", "after", "again", "could", "every", "first",
    "great", "house", "large", "learn", "never", "other",
    "place", "right", "small", "still", "such", "their",
    "there", "these", "thing", "think", "those", "three",
    "where", "which", "while", "world", "would", "write",
    "should", "people", "really", "thought",
})

# Generic tech vocabulary that Whisper handles perfectly and that
# floods auto-candidates without value
TECH_GENERIC = frozenset({
    "api", "url", "html", "css", "json", "xml", "csv", "pdf",
    "code", "data", "score", "test", "file", "user", "name",
    "type", "size", "list", "item", "page", "site", "link",
    "load", "save", "open", "close", "edit", "view", "tool",
    "task", "step", "rate", "rule", "mode", "role", "team",
    "info", "case", "form", "menu", "tab", "log", "auth",
    "post", "get", "put", "del", "key", "val", "id",
    "production", "development", "staging", "build", "deploy",
    "review", "scientist", "engineer", "developer", "designer",
    "research", "science", "analysis", "report", "result",
    "input", "output", "value", "config", "setting", "option",
    "param", "field", "table", "record", "entry", "column",
    "row", "model", "service", "client", "server", "system",
    "process", "thread", "queue", "buffer", "cache", "stream",
    "method", "function", "class", "object", "module", "package",
    "library", "framework", "platform", "tool", "command",
    "flash", "mac", "win", "linux", "apple", "google",
    "microsoft", "amazon", "facebook",
})

EN_STOP = EN_COMMON | TECH_GENERIC

# Russian — кириллические частотные (для симметрии)
RU_STOP = frozenset({
    "это", "что", "как", "так", "его", "она", "они", "был",
    "была", "были", "быть", "есть", "нет", "для", "при",
    "под", "над", "тут", "там", "уже", "ещё", "или",
    "тоже", "если", "когда", "потом", "также", "только",
    # повелительные глаголы — Whisper их знает идеально
    "напиши", "проверь", "посмотри", "проанализируй", "выполни",
    "проведи", "сделай", "удали", "открой", "закрой",
})

ALL_STOP_BY_SCRIPT = {
    "latin": EN_STOP,
    "cyrillic": RU_STOP,
}

def is_stop_word(term: str, script: str | None = None) -> bool:
    """Return True if term should be filtered out from auto-candidates."""
    if not term:
        return True
    t = term.lower().strip()
    if script:
        return t in ALL_STOP_BY_SCRIPT.get(script, frozenset())
    # auto-detect script
    if t in EN_STOP or t in RU_STOP:
        return True
    return False
```

**Шаг 2.** Интегрировать в `src/log_analyzer.py:get_prompt_candidates` (после кандидат-сбора, перед возвратом):

```python
from .stop_words import is_stop_word

# в конце функции
for bucket in list(result.keys()):
    result[bucket] = [
        item for item in result[bucket]
        if not is_stop_word(item["term"], bucket)
    ]
```

**Шаг 3.** Также в `src/correction_analyzer.py:get_correction_candidates` — добавить тот же фильтр.

**Шаг 4.** Тесты — `tests/test_stop_words.py`:
- `test_common_english_stopped()` — "data", "code", "api" → True
- `test_capitalized_stopped()` — "Data", "Code" → True (lowercase)
- `test_niche_not_stopped()` — "Whisper", "XGBoost", "MCP" → False
- `test_russian_imperative_stopped()` — "напиши", "проверь" → True
- `test_log_analyzer_filters_stopwords()` — синтетический log с "Data" 20× → НЕ в кандидатах

**Edge cases:**
- Двойной фильтр (log_analyzer + correction_analyzer + suggestions panel) — OK, дешёвая операция
- Пользователь хочет добавить «code» вручную (manual) — D1 это пропустит (валидно), D2 НЕ применяется к manual
- Список можно расширять — добавить ссылку на сборку из top-frequency English

**Definition of Done:**
- `stop_words.py` создан с ~200 английскими + 30 русскими словами
- Все auto-кандидаты фильтруются
- Manual-ввод НЕ затронут

---

### D5. Унификация регистра при дедупликации — **P2**

Сейчас `MCP` и `mcp` могут существовать как два разных user_term.

- **Где:** `src/utils.py:deduplicate_prompt_terms` + merge-логика в `_apply_candidates_to_user_terms`.
- **Правило:** при merge — оставлять регистр чаще встречающегося варианта.
- **Acceptance:** unit-тест: добавление `mcp` после `MCP` не создаёт второй термин.
- **Оценка:** ~1 час.

#### План реализации

**Шаг 1.** Расширить `_apply_candidates_to_user_terms` (`src/app.py:93-123`) — при добавлении проверять `canonical_term_key`:

```python
existing_by_key = {canonical_term_key(_term_str(i)): i for i in lang_items}
for cand in candidates_for_lang:
    key = canonical_term_key(cand["term"])
    if key in existing_by_key:
        existing = existing_by_key[key]
        # Don't add duplicate. Decide whose casing to keep.
        existing_term = _term_str(existing)
        if cand["count"] > _get_use_count(existing):
            # New candidate is more frequent — adopt its casing
            if isinstance(existing, dict):
                existing["term"] = cand["term"]
        # else: keep existing
        continue
    # ... add new ...
```

**Шаг 2.** То же для `add_term_to_user_terms` (manual путь) — если key уже есть и регистр другой, **оставляем существующий** (manual преимущественно user-typed, мы доверяем).

**Шаг 3.** Тесты:
- `test_add_same_term_different_case_no_duplicate()`
- `test_more_frequent_casing_wins()` — `MCP (count=10)` уже в словаре, приходит `mcp (count=20)` → итог: term="mcp"
- `test_manual_keeps_existing_case()` — пользователь добавляет `mcp` через ⌘D, в словаре есть `MCP` → итог: `MCP`

**Edge cases:**
- Конфликт casing при многих изменениях за сессию → не страшно, на следующем merge нормализуется
- Legacy `list[str]` items — `canonical_term_key` обрабатывает оба формата

**Definition of Done:**
- При повторном auto-detect термина в другом регистре — счётчик растёт, дубликат не появляется

---

## E. Авто-настройка и подсказки

### E5. Повышение порога `auto_prompt_check_min_count_additional` — **P1**

Сейчас 5 — слишком низко. Поднять до 8.

- **Где:** `src/utils.py` дефолты + `src/app.py:_run_prompt_analysis`.
- **Migration:** для существующих конфигов — оставить значение, если пользователь менял; иначе обновить.
- **Оценка:** 15 минут.

#### План реализации

**Шаг 1.** Изменить дефолт в `src/utils.py` (`DEFAULT_CONFIG` или константа):

```python
DEFAULT_AUTO_MIN_COUNT_ADDITIONAL = 8  # было 5
```

**Шаг 2.** Не делать миграцию — если у юзера значение установлено явно, оно сохраняется в `config.json`.
**Однако** — для большинства пользователей значение присутствует со старым дефолтом (5), миграция нужна.

Альтернатива: добавить `migrate_config_to_v7`:

```python
def migrate_config_to_v7(config: dict) -> dict:
    if config.get("schema_version", 0) >= 7:
        return config
    # Только если значение явно 5 (старый дефолт), повысить до 8
    if config.get("auto_prompt_check_min_count_additional") == 5:
        config["auto_prompt_check_min_count_additional"] = 8
    config["schema_version"] = 7
    return config
```

**Шаг 3.** Тест: миграция применяется только к старому дефолту, кастомные значения не трогаются.

**Definition of Done:**
- Новые конфиги: 8
- Существующие конфиги с дефолтом 5: подняты до 8
- Кастомные значения сохранены

---

### E6. Квотирование бюджета prompt по языкам — **P2**

Не больше 60% от 200 токенов одному языку.

- **Где:** `src/utils.py:build_initial_prompt` (799-807).
- **Логика:** разбить budget по языкам пропорционально кол-ву терминов, но не более X% любому.
- **Acceptance:** при 50 EN терминов и 5 RU — EN займёт ≤120 ток., RU гарантированно влезает.
- **Оценка:** ~2 часа.

#### План реализации

**Шаг 1.** Изменить алгоритм в `build_initial_prompt`:

```python
_PER_LANG_BUDGET_CAP = 0.6  # 60% максимум одному языку

def build_initial_prompt(config: dict) -> str:
    primary = get_primary_language(config)
    additional = list(config.get("additional_languages") or [])
    langs = [primary] + [l for l in additional if l != primary]
    # Compute per-lang sorted active terms
    per_lang_sorted = {}
    for lang in langs:
        terms = [_term_str(t) for t in config.get("user_terms", {}).get(lang, []) if _term_is_active(t)]
        terms = sorted(terms, key=lambda t: -_get_use_count_for(t, config, lang))  # уже есть key
        per_lang_sorted[lang] = deduplicate_prompt_terms(terms)

    # Build lang_hint + context as before
    base_prefix = _build_prefix(langs, per_lang_sorted)
    available_tokens = _MAX_PROMPT_TOKENS - _count_prompt_tokens(base_prefix)
    cap_tokens = int(available_tokens * _PER_LANG_BUDGET_CAP)

    # First pass: each lang gets up to cap_tokens
    chosen: dict[str, list[str]] = {}
    used_per_lang: dict[str, int] = {l: 0 for l in langs}
    for lang in langs:
        chosen[lang] = []
        for term in per_lang_sorted[lang]:
            fragment = (", " if any(chosen.values()) or chosen[lang] else "") + term
            cost = _count_prompt_tokens(fragment)
            if used_per_lang[lang] + cost > cap_tokens:
                break
            chosen[lang].append(term)
            used_per_lang[lang] += cost

    # Second pass: distribute leftover tokens by leftover candidates
    total_used = sum(used_per_lang.values())
    leftover = available_tokens - total_used
    while leftover > 0:
        added = False
        for lang in langs:
            consumed = len(chosen[lang])
            if consumed >= len(per_lang_sorted[lang]):
                continue
            next_term = per_lang_sorted[lang][consumed]
            cost = _count_prompt_tokens(", " + next_term)
            if cost > leftover:
                continue
            chosen[lang].append(next_term)
            leftover -= cost
            added = True
        if not added:
            break

    all_terms = [t for lang in langs for t in chosen[lang]]
    return base_prefix + (", ".join(all_terms) if all_terms else "")
```

**Шаг 2.** Тесты — `tests/test_build_prompt_quotas.py`:
- `test_one_lang_no_quota()` — 1 язык, 50 терминов → все, что влезли (квота не применяется)
- `test_two_langs_quota_respected()` — `ru=5 terms, en=50 terms`, проверить что EN ≤ 60%, RU полностью
- `test_three_langs_quota()` — `ru=20, en=20, de=20` → распределение примерно 33% каждому
- `test_quota_with_leftovers()` — если RU занял 20%, EN может занять до 80% (leftover redistribution)

**Edge cases:**
- 1 язык — квота не применяется (60% от 100% = 60%, но мы хотим использовать всё)
- Очень короткий primary словарь (например 2 термина) — обходим квоту во второй проходке

**Definition of Done:**
- При неравных словарях каждый язык получает гарантированную долю
- Свободные токены раздаются по запросу

---

### E7. Усиление Gemini-канала через `collect_misrecognitions` — **P1**

У Gemini нет 224-токенного лимита, передавать ему гораздо больше пар.

- **Где:** `src/vocab_provider.py:collect_misrecognitions`.
- **Что:** снизить порог `count ≥ 3` → `count ≥ 2` для Gemini-канала; добавить top-N=50 (вместо текущего лимита).
- **Acceptance:** в Gemini system prompt видны все пары с count ≥ 2 за 60 дней.
- **Оценка:** ~1 час.

#### План реализации

**Шаг 1.** Расширить сигнатуру `collect_misrecognitions`:

```python
def collect_misrecognitions(
    corrections_path: Path,
    *,
    min_count: int = 3,
    max_pairs: int = 20,
    lookback_days: int = 60,
) -> list[tuple[str, str]]:
    ...
```

**Шаг 2.** В `ExternalApiEditor.refine` (или `GeminiEditor`) — позвать с увеличенными лимитами:

```python
misrec = collect_misrecognitions(
    corrections_path(),
    min_count=2,      # было 3
    max_pairs=50,     # было ~20
    lookback_days=60,
)
```

**Шаг 3.** Проверить размер итогового system prompt. У Gemini Flash 2.5 — input context до 1M токенов, не проблема.

**Шаг 4.** Тесты:
- `test_collect_misrec_lower_threshold()`
- `test_collect_misrec_cap_max_pairs()`

**Edge cases:**
- В corrections.json пар нет → пустой list (уже обрабатывается)
- Пользователь использует **локальный Qwen**, а не Gemini — там лимит контекста 32K, текущие настройки (3/20) подходят

**Definition of Done:**
- Gemini получает больше пар → меньше «оставшихся» misrecognitions в metrics

---

### N7. Единый knob чувствительности словаря — **P2**

Заменить 3 параметра на `dictionary_sensitivity: low | medium | high`.

- **Mapping:**
  - low: `min_count_primary=15, min_count_additional=10, check_interval=30`
  - medium (default): `10/8/20`
  - high: `5/3/10`
- **Где:** `src/menu_bar.py` (новый submenu); `src/utils.py` (миграция).
- **Acceptance:** меню «Настройки → Чувствительность словаря».
- **Оценка:** ~3 часа.

#### План реализации

**Шаг 1.** Добавить mapping в `src/utils.py`:

```python
SENSITIVITY_PRESETS = {
    "low": {
        "auto_prompt_check_min_count_primary": 15,
        "auto_prompt_check_min_count_additional": 10,
        "auto_prompt_check_interval": 30,
    },
    "medium": {
        "auto_prompt_check_min_count_primary": 10,
        "auto_prompt_check_min_count_additional": 8,
        "auto_prompt_check_interval": 20,
    },
    "high": {
        "auto_prompt_check_min_count_primary": 5,
        "auto_prompt_check_min_count_additional": 3,
        "auto_prompt_check_interval": 10,
    },
}

def apply_sensitivity_preset(config: dict, preset: str) -> None:
    if preset not in SENSITIVITY_PRESETS:
        return
    config["dictionary_sensitivity"] = preset
    config.update(SENSITIVITY_PRESETS[preset])
```

**Шаг 2.** Submenu в `src/menu_bar.py` — Initial Prompt → Sensitivity → [Low | Medium | High], галочка у текущего.

**Шаг 3.** При выборе:

```python
def _on_sensitivity_change(self, level: str):
    apply_sensitivity_preset(self._app.config, level)
    save_config_to_disk(self._app.config)
    self._refresh_sensitivity_submenu()
    send_notification(f"Чувствительность словаря: {level}")
```

**Шаг 4.** Миграция: при загрузке конфига без `dictionary_sensitivity` — определить по текущим значениям (`medium`, если соответствуют), иначе `custom` (без preset).

**Шаг 5.** Если пользователь руками меняет один из 3 параметров → `dictionary_sensitivity = "custom"`, галочка снимается со всех presetов.

**Тесты:**
- `test_apply_preset_updates_config()`
- `test_custom_detection()`

**Edge cases:**
- Юзер выставил preset, потом отредактировал значения вручную — переключаем на `custom`
- Migration: смотреть точное совпадение всех трёх значений с известным presetом

**Definition of Done:**
- Меню «Чувствительность» работает
- Сохраняется выбор
- При custom-значениях preset не «фальшиво» подсвечен

---

## F. Диагностика и наблюдаемость

### N3. UI-петля для `failed_pairs`

См. **A3** — это перекрёстная ссылка, реализуется там.

---

### N4. Highlight low-confidence слов в попапе — **P2**

Whisper возвращает per-segment `avg_logprob` и `no_speech_prob`.
Подсветить слова с `avg_logprob < -0.7` жёлтым в попапе.

- **Где:** `src/transcriber.py` (вернуть segments вместо просто text);
  `src/preview_panel.py:append_text` (подсветка).
- **Acceptance:** диктуем фразу с нишевым словом — оно подсвечено.
- **Оценка:** ~1 день (изменение API transcriber + UI).

#### План реализации

**Шаг 1.** Изменить return type `WhisperTranscriber.transcribe` (`src/transcriber.py`):

```python
@dataclass
class TranscribeResult:
    text: str
    language: str | None
    segments: list[dict]  # raw segments from mlx_whisper
    low_confidence_spans: list[tuple[int, int]]  # (start_char, end_char) in `text`

def transcribe(...) -> TranscribeResult:
    raw = mlx_whisper.transcribe(...)
    text = raw["text"]
    segments = raw.get("segments", [])
    spans = []
    cursor = 0
    for seg in segments:
        seg_text = seg.get("text", "")
        start = text.find(seg_text, cursor)
        if start < 0:
            continue
        end = start + len(seg_text)
        if seg.get("avg_logprob", 0) < -0.7:
            spans.append((start, end))
        cursor = end
    return TranscribeResult(text=text, language=raw.get("language"), segments=segments, low_confidence_spans=spans)
```

**Шаг 2.** Обновить **все** call-sites — `process_chunk` теперь принимает `TranscribeResult`:

```python
result = self.transcriber.transcribe(audio_chunk, ...)
text = result.text
# использовать result.language для A2, result.low_confidence_spans для UI
```

**Шаг 3.** `preview_panel.append_text` — добавить параметр `low_confidence_spans`:

```python
def append_text(self, text: str, low_conf_spans: list[tuple[int, int]] | None = None):
    if low_conf_spans:
        attr_str = NSMutableAttributedString.alloc().initWithString_(text)
        for start, end in low_conf_spans:
            attr_str.addAttribute_value_range_(
                NSBackgroundColorAttributeName,
                NSColor.systemYellowColor().colorWithAlphaComponent_(0.3),
                NSMakeRange(start, end - start),
            )
        self._text_view.textStorage().appendAttributedString_(attr_str)
    else:
        self._text_view.textStorage().mutableString().appendString_(text)
```

**Шаг 4.** UX: при редактировании text view подсветка может смущать — **снимать подсветку при первом keystroke** (NSTextViewDidChangeNotification).

**Шаг 5.** Тесты:
- `test_low_confidence_detection()` — мок segments с logprob=-1.0 → spans непустые
- `test_no_segments_no_spans()` — пустой segments → spans=[]
- Manual UI test — диктуем «MCP», смотрим подсветку

**Edge cases:**
- mlx_whisper может НЕ возвращать segments при некоторых параметрах — проверить, fallback на text-only без подсветки
- Span overlap при дубликате текста (рестрим того же слова) — `find` берёт первое вхождение, OK

**Definition of Done:**
- Низкоуверенные слова видимо подсвечены жёлтым
- Подсветка снимается при правке
- Прежний UX без подсветки сохраняется как fallback

---

### N5. «Whisper думал…» toggle в попапе — **P2**

Кнопка «показать сырое распознавание» — раскрывает `raw_whisper` под `ai_edited`.
Диагностический инструмент: если правка совпадает с raw — Gemini испортил.

- **Где:** `src/preview_panel.py` (раскрывающаяся секция).
- **Зависит от:** preview_panel должен иметь доступ к raw_whisper (сейчас только ai_edited).
- **Оценка:** ~3 часа.

#### План реализации

**Шаг 1.** Передать `raw_whisper` в `show_interactive`:

```python
# src/preview_panel.py
def show_interactive(
    self,
    text: str,
    raw_whisper: str | None = None,
    on_confirm: Callable | None = None,
    on_cancel: Callable | None = None,
):
    self._raw_whisper = raw_whisper or ""
    # ... existing rendering ...
```

**Шаг 2.** Добавить кнопку-disclosure внизу попапа:

```python
self._raw_toggle_btn = NSButton.alloc().initWithFrame_(...)
self._raw_toggle_btn.setTitle_("▸ Whisper думал…")
self._raw_toggle_btn.setBezelStyle_(15)  # transparent recessed
self._raw_toggle_btn.setTarget_(self._delegate)
self._raw_toggle_btn.setAction_("toggleRaw:")
```

**Шаг 3.** При клике — показать non-editable serif-style label под текстом:

```python
def _toggle_raw(self):
    self._raw_visible = not self._raw_visible
    if self._raw_visible:
        self._raw_toggle_btn.setTitle_("▾ Whisper думал…")
        # Resize panel, add raw label
        self._raw_label.setStringValue_(self._raw_whisper)
        self._raw_label.setHidden_(False)
        # Resize window
    else:
        self._raw_toggle_btn.setTitle_("▸ Whisper думал…")
        self._raw_label.setHidden_(True)
```

**Шаг 4.** Стиль raw_label — серый, italic, меньший шрифт, без bg → визуально вторичен.

**Шаг 5.** Тесты — manual UI:
- Диктуем фразу
- Жмём «Whisper думал…» → видим raw_whisper
- Закрываем → label скрыт

**Edge cases:**
- `raw_whisper == ai_edited` (AI ничего не менял) — кнопка серая или disabled с tooltip «AI ничего не менял»
- Очень длинный raw — лимит на 2 строки, дальше «…»

**Definition of Done:**
- Toggle работает, raw_whisper виден по запросу
- Размер окна корректно меняется

---

### N6. `prompt_hash` в каждой записи dataset

Включено в **A2**. Перекрёстная ссылка, отдельной реализации нет.

---

### N11. Self-test через эталонное аудио — **P3**

В bundle 3 коротких .wav (рус + англ + смешанный) с известным reference text.
Меню «Запустить тест» — прогон, diff, оценка `edit_score`.

- **Где:** новый `src/self_test.py`, `tests/fixtures/`.
- **Полезно:** после правки словаря — проверить «не сломал ли».
- **Оценка:** ~4 часа.

#### План реализации

**Шаг 1.** Подготовить fixture-аудио (один раз):
- `tests/fixtures/audio/ru_short.wav` (~5 сек, 16kHz mono)
- `tests/fixtures/audio/en_tech.wav` (нишевые термины: MCP, XGBoost, Whisper)
- `tests/fixtures/audio/mixed.wav` (русский + английские термины)
- Для каждого — `*.txt` с reference text.

Записать руками или взять из public dataset (CC0).

**Шаг 2.** `src/self_test.py`:

```python
from pathlib import Path
import numpy as np
import soundfile as sf
from .transcriber import TranscriberProcessWrapper
from .metrics import _edit_score_char

FIXTURES = Path(__file__).parent.parent / "tests" / "fixtures" / "audio"

def run_self_test(transcriber: TranscriberProcessWrapper, initial_prompt: str) -> list[dict]:
    results = []
    for wav in sorted(FIXTURES.glob("*.wav")):
        ref_path = wav.with_suffix(".txt")
        if not ref_path.exists():
            continue
        reference = ref_path.read_text().strip()
        audio, sr = sf.read(wav, dtype="float32")
        assert sr == 16000
        result = transcriber.transcribe(audio, initial_prompt=initial_prompt, allowed_languages=None)
        text = result.text if hasattr(result, "text") else result
        edit = _edit_score_char(text, reference)
        results.append({
            "name": wav.stem,
            "ref": reference,
            "got": text,
            "edit_score": edit,
        })
    return results
```

**Шаг 3.** Меню в `src/menu_bar.py`: «Initial Prompt → Self-Test → запустить»:

```python
def _on_self_test(self, _):
    results = run_self_test(self._app.transcriber, self._app.config.get("initial_prompt", ""))
    msg = "Результат самотеста:\n\n"
    for r in results:
        marker = "✅" if r["edit_score"] < 0.05 else "⚠️" if r["edit_score"] < 0.2 else "❌"
        msg += f"{marker} {r['name']}: edit={r['edit_score']:.1%}\n"
        if r["edit_score"] > 0.05:
            msg += f"   ref: {r['ref'][:60]}\n   got: {r['got'][:60]}\n"
    rumps.alert("Self-Test", msg)
```

**Шаг 4.** Запись fixture аудио — отдельный скрипт `scripts/record_fixtures.py`:
- Используем тот же `recorder.py`
- Сохраняем wav и просим юзера ввести reference text

**Шаг 5.** Тесты:
- Сам self-test НЕ запускается в CI (нужны wav-файлы и реальный модель). Помечать `@pytest.mark.integration`.

**Edge cases:**
- Аудио в bundle растёт по размеру — держать каждый файл ≤ 200 KB
- Тест блокирует UI на ~10 сек — показать spinner
- В .app bundle добавить fixtures в Resources/

**Definition of Done:**
- Меню «Self-Test» работает
- 3 fixture-аудио в репо
- После правки словаря можно нажать одну кнопку и увидеть качество

---

## N8. Drift-алерт для pending_suggestions — **P3**

Если за неделю pending вырос на 30+, а acceptance_rate < 20% — уведомление.

- **Где:** `src/metrics.py` + `src/app.py:run_metrics_if_due`.
- **Оценка:** ~2 часа.

#### План реализации

**Шаг 1.** В `src/metrics.py` — новая функция `detect_drift`:

```python
def detect_drift(
    history: list[dict],
    pending_delta_threshold: int = 30,
    acceptance_rate_threshold: float = 0.2,
    window_days: int = 7,
) -> dict | None:
    if len(history) < 2:
        return None
    now = datetime.now(UTC)
    week_ago = now - timedelta(days=window_days)
    last = history[-1]
    prev = next((h for h in reversed(history[:-1]) if _parse_iso(h.get("ts")) < week_ago), None)
    if prev is None:
        return None
    delta_pending = last.get("pending_now", 0) - prev.get("pending_now", 0)
    rate = last.get("acceptance_rate") or 0
    if delta_pending >= pending_delta_threshold and rate < acceptance_rate_threshold:
        return {
            "delta_pending": delta_pending,
            "acceptance_rate": rate,
            "advice": "Consider lowering dictionary_sensitivity to 'low'",
        }
    return None
```

**Шаг 2.** В `run_metrics_if_due` после `append_metrics_history` — проверить drift:

```python
history = load_metrics_history(history_path)
drift = detect_drift(history)
if drift:
    self._maybe_notify_drift(drift)
```

**Шаг 3.** Throttle уведомления через `last_drift_notification_ts` в config (раз в 14 дней).

**Шаг 4.** Тесты:
- `test_no_drift_in_short_history()`
- `test_drift_detected()` — две точки с разницей в pending=50, acceptance=0.1 → результат не None
- `test_no_drift_when_acceptance_high()`

**Definition of Done:**
- При drift'е раз в 2 недели появляется уведомление с советом

---

## N9. Авто-совет про `additional_language` — **P3**

Если в последних 100 фразах ≥30% токенов чужого скрипта, а соответствующий язык не в additional — предложить.

- **Где:** `src/app.py` (новая периодическая проверка) + `src/utils.py:get_language_script`.
- **Оценка:** ~2 часа.

#### План реализации

**Шаг 1.** Функция в `src/log_analyzer.py`:

```python
def script_distribution(phrases: list[str]) -> dict[str, float]:
    """Return {'latin': 0.4, 'cyrillic': 0.6} based on alphabetic chars."""
    cnt = {"latin": 0, "cyrillic": 0}
    for ph in phrases:
        for c in ph:
            if c.isalpha():
                if c.isascii():
                    cnt["latin"] += 1
                elif "Ѐ" <= c <= "ӿ":
                    cnt["cyrillic"] += 1
    total = sum(cnt.values()) or 1
    return {k: v / total for k, v in cnt.items()}
```

**Шаг 2.** В `run_daily_maintenance_if_due` (`src/app.py`):

```python
def _check_additional_lang_suggestion(self):
    last_suggested = self.config.get("last_additional_lang_suggestion_ts")
    if last_suggested and _days_since(last_suggested) < 30:
        return
    phrases = get_last_phrases(100)
    dist = script_distribution(phrases)
    primary_script = get_language_script(get_primary_language(self.config))
    other_script = "cyrillic" if primary_script == "latin" else "latin"
    if dist.get(other_script, 0) < 0.3:
        return
    suggested_lang = "en" if other_script == "latin" else "ru"
    if suggested_lang in (self.config.get("additional_languages") or []):
        return
    self._submit_for_main_thread(
        send_notification,
        f"В речи замечен {other_script} текст ({dist[other_script]:.0%}). "
        f"Включить {suggested_lang.upper()} в дополнительные языки?"
    )
    self.config["last_additional_lang_suggestion_ts"] = datetime.now(UTC).isoformat()
```

**Шаг 3.** Тесты:
- `test_script_distribution_pure_latin()`
- `test_no_suggestion_below_threshold()`
- `test_suggestion_throttled_30_days()`

**Edge cases:**
- Пользователь явно отклонил предложение — нужно сохранить «не показывать снова». Добавить отдельный флаг `additional_lang_suggestion_dismissed`.

**Definition of Done:**
- Уведомление приходит раз в 30 дней при наличии сильного сигнала
- Throttle работает

---

## Рекомендуемый порядок выполнения

### Спринт 1 — фиксы и базовая корректность (2-3 дня)

1. **D1** — валидация ручного ввода (1ч) — устраняет основной источник мусора.
2. **C1+C2** — script detection и fallback fix (3ч) — фиксит молчаливый баг.
3. **A1+A10** — token budget control + урезание recent_text (1.5ч) — гарантирует что vocab долетает.
4. **D2** — stop-list для auto (2ч) — обнуляет 80% мусорных кандидатов.
5. **A4** — агрессивный decay (1ч) — чистит auto-термины с use_count=0.
6. **E5** — поднять порог auto до 8 (15м).

**Итого:** ~9 часов, ноль внешних зависимостей, ноль UI-сложности.

### Спринт 2 — измерение эффективности (2 дня)

7. **A2 + N6** — per-term tracking + prompt_hash в dataset (3ч).
8. **B5** — карточка эффективности в Statistics (3ч).
9. **A3 / N3** — failed_pairs как активный сигнал (2ч).

**Итого:** ~8 часов. После этого спринта у нас появляются **факты** вместо догадок.

### Спринт 3 — UX (3 дня)

10. **B1+B2** — группировка SuggestionsPanel + объясняющая строка (3.5ч).
11. **B3** — toast после ⌘D (1ч).
12. **B4** — Manage Terms tableview (1д).
13. **B6** — стартовый алерт с языками (30м).

### Спринт 4 — опциональные улучшения

14. **E7** — усиление Gemini-канала (1ч).
15. **E6** — квотирование бюджета (2ч).
16. **N7** — knob чувствительности (3ч).
17. **A5** — эксперимент с `condition_on_previous_text` (1д).
18. **D5** — унификация регистра (1ч).
19. **N4 / N5** — confidence highlight, raw_whisper toggle (1.5д).
20. **N8 / N9 / N11** — drift-алерт, lang-совет, self-test (1д).
21. **C3** — валидация .txt при сохранении (30м).

---

## Что НЕ делаем (рассмотрено и отброшено)

- **Re-transcribe старого аудио с новым словарём.** Аудио не сохраняется (privacy + disk).
  Без аудио невозможно — Whisper нельзя «переиграть» только из текста.
- **Режимы словарей (контексты «код-ревью / медицина / переписка»).** Сложно и преждевременно.
  Сначала научимся мерить эффект простого глобального словаря.
- **Глобальный refactor `ai_editor.py` для уравнивания Qwen и Gemini API.** Локальный Qwen
  слабый и редко используется на практике. Оптимизировать его vocab-канал — не приоритет.

---

## Метрики успеха

После выполнения спринтов 1-2 ожидаем (наблюдать в `metrics_history.jsonl`):

- `edit_score_avg` — снижение на 10-15% (за счёт чистки prompt и устранения молчаливых багов).
- `hit_rate` — рост (за счёт script detection: термины попадают в правильный язык).
- `prompt_tokens_used / 200` — снижение до 50-60% (за счёт A4 + D2 + ручной чистки).
- `failed_pairs_count` — снижение (за счёт A3: пользователь активно решает повторяющиеся ошибки).
- `acceptance_rate` для auto-кандидатов — рост до >50% (за счёт D2 stop-list).

---

## Заметки для исполнителя

- **Тесты:** все unit-тесты — pytest в `tests/`. Перед запуском: `source venv/bin/activate`.
- **Миграции:** при изменении schema `config.json` — повышать `schema_version` и писать `migrate_config_to_vN`.
- **Сохранение конфига:** только через `save_config_to_disk` (атомарная запись).
- **UI-операции:** только через `_submit_for_main_thread` из worker-потоков.
- **Логирование:** `log_info / log_warning / log_error` из `src/utils.py`, не `print`.
- **Hot-reload prompt:** при правке `user_terms` всегда вызывать `build_initial_prompt(config)` и
  обновлять `config["initial_prompt"]`, чтобы следующий чанк подхватил.
