# План улучшения UX загрузки моделей Whisper

Документ описывает 5 ключевых улучшений процесса загрузки моделей Whisper из меню-бара
и одну бонусную задачу. Идеи отсортированы от самых высокоприоритетных к низким.
Для каждой указаны: проблема, решение, конкретные файлы и функции, edge cases,
оценка трудозатрат и риски.

---

## Контекст текущей реализации

**Состояние на момент написания плана:**

- `WHISPER_MODELS` и `WHISPER_MODEL_SIZES` объявлены в `src/menu_bar.py:12-27`.
- Индикатор `🟢` ставится через `_update_model_cache_indicators()` (`menu_bar.py:881`),
  запускается фоновым тредом из `_start_model_cache_check()` (`menu_bar.py:876`).
- Клик по модели → `change_model()` (`menu_bar.py:925`):
  если модель не в кэше, вызывает `_prompt_whisper_model_download()` →
  `_start_whisper_model_download()` → `osascript` открывает Terminal с
  `scripts/download_whisper_model.py`.
- Скрипт `scripts/download_whisper_model.py` использует `huggingface_hub.snapshot_download`
  с `resume_download=True`. Печатает прогресс через встроенный `tqdm`.
- После завершения пользователь должен **вручную перезапустить приложение**.
- Все UI-операции идут через `_main_thread_queue` (`menu_bar.py:494`), drained каждые 0.3s.

**Главные точки расширения для плана:**

- `update_config({"model_name": ...})` (`app.py`) — горячая смена модели
  без рестарта; уже работает для уже-кэшированных моделей.
- `_update_model_cache_indicators()` — пере-сканирование кэша; можно дёрнуть после
  завершения загрузки.
- `_main_thread_queue` — единственный безопасный канал в UI из фоновых тредов.

---

## 1. Внутренняя загрузка вместо Terminal

### Проблема

Открытие Terminal с командой `python /Users/.../venv/bin/python scripts/...` для конечного
пользователя выглядит как сбой или подозрительная активность. Многие закроют окно или
запаникуют. Это самое слабое место всего флоу.

### Решение

Загрузка идёт **внутри приложения** в небольшом NSPanel с прогресс-баром,
скоростью, ETA и кнопкой «Отмена». Пользователь не покидает Click-n-speak.

### Реализация

**Новый файл:** `src/model_download_panel.py`

```python
class ModelDownloadPanel:
    """NSPanel with progress bar, speed/ETA labels, Cancel button.

    Lifecycle:
      - show(label, model_id, total_bytes_estimate)
      - update_progress(downloaded_bytes, total_bytes, speed_bps)
      - finish(success: bool, error: str | None)
      - close()
    """
```

UI: вертикальный стек с `NSTextField` (название модели), `NSProgressIndicator`
(determinate), две `NSTextField` строки («Скачано 450 МБ из 1.5 ГБ · 12 МБ/с» и «Осталось ~1 мин 20 с»),
`NSButton` «Отмена». Стиль такой же, как `preview_panel.py` —
NSPanel + KeyablePanel pattern.

**Новый файл/модуль:** `src/model_downloader.py`

```python
class ModelDownloader:
    """Wraps huggingface_hub.snapshot_download with progress reporting.

    - Runs in a daemon thread.
    - Uses tqdm subclass that fires on_progress(downloaded, total) callback.
    - Supports cancel via threading.Event → raises inside tqdm.update().
    """
    def start(self, model_id: str, on_progress, on_done, on_error) -> None
    def cancel(self) -> None
```

**Технически:** `snapshot_download` принимает `tqdm_class` параметр.
Передаём кастомный подкласс, который в `update(n)` вызывает callback
и проверяет `cancel_event.is_set()` → `raise CancelledError`.

```python
class _ReportingTqdm(tqdm):
    def update(self, n=1):
        super().update(n)
        if self._cb:
            self._cb(self.n, self.total)
        if self._cancel_event.is_set():
            raise _DownloadCancelled()
```

**Изменения в `src/menu_bar.py`:**

- `_start_whisper_model_download()` больше не вызывает `osascript`.
  Вместо этого создаёт `ModelDownloadPanel`, запускает `ModelDownloader.start()`,
  на `on_progress` обновляет панель через `_main_thread_queue`.
- На `on_done(success=True)` вызывает `_update_model_cache_indicators()` +
  `update_config({"model_name": model_id})` (см. пункт 2).
- На `on_error` показывает сообщение в той же панели и предлагает «Повторить».

### Edge cases

- **Пользователь закрывает панель крестиком** → трактуем как «Отмена», `cancel_event.set()`,
  закрываем стрим, не удаляем уже скачанные части (HF Hub сам поддерживает resume).
- **Сеть пропала на 80%** → `requests.exceptions.ConnectionError` пойдёт в `on_error`,
  показываем «Соединение прервано — Повторить?». Кнопка повтора снова вызывает
  `ModelDownloader.start()` с тем же `model_id` (resume).
- **Приложение закрыли во время загрузки** → стрим прерывается, частичный файл
  остаётся в `~/.cache/huggingface/hub/`. При следующем запуске и клике на ту же модель
  — продолжает с того же места.
- **Total bytes неизвестен** (некоторые snapshot'ы не знают размер) →
  показываем indeterminate `NSProgressIndicator`, скрываем ETA.

### Трудозатраты

3–4 часа: ~120 строк панели, ~80 строк downloader, ~30 строк интеграции в menu_bar.

### Риски

- `huggingface_hub.snapshot_download` использует параллельные потоки для нескольких
  файлов — `tqdm` колбэки могут приходить из разных тредов. Колбэк должен быть
  thread-safe (просто `_main_thread_queue.put_nowait`).
- Cancel через exception внутри tqdm может оставить мусор на диске. Это не критично:
  `huggingface_hub` использует `.incomplete` файлы и сам их подчищает при resume.

---

## 2. Не требовать перезапуска приложения

### Проблема

После завершения загрузки текст «Перезапустите приложение, чтобы появился зелёный
индикатор» воспринимается пользователем как баг. У вас уже есть механизм горячей
смены модели — он просто не задействован в этом пути.

### Решение

После успешной загрузки:
1. Пере-сканировать HF-кэш → индикатор `🟢` появляется автоматически.
2. Сразу переключить активную модель на скачанную (ведь пользователь её и выбирал).
3. Прогреть GPU новой моделью.

### Реализация

**В `src/menu_bar.py`, метод `_on_download_complete(model_id, label)`:**

```python
def _on_download_complete(self, model_id: str, label: str) -> None:
    """Called by ModelDownloader on successful completion (main thread)."""
    log_info(f"Whisper model downloaded: {model_id}")

    # 1. Re-scan cache → indicator updates
    self._start_model_cache_check()

    # 2. Activate the just-downloaded model
    self.main_app.update_config({"model_name": model_id})

    # 3. Update menu checkmarks
    for item in self.menu["Model"].values():
        if hasattr(item, "state"):
            item.state = 0
        # title might still have download icon — find by base label
        base = item.title.lstrip(_ICON_CACHED).strip()
        if base == label:
            item.state = 1

    # 4. Notify
    self.main_app.notify(
        f"Модель «{label}» готова",
        "Можно начинать диктовку — модель активна.",
    )
```

`update_config` уже имеет логику: при изменении `model_name` он вызывает
`update_transcriber(model)`, что отправляет `{"action": "update_model", ...}`
в child-процесс. Тот перезагружает MLX-веса. Работает, проверено для
кэшированных моделей.

### Edge cases

- **Транскрипция идёт в момент завершения загрузки** → `update_transcriber` ставит
  команду в input_queue, child-процесс обработает её *после* текущего чанка.
  Никакого конфликта.
- **Пользователь успел выбрать другую модель за время загрузки** →
  не переключаем модель автоматически. Решение: запоминаем `_active_model_at_download_start`,
  и переключаем только если он не менялся за время загрузки.
- **Загрузка завершилась, но модель битая** (corruption) → на следующей
  транскрипции `mlx_whisper` упадёт; current `cold-start timeout` отловит.
  Можно дополнительно перед активацией прогреть модель через `transcriber.warmup()`
  и ловить ошибку.

### Трудозатраты

1 час: 30 строк в `menu_bar.py` + рефакторинг текущего пути загрузки.

### Риски

Минимальные. Логика уже работает для кэшированных моделей; здесь применяем тот же путь.

---

## 3. Размер и статус прямо в меню

### Проблема

Пользователь не может сравнить варианты, не кликая в каждый. Размер модели
показывается только в NSAlert *после* клика. Иконка-стрелка `⤓` (16×16 template)
плохо видна на крошечной строке меню.

### Решение

Формат пункта меню:
```
   Turbo · 795 MB · 🟢
   Large v3 · 1.5 GB · ⤓
   Medium · 790 MB · ⤓
   Small · 244 MB · 🟢
   Base · 74 MB · 🟢
```

Опционально: `★` рядом с рекомендованной моделью (Turbo для большинства пользователей —
лучший trade-off speed/quality).

### Реализация

**В `src/menu_bar.py`:**

1. Изменить `_setup_model_menu()` (примерно `menu_bar.py:749`):
   при создании каждого `MenuItem` сразу включать размер:
   ```python
   for label, model_id in WHISPER_MODELS:
       size = WHISPER_MODEL_SIZES.get(model_id, "?")
       title = f"{label} · {size}"
       if model_id == _RECOMMENDED_MODEL:
           title += " ★"
       item = rumps.MenuItem(title, callback=self.change_model)
   ```

2. Изменить `_update_model_cache_indicators()` (`menu_bar.py:881`):
   аккуратно работать с новым форматом. Title теперь `{label} · {size}` или
   `🟢 {label} · {size}`. Для парсинга base label:
   ```python
   def _parse_model_title(title: str) -> str:
       """Extract clean label from menu item title.
       '🟢 Turbo · 795 MB ★' → 'Turbo'
       """
       t = title.strip()
       if t.startswith(_ICON_CACHED):
           t = t[len(_ICON_CACHED):].strip()
       # cut at first ' · '
       return t.split(" · ", 1)[0].rstrip(" ★")
   ```
   Использовать эту функцию и в `change_model()` вместо текущего ручного парсинга.

3. Добавить константу:
   ```python
   _RECOMMENDED_MODEL = "mlx-community/whisper-large-v3-turbo"
   ```

### Edge cases

- **Локализация:** «MB»/«ГБ» — в текущей версии используется английское `MB`. Оставляем,
  это техническая единица, не локализуется.
- **Длина title:** в macOS menu bar нет жёсткого лимита, но 30+ символов выглядит
  громоздко. Самый длинный: `🟢 Large v3 · 1.5 GB ★` = 22 символа. OK.
- **Парсинг title в `change_model`:** все места, которые делали `.lstrip(_ICON_CACHED)`,
  теперь должны идти через `_parse_model_title()`. Найти все:
  `grep "_ICON_CACHED" src/menu_bar.py`.

### Трудозатраты

1 час: ~20 строк изменений, тестирование на всех 5 моделях.

### Риски

Минимальные. Чисто строковая работа с UI.

---

## 4. Статус «загружается» как первоклассный пункт меню

### Проблема

Между кликом «Загрузить» и завершением загрузки модель в меню выглядит как обычная
не-скачанная. Если пользователь забыл, что запустил — может кликнуть второй раз
и запустить **второй параллельный** процесс. Скрипт это не обрабатывает.

### Решение

Состояния пункта меню:

| Состояние | Title | Поведение клика |
|---|---|---|
| Готова | `🟢 Turbo · 795 MB` | Активировать |
| Не загружена | `Turbo · 795 MB ⤓` | Открыть диалог загрузки |
| Загружается | `Turbo · 45% ↓` | disabled (или показать панель прогресса) |
| Ошибка | `Turbo ⚠ Повтор` | Открыть диалог повтора |

### Реализация

**Состояние в `ClickNSpeakApp`:**

```python
self._download_state: dict[str, str] = {}
# model_id → "downloading" | "error"
self._download_progress: dict[str, int] = {}
# model_id → percent 0..100
```

**Метод `_render_model_menu_item(model_id)`:**

```python
def _render_model_menu_item(self, model_id: str) -> str:
    label = next((l for l, mid in WHISPER_MODELS if mid == model_id), model_id)
    size = WHISPER_MODEL_SIZES.get(model_id, "?")

    state = self._download_state.get(model_id)
    if state == "downloading":
        pct = self._download_progress.get(model_id, 0)
        return f"{label} · {pct}% ↓"
    if state == "error":
        return f"{label} ⚠ Повтор"
    if self._cached_models.get(model_id):
        return f"{_ICON_CACHED} {label} · {size}"
    return f"{label} · {size} ⤓"
```

**Колбэк прогресса (вызывается из `ModelDownloader`):**

```python
def _on_download_progress(self, model_id: str, downloaded: int, total: int) -> None:
    pct = int(100 * downloaded / total) if total else 0
    if pct == self._download_progress.get(model_id):
        return  # avoid menu thrash
    self._download_progress[model_id] = pct
    self._main_thread_queue.put((self._refresh_model_menu_titles, [], {}))
```

**Защита от двойного клика:**

В `change_model()` сразу после извлечения `model_id`:

```python
if self._download_state.get(model_id) == "downloading":
    # already in progress — just bring panel to front
    if self._download_panel:
        self._download_panel.bring_to_front()
    return
```

**Persistence через рестарт:**

Если приложение убили во время загрузки — ничего не делаем для
полировки сохранения состояния (HF Hub сам поддерживает resume).
Просто при следующем запуске — пользователь снова кликает на модель,
загрузка возобновляется с того же места.

### Edge cases

- **Throttling обновлений:** прогресс может прилетать 100+ раз/с. Обновлять title
  только когда `pct` поменялся на целое число.
- **Модель завершилась с ошибкой, потом новый клик** → `_download_state[model_id] = None`
  при попытке нового запуска.
- **Несколько моделей одновременно** — теоретически можно, но HF Hub использует
  fcntl-локи на файлы кэша, конфликтов нет. UX-вопрос: разрешать или нет.
  Рекомендую **запретить** (только одна загрузка за раз) — дешевле и понятнее.

### Трудозатраты

3 часа: новое state machine, throttling, refresh menu titles, тестирование.

### Риски

- `rumps.MenuItem.title` setter может быть медленным при частых обновлениях.
  Mitigation: throttling по проценту.
- Обновление title через `_main_thread_queue` каждые 1% — это до 100 jobs за загрузку.
  Очередь дренится каждые 300ms, так что max ~3 обновления видимы. Норм.

---

## 5. Проверка диска и сети **до** старта загрузки

### Проблема

Пользователь нажимает «Загрузить», уходит делать кофе, возвращается через 20 минут —
а на диске не было 1.5 ГБ или сеть отвалилась на 80%. Сообщение об ошибке появляется
в Terminal/логе, в самом приложении ничего не понятно.

### Решение

Перед стартом загрузки:

1. **Disk space check** — `shutil.disk_usage(cache_dir)`. Если свободно меньше
   `model_size_bytes * 1.2`, показать NSAlert: «Недостаточно места. Свободно X ГБ,
   нужно Y ГБ. Освободите место и попробуйте снова». Без кнопки «Загрузить всё равно» —
   это бесполезно.
2. **Network check (опционально)** — лёгкий HEAD-запрос к
   `https://huggingface.co/<model_id>/resolve/main/config.json`.
   Если 4xx/5xx/timeout — показать «Не удаётся подключиться к huggingface.co.
   Проверьте интернет-соединение». Без блокировки: просто warning, кнопка «Всё равно
   попробовать» включена.
3. **Show real free space in download alert** — добавить строку «Свободно на диске:
   12 ГБ» рядом с «Размер: 1.5 ГБ». Снимает тревогу у пользователей с маленькими SSD.

### Реализация

**В `src/menu_bar.py`, метод `_prompt_whisper_model_download()`:**

Добавить парсинг размера в байты:

```python
_MODEL_SIZE_BYTES: dict[str, int] = {
    "mlx-community/whisper-large-v3-turbo":  795_000_000,
    "mlx-community/whisper-large-v3-mlx":  1_500_000_000,
    "mlx-community/whisper-medium-mlx":     790_000_000,
    "mlx-community/whisper-small-mlx":      244_000_000,
    "mlx-community/whisper-base-mlx":        74_000_000,
}
```

Добавить пре-флайт чек:

```python
def _preflight_download(self, model_id: str) -> tuple[bool, str | None]:
    """Returns (ok, error_message). Error_message is None if ok."""
    import shutil
    cache_dir = os.environ.get("HF_HOME") or \
        os.path.expanduser("~/.cache/huggingface/hub")
    os.makedirs(cache_dir, exist_ok=True)

    needed = _MODEL_SIZE_BYTES.get(model_id, 0)
    free = shutil.disk_usage(cache_dir).free

    if needed and free < needed * 1.2:
        free_gb = free / 1e9
        need_gb = needed * 1.2 / 1e9
        return False, (
            f"Недостаточно места на диске.\n\n"
            f"Свободно: {free_gb:.1f} ГБ\n"
            f"Требуется: {need_gb:.1f} ГБ (с буфером)\n\n"
            f"Освободите место и попробуйте снова."
        )
    return True, None
```

В `_prompt_whisper_model_download()` показывать в `informativeText`:

```python
free_gb = shutil.disk_usage(cache_dir).free / 1e9
alert.setInformativeText_(
    f"Размер: {size_str} · Свободно на диске: {free_gb:.1f} ГБ\n\n"
    f"Загрузка идёт в фоне, можно отменить и продолжить позже."
)
```

После клика «Загрузить» сначала вызвать `_preflight_download()`. Если `ok=False` —
показать второй alert с конкретной ошибкой и не запускать.

**Network check (опционально):**

```python
def _check_huggingface_reachable(self, timeout: float = 3.0) -> bool:
    import urllib.request
    try:
        req = urllib.request.Request(
            "https://huggingface.co/api/whoami-v2",
            method="HEAD",
        )
        urllib.request.urlopen(req, timeout=timeout)
        return True
    except Exception:
        return False
```

Опционален — некоторые корпоративные сети режут HEAD, но GET файлов работает.
Поэтому делаем только soft warning.

### Edge cases

- **Симлинки в кэше HF** — `shutil.disk_usage(cache_dir)` смотрит на partition,
  где лежит cache_dir, корректно учитывает реальное место.
- **HF_HOME переопределён** на NFS/external drive — учитывается, потому что
  читаем переменную окружения первым делом.
- **Размер модели в БАЙТАХ может быть неточным** (отличается от строки `~795 MB`).
  Решение: брать с запасом (`* 1.2`), точнее не нужно.

### Трудозатраты

1.5 часа: ~50 строк кода + два дополнительных alert.

### Риски

- `urllib.request.urlopen` с timeout=3s может блокировать main thread на эти 3
  секунды. Решение: вынести в фоновый тред, показать spinner до получения ответа,
  или не блокировать — давать клиенту запустить и ловить connection error в downloader.
  Рекомендую второй вариант — проще, и downloader всё равно покажет ошибку
  внутри панели.

---

## Бонус. Текст диалогов и устранение мелких косяков

### Проблема

Некоторые мелочи, которые не входят в топ-5, но видны в живой эксплуатации:

- Текст диалога слишком технический («Загрузка запустится в Терминале и может быть
  прервана и возобновлена»). Деталь *как* работает не нужна пользователю.
- Если индикатор `🟢` отсутствует, но модель *на самом деле* в кэше (race condition
  при старте, до завершения первого фонового скана) — клик ведёт в диалог загрузки,
  что выглядит как баг.
- Нет ETA в alert, только размер. Пользователь не понимает, на сколько это.

### Решение

**1. Перепиcать тексты диалогов.**

Было:
```
Размер: ~1.5 GB. Загрузка запустится в Терминале и может быть прервана и возобновлена.

После завершения перезапустите приложение — модель появится с зелёным индикатором.
```

Стало (при условии реализации пунктов 1+2):
```
Размер: 1.5 ГБ · Свободно: 87 ГБ
Примерное время: 2–4 минуты при средней скорости.

Загрузка идёт в фоне. Можно отменить и продолжить позже —
скачанные части не потеряются.
```

ETA можно прикинуть очень грубо (size / 10 МБ/с) или вообще не показывать —
всё равно зависит от сети. Лучше показывать в самой панели прогресса, когда
есть реальные данные.

**2. Re-check кэша перед открытием диалога загрузки.**

В `change_model()`:

```python
if not self._is_whisper_model_cached(model_id):
    # Maybe the cache scan hasn't finished yet, or model was added externally.
    # Do one fresh blocking check before showing download alert.
    if not self._is_whisper_model_cached_fresh(model_id):
        self._prompt_whisper_model_download(clean_label, model_id)
        return
    # Cache had it — refresh indicators and proceed
    self._start_model_cache_check()
```

`_is_whisper_model_cached_fresh()` — то же самое что `_is_whisper_model_cached`,
просто с явным комментарием, что вызов синхронный и блокирующий (~50–100ms,
дискового I/O).

**3. После успешного preflight + фактической загрузки — пере-логировать
индикаторы.**

Уже учтено в пункте 2. Здесь упоминается для полноты.

**4. Языковая консистентность скрипта `download_whisper_model.py`.**

Если оставляем скрипт (он полезен как fallback / для CI / для отладки),
текст «Whisper Model Downloader — Click-n-speak» — оставить английским,
это техническая утилита.

### Реализация

Все изменения локальны:
- `src/menu_bar.py` — текст alert + дополнительный fresh-check.
- `scripts/download_whisper_model.py` — без изменений (или незначительные правки в комментарии).

### Трудозатраты

30 минут.

### Риски

Нулевые. Косметика и одна защитная проверка.

---

## Сводная таблица приоритетов

| # | Идея | Закрывает % жалоб | Трудозатраты | Сложность | Риск |
|---|---|---|---|---|---|
| 1 | Внутренняя загрузка вместо Terminal | 50% | 3–4 ч | Средняя | Низкий |
| 2 | Без перезапуска | 20% | 1 ч | Низкая | Минимальный |
| 3 | Размер в меню | 10% | 1 ч | Низкая | Минимальный |
| 4 | Статус «загружается» | 10% | 3 ч | Средняя | Низкий |
| 5 | Pre-flight checks | 5% | 1.5 ч | Низкая | Минимальный |
| Б | Тексты + fresh re-check | 5% | 30 мин | Низкая | Нулевой |

---

## Рекомендуемый порядок исполнения

**Sprint 1 (минимум жизнеспособного UX, ~2 часа):**

- #3 Размер в меню — самый дешёвый win, видно сразу.
- #2 Без перезапуска — чистое исправление, опирается на готовую инфраструктуру.
- Б Тексты — косметика поверх существующего alert.

После этого спринта пользователь увидит размеры до клика, и после завершения загрузки
модель будет работать без перезапуска. Это закрывает примерно 35% жалоб.

**Sprint 2 (главный UX-удар, ~5 часов):**

- #1 Внутренняя загрузка с панелью.
- #4 Статус «загружается» в меню.
- #5 Pre-flight checks (бонусом, как часть нового пути загрузки).

После этого спринта Terminal больше не открывается. Закрывает оставшиеся 65% жалоб.

---

## Что **не** входит в этот план

- **Удаление модели из кэша** (pop-up «удалить чтобы освободить место») — отдельная фича,
  не для UX-плана загрузки.
- **Авто-загрузка моделей по триггеру low-disk** — преждевременная оптимизация,
  пока не понятно, как часто это случается.
- **Telemetry загрузок** (сколько % пользователей скачивают какую модель) —
  политически чувствительно, требует отдельного решения.
- **Прогресс-бар в menu bar icon** (как в Spotify) — потребует AppKit-кастомизации
  иконки, дорого, малая отдача.
