# Этап 5 — UI «Add to dictionary» в попапе правки

## Цель

Самый быстрый возможный путь добавить термин: **пользователь увидел в попапе «Гитхаб» вместо «GitHub», поправил, нажал ⌘D — слово сразу в словаре**. Без копаний в меню, NSAlert'ах и кнопке «Manage Terms».

Это паттерн Wispr Flow / Superwhisper: дикcловарь редактируется по ходу диктовки, а не отдельным сеансом.

После этапа: добавление нового термина занимает <1 секунды.

---

## Что есть сейчас

`src/preview_panel.py:show_interactive` — открывает `KeyablePanel` с `NSTextView` для редактирования. `TextViewDelegate` ловит Enter/Escape через `textView_doCommandBySelector_`. Локальный + глобальный NSEvent monitor дополняет (на случай, если попап потерял фокус).

Текстовое поле поддерживает выделение (NSTextView). Selection доступен через `text_view.selectedRange()` → `NSRange`.

---

## Что меняем

### Хоткей ⌘D в попапе

В `TextViewDelegate.textView_doCommandBySelector_` пока ловятся только `insertNewline:` (Enter) и `cancelOperation:` (Escape). ⌘D не отдельный selector — это keyDown с modifier'ом. Его проще обрабатывать через NSEvent local monitor (он уже есть в `_local_key_handler`).

```python
# в _local_key_handler:
if event.type() == NSKeyDown and event.modifierFlags() & NSEventModifierFlagCommand:
    if event.charactersIgnoringModifiers() == "d":
        _add_selection_to_dictionary()
        return None  # consume
```

### Реакция: `_add_selection_to_dictionary`

```python
def _add_selection_to_dictionary():
    rng = self.text_view.selectedRange()
    if rng.length == 0:
        # Нет выделения — берём слово под курсором
        full = str(self.text_view.string())
        word = _word_at_offset(full, rng.location)
    else:
        full = str(self.text_view.string())
        word = full[rng.location : rng.location + rng.length].strip()

    if not _is_valid_term(word):
        _flash_toast("Not a valid term")  # см. ниже
        return

    # Колбек в app.py — попап не должен сам мутировать config
    if self._on_add_to_dictionary:
        self._on_add_to_dictionary(word)
        _flash_toast(f"Added: {word}")
```

`_word_at_offset(text, offset)` — находит границы слова по `_TERM_PATTERN` (импорт из log_analyzer).

`_is_valid_term(word)`:
- ≥2 символа
- Не цифры
- Не из стоп-листа
- ≤30 символов (защита от случайного выделения целой фразы)

### Колбек `on_add_to_dictionary` — поднять интерфейс попапа

В `show_interactive(...)` добавить параметр:

```python
def show_interactive(self, text, queue, on_confirm, on_cancel=None,
                     title="...", on_add_to_dictionary=None):
    ...
    self._on_add_to_dictionary = on_add_to_dictionary
```

В `app.py:_build_confirm_cancel_callbacks` — собрать вместе с `_on_confirm` и `_on_cancel`:

```python
def _on_add_to_dictionary(term: str):
    primary = get_primary_language(self.config)
    add_term_to_user_terms(self.config, primary, term, source="manual")
    self.config["initial_prompt"] = build_initial_prompt(self.config)
    save_config_to_disk(self.config)
    self._initial_prompt_dirty = True
    # Обновить prompt-файл, чтобы watcher не схватил пустую правку
    if self.menu_bar and hasattr(self.menu_bar, "_sync_prompt_file"):
        self._submit_for_main_thread(self.menu_bar._sync_prompt_file, primary)
    log_info(f"Added term to dictionary via popup: {term}")
```

`add_term_to_user_terms(config, lang, term, source)` — общий хелпер в `utils.py` (или `vocab_provider.py` из этапа 4):
- Игнорирует дубликат (case-insensitive).
- Создаёт dict-объект (v5 формат) или строку (v4) — в зависимости от текущей schema_version.
- Возвращает True/False (добавлен ли).

Передать в `show_interactive`:

```python
self._preview_panel.show_interactive(
    text=full_text,
    queue=self._main_thread_queue,
    on_confirm=_on_confirm,
    on_cancel=_on_cancel,
    on_add_to_dictionary=_on_add_to_dictionary,
)
```

(Несколько мест вызова — `app.py:980, 1020, 1164`.)

### Toast-уведомление в попапе

Чтобы пользователь видел подтверждение «Added: GitHub», без отвлечения внешним notification.

Простая реализация — title_field временно меняет текст и цвет:

```python
def _flash_toast(self, message: str, duration: float = 1.5):
    original_title = self.title_field.stringValue()
    original_color = self.title_field.textColor()
    self.title_field.setStringValue_(message)
    self.title_field.setTextColor_(NSColor.systemGreenColor())

    def _restore():
        time.sleep(duration)
        self._submit(_apply_restore)
    def _apply_restore():
        self.title_field.setStringValue_(original_title)
        self.title_field.setTextColor_(original_color)
    threading.Thread(target=_restore, daemon=True).start()
```

(Уже есть pattern для submit в main thread — переиспользуем.)

### Контекстное меню (правый клик)

Опционально, поверх ⌘D. NSTextView поддерживает `menu(for:)` через subclass или setMenu_. Добавить пункт «Add to dictionary» в стандартное контекстное меню.

```python
class DictionaryAwareTextView(NSTextView):
    def menuForEvent_(self, event):
        menu = super().menuForEvent_(event)
        if menu is None:
            return None
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Add to Dictionary", "addToDictionary:", "d"
        )
        item.setKeyEquivalentModifierMask_(NSEventModifierFlagCommand)
        item.setTarget_(self)
        menu.insertItem_atIndex_(item, 0)
        menu.insertItem_atIndex_(NSMenuItem.separatorItem(), 1)
        return menu

    def addToDictionary_(self, sender):
        # Тот же путь, что и хоткей
        if hasattr(self, "_panel_ref") and self._panel_ref:
            self._panel_ref._add_selection_to_dictionary()
```

### Title попапа

Подсказать юзеру, что хоткей существует. Сейчас title — `"Редактируй и нажми Enter"` (по умолчанию). Меняем на:

`"Edit · Enter to confirm · ⌘D to add term"`

(или по языку: `s = get_ui_strings(lang); s["popup_title"]`).

---

## Изменения по файлам

| Файл | Изменение |
|---|---|
| `src/preview_panel.py` | Subclass `DictionaryAwareTextView`. `_local_key_handler` — обработка ⌘D. `show_interactive` — параметр `on_add_to_dictionary`. `_flash_toast`. `_word_at_offset`, `_is_valid_term` хелперы. |
| `src/app.py` | `_build_confirm_cancel_callbacks` — собрать `_on_add_to_dictionary`. Передать в каждый `show_interactive`. |
| `src/utils.py` (или `vocab_provider.py`) | `add_term_to_user_terms` — общий хелпер с поддержкой v4/v5. |
| `src/utils.py:get_ui_strings` | Новые ключи: `popup_title_with_hotkey`, `toast_added`, `toast_invalid_term`. |
| `tests/test_preview_panel.py` | Manual smoke test — UI трудно покрыть unit-тестами, но базовые `_word_at_offset`, `_is_valid_term` — да. |
| `tests/test_vocab_provider.py` | Тесты `add_term_to_user_terms`. |

---

## Тесты

Юнит:

1. **test_word_at_offset_inside_word** — offset в середине слова → возвращает целое слово.
2. **test_word_at_offset_at_boundary** — offset на пробеле → ближайшее слово или пусто.
3. **test_is_valid_term_accepts_alphanumeric** — «PCA», «MLX2», «git#hub» → True.
4. **test_is_valid_term_rejects_too_short** — «a», «12» → False.
5. **test_is_valid_term_rejects_stoplist** — «the», «http» → False.
6. **test_is_valid_term_rejects_long_phrase** — 50 символов с пробелами → False.
7. **test_add_term_to_user_terms_dedupe_ci** — добавление «GitHub» при наличии «github» → False (дубликат).
8. **test_add_term_to_user_terms_v5_dict** — на v5-конфиге создаётся dict с `source="manual"` и `added_at=now`.
9. **test_add_term_to_user_terms_v4_string** — на v4 — просто строка (не ломаем legacy).

Manual smoke test:
- Записать фразу «гитхаб репозиторий».
- В попапе исправить на «GitHub репозиторий».
- Выделить «GitHub», нажать ⌘D → toast «Added: GitHub».
- Нажать Enter, подтвердить.
- Проверить: `user_terms[primary]` содержит `GitHub`.
- Проверить: следующая запись «гитхаб» уже распознаётся как «GitHub».

---

## Риски и митигации

| Риск | Митигация |
|---|---|
| ⌘D перехвачен глобально / другой системный шорткат | Внутри попапа — он наш (popup is key window). NSEvent local monitor ловит до системы. |
| Юзер случайно нажал ⌘D без выделения → добавлено мусорное слово | Берём слово под курсором; `_is_valid_term` отфильтровывает мусор. Toast показывает что добавлено — юзер видит ошибку. |
| Если NSTextView потерял фокус — keypress не дойдёт | Уже решено в существующей реализации (popup activates app). Добавить `_global_key_handler` зеркало для ⌘D на всякий. |
| Юзер хочет undo | Не критично сразу: можно открыть «Manage Terms» (этап 3) и удалить. В будущем — добавить command stack в попапе. |
| Контекстное меню не показывается | Опциональный путь, если subclass не сработает — оставляем только хоткей. |
| Сохранение config из main-thread в хот-пас попапа | `save_config_to_disk` атомарный, дёшев (<10 мс). Допустимо. |

---

## Критерии готовности

- [ ] ⌘D в попапе с выделенным словом → слово в `user_terms[primary]`, toast виден.
- [ ] ⌘D без выделения → берётся слово под курсором.
- [ ] Дубликат не добавляется повторно.
- [ ] Контекстное меню (правый клик) содержит «Add to Dictionary».
- [ ] Title попапа подсказывает про шорткат.
- [ ] Существующий поток Enter/Escape не сломан.
- [ ] CLAUDE.md обновлён: раздел «Popup hotkeys».

---

## Порядок коммитов

1. `feat(vocab-provider): add_term_to_user_terms helper with v4/v5 support`
2. `feat(preview-panel): ⌘D hotkey to add selected/cursor word to dictionary`
3. `feat(preview-panel): toast feedback for dictionary actions`
4. `feat(preview-panel): context menu item for Add to Dictionary`
5. `feat(app): wire on_add_to_dictionary callback into popup`
6. `feat(ui-strings): popup title with hotkey hint per language`
7. `test(vocab-provider): add_term_to_user_terms behaviour`
8. `docs(claude-md): document popup hotkeys`

---

## Зависимости

- Может быть сделан **независимо** от этапов 1, 2, 3, 4.
- Лучше всего сочетается с этапом 3 (v5-конфиг с метаданными — `source="manual"` сразу как ожидается).
- Если этап 3 не сделан — `add_term_to_user_terms` пишет строку (v4 формат). Совместимо.
