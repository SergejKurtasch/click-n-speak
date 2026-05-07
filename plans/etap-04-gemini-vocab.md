# Этап 4 — Передача словаря в Gemini (но не в Qwen)

## Цель

Сейчас Whisper знает про термины пользователя (через `initial_prompt`), но **AI editor не знает**. Это значит:

- Whisper правильно распознал «GitHub» → Gemini может «исправить» на «гитхаб» или «git hub», если решит, что это опечатка.
- Whisper неправильно распознал «питон» → Gemini тоже видит «питон» и пропускает; правильный «Python» так и не появится.

Передача словаря в Gemini решает обе проблемы. **Qwen 1.5B 4-bit мы не трогаем** — слабая модель легко начнёт навязывать словарные слова там, где их не было (галлюцинации в духе «вставлю PCA сюда, чтобы понравиться промпту»).

После этапа: Gemini защищает корректно распознанные термины + чинит частые ошибки распознавания, изученные из правок пользователя (этап 1).

---

## Что есть сейчас

`src/ai_editor.py:_build_system_prompt(languages)` — единый системный промпт для **обоих** редакторов (`AiEditor` локальный + `GeminiEditor`). Содержит только инструкции по пунктуации/филлерам, никаких терминов.

`GeminiEditor.refine()` (`src/ai_editor.py:658`) вызывает `_call_gemini` с тем же `_build_system_prompt`. Без знания о словаре.

---

## Что меняем

### Новая функция `_build_gemini_system_prompt`

Отдельная от локальной (которая остаётся прежней — Qwen не трогаем).

```python
def _build_gemini_system_prompt(
    languages: list[str] | None = None,
    known_terms: list[str] | None = None,
    misrecognitions: list[tuple[str, str]] | None = None,
) -> str:
    """Gemini-only realtime prompt with optional dictionary context.

    known_terms — words the user has explicitly added to their vocabulary.
                  Gemini must NOT 'correct' or normalise them.
    misrecognitions — (heard → meant) pairs learned from user edits.
                       Gemini SHOULD apply these substitutions when confident.
    """
    base = _build_system_prompt(languages)  # переиспользуем основу

    extras: list[str] = []
    if known_terms:
        terms_str = ", ".join(known_terms[:50])  # cap для бюджета токенов
        extras.append(
            "KNOWN TERMS — these are intentional vocabulary. "
            "Do NOT 'correct' spelling, capitalisation, or merge/split them:\n"
            f"{terms_str}"
        )
    if misrecognitions:
        # топ-N по count, отрезаем
        pairs_str = "\n".join(f'  "{frm}" → "{to}"' for frm, to in misrecognitions[:30])
        extras.append(
            "COMMON MISRECOGNITIONS — when you see the left form in context where "
            "it doesn't fit, replace with the right form:\n"
            f"{pairs_str}"
        )
    if not extras:
        return base
    return base + "\n\n" + "\n\n".join(extras)
```

### Где собираются `known_terms` и `misrecognitions`

В `GeminiEditor.refine()`:

```python
def refine(self, text: str, languages: list[str] | None = None,
           known_terms: list[str] | None = None,
           misrecognitions: list[tuple[str, str]] | None = None) -> str:
    ...
    prompt_text = _build_gemini_system_prompt(languages, known_terms, misrecognitions)
    ...
```

В `app.py`, перед вызовом `self.ai_editor.refine(text, languages)`:

```python
known_terms = []
if isinstance(self.ai_editor, GeminiEditor):
    known_terms = collect_known_terms(self.config, languages)
    misrecognitions = collect_misrecognitions(languages)  # из corrections.json (этап 1)

refined = self.ai_editor.refine(text, languages, known_terms, misrecognitions)
```

Хелперы `collect_known_terms`, `collect_misrecognitions` — в `src/utils.py` или новый модуль `src/vocab_provider.py` (предпочтительнее — изолировать от utils).

#### `collect_known_terms(config, languages)`:

- Берёт `user_terms[lang]` для всех `languages` (поддержка v4 и v5 через `_term_str`).
- В этапе 3 — пропускает `inactive=True`.
- Сортировка: сначала manual (защищать важнее всего), потом по use_count desc.
- Cap: 50 терминов (помещается в ~150 токенов промпта Gemini, без ущерба латентности).

#### `collect_misrecognitions(languages)`:

- Читает `corrections.json` → `replacement_pairs[lang]` для каждого активного языка.
- Сортировка по `count` desc.
- Cap: 30 пар.
- Фильтр: оставляем только пары с `count >= 3` — в pairs шум выше, чем в insertions.

### Бюджет токенов

| Источник | Примерная длина | Токенов |
|---|---|---|
| Базовый системный промпт | 600 chars | ~150 |
| KNOWN TERMS (50 × ~10 chars) | 500 chars | ~125 |
| MISRECOGNITIONS (30 × ~30 chars) | 900 chars | ~225 |
| Итого system | — | ~500 |

Допустимо для Gemini Flash Lite, контекст 1M+ токенов; платим за input копейки. Латентность не вырастает.

### Кэширование промпта

Если `known_terms` и `misrecognitions` не менялись — нет смысла перестраивать строку каждый refine.

```python
class GeminiEditor:
    def __init__(self, ...):
        ...
        self._cached_prompt_key: tuple | None = None
        self._cached_prompt_text: str | None = None

    def _get_prompt(self, languages, known_terms, misrecognitions):
        key = (tuple(languages or ()), tuple(known_terms or ()), tuple(misrecognitions or ()))
        if key == self._cached_prompt_key:
            return self._cached_prompt_text
        text = _build_gemini_system_prompt(languages, known_terms, misrecognitions)
        self._cached_prompt_key = key
        self._cached_prompt_text = text
        return text
```

Это плюс к дешёвости — при стабильном словаре одна строка переиспользуется.

### Файловый режим (`refine_file_text`)

Сделать симметрично: `_build_file_system_prompt_gemini` — добавить те же `known_terms` и `misrecognitions` блоки. Можно полностью переиспользовать `_build_gemini_system_prompt` после рефактора (передавать `mode="realtime"|"file"` в hint-строке).

### Защита от хаков

В блоке KNOWN TERMS можно случайно засунуть зловредное слово (например, юзер ввёл термин с управляющими символами). Перед интерполяцией:

```python
def _sanitize_term(t: str) -> str:
    # Strip newlines and curly quotes that might break the prompt structure
    return t.replace("\n", " ").replace('"', "'").strip()
```

Применить ко всем `known_terms` и обоим элементам `misrecognitions`.

---

## Почему НЕ для Qwen

| Причина | Деталь |
|---|---|
| Размер модели | 1.5B 4-bit — слабый instruction-following, склонность к hallucination |
| Уже работает по чёткому промпту «не меняй слова» | Любое расширение промпта повышает риск, что модель «начнёт творить» |
| Контекст 32k, но эффективный — меньше | Длинный системный промпт + входной текст = деградация точности |
| Нет видимой пользы | Локальный pipeline и так консервативен; misrecognitions для слабой модели — слишком тонкий сигнал |

В коде это явно: ветвление `if isinstance(self.ai_editor, GeminiEditor): ...`. Документируем отказ комментарием:

```python
# Dictionary context is intentionally NOT passed to local Qwen (1.5B):
# small instruction-tuned models tend to over-apply known-terms hints,
# inserting them in places they don't belong. Gemini Flash Lite handles
# this correctly thanks to stronger instruction following.
```

---

## Изменения по файлам

| Файл | Изменение |
|---|---|
| `src/ai_editor.py` | `_build_gemini_system_prompt` (новая). `GeminiEditor.refine` — параметры `known_terms`, `misrecognitions` + кэш. `GeminiEditor.refine_file_text` симметрично. |
| `src/vocab_provider.py` | **Новый.** `collect_known_terms`, `collect_misrecognitions`, `_sanitize_term`. |
| `src/app.py` | Перед каждым `self.ai_editor.refine(...)` — собрать словарь, передать (только для GeminiEditor). |
| `tests/test_ai_editor.py` | Тесты системного промпта. |

---

## Тесты

В `tests/test_ai_editor.py`:

1. **test_gemini_prompt_without_dict** — `known_terms=None` → промпт идентичен `_build_system_prompt`.
2. **test_gemini_prompt_with_known_terms** — список терминов попадает в промпт без обрезки.
3. **test_gemini_prompt_with_misrecognitions** — пары `(from, to)` форматируются корректно.
4. **test_gemini_prompt_caching** — повторный вызов с теми же аргументами не пересоздаёт строку (мокаем `_build_gemini_system_prompt`, проверяем call count).
5. **test_gemini_prompt_invalidation** — изменение списка → новая строка.
6. **test_known_terms_capped_at_50** — 100 терминов → в промпте только 50, отсортированных по приоритету (manual → use_count).
7. **test_misrecognitions_capped_at_30** — аналогично, и порог `count >= 3`.
8. **test_term_sanitization** — термин с `\n` или `"` корректно очищен.
9. **test_qwen_unaffected** — `AiEditor` (локальный) не получает дополнительный контекст; `_call_llm` вызывается со стандартным system_prompt.

Интеграционный (manual): включить Gemini, дать команду «Переведи это» в записи. Проверить, что Gemini не выполняет команду (защита уже есть в существующем промпте) и что термин из `user_terms` не «исправляется».

---

## Риски и митигации

| Риск | Митигация |
|---|---|
| Gemini начнёт галлюцинировать словарные слова | Промпт явно: «do not insert known terms where they don't appear». Маленький cap (50) + только реально активные. |
| Misrecognitions слишком агрессивны: «питон» → «Python» применится в контексте «змея питон» | Промпт: «when context doesn't fit». Gemini Flash Lite справляется. Для совсем спорных пар можно вручную blacklist через UI. |
| Латентность вырастает из-за длинного промпта | На Flash Lite +200 токенов системы → ~+30 мс. Незаметно. Кэш промпта помогает. |
| Стоимость API растёт | Те же +200 токенов input на каждый запрос. На Flash Lite — копейки. Юзер видит свою стоимость через Google Console. |
| corrections.json пуст (этап 1 не сделан) | `collect_misrecognitions` возвращает []; промпт без блока MISRECOGNITIONS. Деградация мягкая. |
| Юзер быстро меняет языки → cache miss каждый раз | Нормально, всё равно <50 мс на пересборку. |

---

## Критерии готовности

- [ ] `GeminiEditor.refine` принимает и использует словарь.
- [ ] Manual-тест: добавил «PCA» в user_terms, диктую «PCA анализ» → в `_ai_edited_text` сохранилось «PCA», не «ПКА» / «PSA» / «pca».
- [ ] Manual-тест: пара «питон → Python» в corrections.json, диктую «использую питон для скриптов» → Gemini заменил на «Python».
- [ ] Локальный путь (Qwen) не изменился — `_call_llm` вызывается ровно как раньше.
- [ ] Все тесты `test_ai_editor.py` зелёные.
- [ ] CLAUDE.md обновлён: раздел «AI editor — vocabulary context (Gemini only)».

---

## Порядок коммитов

1. `feat(ai-editor): _build_gemini_system_prompt with optional vocab/misrecognition blocks`
2. `feat(vocab-provider): collect_known_terms + collect_misrecognitions helpers`
3. `feat(app): pass dictionary context to GeminiEditor.refine`
4. `feat(ai-editor): cache built prompt by (langs, terms, pairs) key`
5. `feat(ai-editor): symmetric vocab passing for refine_file_text on Gemini`
6. `test(ai-editor): coverage for prompt building, caching, sanitisation`
7. `docs(claude-md): document Gemini vocab pass-through`

---

## Зависимости

- `known_terms`: работает уже сегодня (есть `user_terms`).
- `misrecognitions`: требует этапа 1 (`corrections.json`). Без него — просто пустой список, остальной этап работает.
- Этап 3 (decay): если сделан, `collect_known_terms` фильтрует inactive. Если не сделан — берёт все, не страшно.
