import os
import queue
import subprocess
import sys
import threading

import rumps

# ---------------------------------------------------------------------------
# Whisper model registry — ordered fastest → most accurate
# ---------------------------------------------------------------------------
WHISPER_MODELS = [
    ("Turbo",    "mlx-community/whisper-large-v3-turbo"),
    ("Large v3", "mlx-community/whisper-large-v3-mlx"),
    ("Medium",   "mlx-community/whisper-medium-mlx"),
    ("Small",    "mlx-community/whisper-small-mlx"),
    ("Base",     "mlx-community/whisper-base-mlx"),
]

_ICON_CACHED   = "\U0001f7e2"   # 🟢  — model is on disk, instant switch
_ICON_DOWNLOAD = "\u2b07\ufe0f"  # ⬇️  — model needs to download

from .log_analyzer import generate_terms_hint_from_history
from .phrase_history import get_last_phrases
from .updater import check_for_update
from .utils import (
    build_initial_prompt,
    copy_to_clipboard,
    escape_applescript_string,
    get_config_path,
    get_log_file_path,
    get_menu_icon_path,
    get_primary_language,
    get_ui_strings,
    is_accessibility_trusted,
    log_error,
    log_info,
    open_accessibility_settings,
    save_config_to_disk,
    send_notification,
)


class ClickNSpeakApp(rumps.App):
    def __init__(self, main_app):
        icon_path = str(get_menu_icon_path())
        super(ClickNSpeakApp, self).__init__("", icon=icon_path)
        self.main_app = main_app
        self.config = main_app.config
        self._last_prompt_mtime = 0.0
        self._accessibility_granted = is_accessibility_trusted()
        self._accessibility_item = None  # set in setup_menu

        # Build Menu
        self.setup_menu()
        self._migrate_old_prompt()
        # Asynchronously check which Whisper models are already cached
        self._start_model_cache_check()

    def _migrate_old_prompt(self):
        """Migrates a single initial_prompt.txt into custom_prompts mapping on first launch."""
        custom_dict = self.config.get("custom_prompts")
        if custom_dict is None:
            old_path = get_config_path().parent / "initial_prompt.txt"
            lang = get_primary_language(self.config)
            
            custom_dict = {}
            if old_path.exists():
                try:
                    with open(old_path, "r", encoding="utf-8") as f:
                        old_txt = f.read().strip()
                    if old_txt:
                        custom_dict[lang] = old_txt
                        self.config["initial_prompt"] = old_txt
                except Exception:
                    pass
            self.config["custom_prompts"] = custom_dict
            self.save_config()

    def _get_prompt_path(self, lang: str = None):
        """Returns the absolute path to initial_prompt_{lang}.txt."""
        if not lang:
            lang = get_primary_language(self.config)
        return get_config_path().parent / f"initial_prompt_{lang}.txt"

    @rumps.timer(0.3)
    def _drain_main_thread_queue(self, _):
        """Drain logic app's main-thread job queue so UI updates run on the main thread."""
        app = self.main_app
        if not hasattr(app, "_main_thread_queue"):
            return
        while True:
            try:
                job = app._main_thread_queue.get_nowait()
            except queue.Empty:
                break
            fn, args, kwargs = job
            try:
                fn(*args, **kwargs)
            except Exception as e:
                log_error(f"Main thread job failed: {e}")

    @rumps.timer(1.0)
    def _watch_prompt_file(self, _):
        """Watches initial_prompt_{lang}.txt for manual edits by the user."""
        lang = get_primary_language(self.config)
        prompt_path = self._get_prompt_path(lang)
        if not prompt_path.exists():
            return
            
        try:
            mtime = prompt_path.stat().st_mtime
            if getattr(self, "_last_prompt_mtime", 0.0) == 0.0 or getattr(self, "_last_prompt_path", None) != prompt_path:
                self._last_prompt_mtime = mtime
                self._last_prompt_path = prompt_path
                return
                
            if mtime > self._last_prompt_mtime:
                self._last_prompt_mtime = mtime
                with open(prompt_path, "r", encoding="utf-8") as f:
                    new_prompt = f.read().strip()
                
                custom_dict = self.config.get("custom_prompts", {})
                previous = custom_dict.get(lang, "")
                
                if previous != new_prompt:
                    if previous:
                        prev_dict = self.config.get("previous_prompts", {})
                        prev_dict[lang] = previous
                        self.config["previous_prompts"] = prev_dict
                        
                    custom_dict[lang] = new_prompt
                    self.config["custom_prompts"] = custom_dict
                    self.config["initial_prompt"] = new_prompt
                    
                    self.save_config()
                    self.main_app.load_config_data(self.config)
                    log_info(f"Initial prompt updated manually for {lang.upper()}.")
                    self.main_app.notify("Настройки", f"Подсказка для {lang.upper()} обновлена!")
        except Exception as e:
            log_error(f"Error checking prompt file: {e}")

    @rumps.timer(5.0)
    def _check_accessibility_status(self, _):
        """Periodically checks accessibility status and auto-starts hotkeys when granted."""
        try:
            trusted = is_accessibility_trusted()
            if trusted != self._accessibility_granted:
                self._accessibility_granted = trusted
                self._update_accessibility_menu_item()
                if trusted:
                    log_info("Accessibility permission detected — restarting hotkey listener.")
                    try:
                        self.main_app.hotkey_handler.restart()
                        self.main_app.notify("Доступ разрешен", "Горячие клавиши активированы.")
                    except Exception as e:
                        log_error(f"Failed to restart hotkey listener: {e}")
        except Exception as e:
            log_error(f"Error in accessibility status check: {e}")

    def _update_accessibility_menu_item(self) -> None:
        """Update the accessibility status menu item text."""
        if self._accessibility_item is None:
            return
        if self._accessibility_granted:
            self._accessibility_item.title = "✅ Accessibility Granted"
        else:
            self._accessibility_item.title = "⚠️ Accessibility Required"

    def _on_accessibility_click(self, _) -> None:
        """Handle click on accessibility menu item: open settings if not granted."""
        if not self._accessibility_granted:
            open_accessibility_settings()
        else:
            self.main_app.notify("Доступ", "Права доступа уже предоставлены.")

    def setup_menu(self):
        # Accessibility status at the top
        self._accessibility_item = rumps.MenuItem("", callback=self._on_accessibility_click)
        self._update_accessibility_menu_item()
        self.menu.add(self._accessibility_item)
        self.menu.add(None)  # Separator

        # Model Selection
        current_model = self.config.get("model_name", "mlx-community/whisper-large-v3-turbo")

        self.menu.add("Model")
        for label, model_id in WHISPER_MODELS:
            # Start with download icon as placeholder; cache check will update it
            title = f"{_ICON_DOWNLOAD} {label}"
            item = rumps.MenuItem(title, callback=self.change_model)
            if model_id == current_model:
                item.state = 1
            self.menu["Model"].add(item)

        # Languages: primary (single) and additional (multiple)
        langs = ["ru", "en", "de", "es", "fr"]
        primary = get_primary_language(self.config)
        additional = self.config.get("additional_languages")
        if not isinstance(additional, list):
            additional = []
        # Backward compat: derive from old "languages" list
        if not additional:
            lang_list = self.config.get("languages", [])
            if isinstance(lang_list, list) and len(lang_list) > 1:
                additional = [str(x).lower().strip() for x in lang_list[1:] if x]

        self.menu.add("Primary Language")
        for lang in langs:
            item = rumps.MenuItem(lang.upper(), callback=self._change_primary_language)
            if lang == primary:
                item.state = 1
            self.menu["Primary Language"].add(item)

        self.menu.add("Additional Languages")
        for lang in langs:
            item = rumps.MenuItem(lang.upper(), callback=self._toggle_additional_language)
            if lang in additional:
                item.state = 1
            self.menu["Additional Languages"].add(item)

        # Sensitivity / Delays
        self.menu.add("Silence Delay")
        sensitivity_options = [("Fast (0.5s)", 0.5), ("Normal (1.0s)", 1.0), ("Slow (2.0s)", 2.0)]
        current_delay = self.config.get("silence_duration", 1.0)
        for title, val in sensitivity_options:
            item = rumps.MenuItem(title, callback=self.set_sensitivity)
            if (
                (val == 0.5 and current_delay <= 0.6)
                or (val == 1.0 and 0.6 < current_delay <= 1.2)
                or (val == 2.0 and current_delay > 1.2)
            ):
                item.state = 1
            self.menu["Silence Delay"].add(item)
            
        self.menu.add("Min Speech Duration")
        speech_options = [("Short (0.3s)", 0.3), ("Normal (1.0s)", 1.0), ("Long (2.0s)", 2.0)]
        current_speech = self.config.get("min_speech_duration", 1.0)
        for title, val in speech_options:
            item = rumps.MenuItem(title, callback=self.set_min_speech_duration)
            if (
                (val == 0.3 and current_speech <= 0.5)
                or (val == 1.0 and 0.5 < current_speech <= 1.5)
                or (val == 2.0 and current_speech > 1.5)
            ):
                item.state = 1
            self.menu["Min Speech Duration"].add(item)

        self.menu.add(None)  # Separator

        self.menu.add(rumps.MenuItem("Edit Config File", callback=self.open_config))
        self.menu.add(rumps.MenuItem("Open Log File", callback=self.open_log_file))
        self._last_phrases_parent = rumps.MenuItem("Last 5 phrases")
        self.menu.add(self._last_phrases_parent)
        self._refresh_last_phrases_submenu()
        self.menu.add(rumps.MenuItem("Edit Initial Prompt", callback=self.edit_initial_prompt))
        self.menu.add(rumps.MenuItem("Update Initial Prompt from History", callback=self.update_initial_prompt_from_history))
        self.menu.add(rumps.MenuItem("Revert Initial Prompt", callback=self.revert_initial_prompt))
        
        self.menu.add(None) # Separator

        # AI Editor toggle
        ai_editor_item = rumps.MenuItem("✦ AI Editor (Punctuation & Cleanup)", callback=self._toggle_ai_editor)
        ai_editor_item.state = 1 if self.config.get("ai_editor_enabled", False) else 0
        self.menu.add(ai_editor_item)
        self.menu.add(rumps.MenuItem("  ↳ Download AI Editor Model", callback=self._download_ai_model))

        self.menu.add(rumps.MenuItem("Transcribe Audio File...", callback=self.transcribe_audio_file))

        self.menu.add(rumps.MenuItem("Reload Configuration", callback=self.reload_config))
        self.menu.add(rumps.MenuItem("Check for Updates", callback=self.check_for_updates))

        # Autostart option
        autostart_item = rumps.MenuItem("Launch at Login", callback=self.toggle_autostart)
        autostart_item.state = 1 if self.config.get("autostart", False) else 0
        self.menu.add(autostart_item)

        self.menu.add(None)

    # ------------------------------------------------------------------
    # Whisper model cache check
    # ------------------------------------------------------------------

    def _start_model_cache_check(self) -> None:
        """Start a daemon thread that checks HuggingFace cache for all Whisper models."""
        t = threading.Thread(target=self._update_model_cache_indicators, daemon=True)
        t.start()

    def _update_model_cache_indicators(self) -> None:
        """Check each Whisper model against the local HF cache and update menu icons.

        Runs in a background thread; schedules UI updates on the main thread.
        """
        try:
            from huggingface_hub import snapshot_download  # type: ignore
        except ImportError:
            log_error("huggingface_hub not installed — cannot check model cache status.")
            return

        for label, model_id in WHISPER_MODELS:
            try:
                snapshot_download(repo_id=model_id, local_files_only=True)
                icon = _ICON_CACHED
            except Exception:
                icon = _ICON_DOWNLOAD

            new_title = f"{icon} {label}"

            def _apply(title: str = new_title, lbl: str = label) -> None:
                try:
                    for item in self.menu["Model"].values():
                        # Strip any existing icon prefix to compare base labels
                        base = item.title
                        for pfx in (_ICON_CACHED, _ICON_DOWNLOAD):
                            if base.startswith(pfx):
                                base = base[len(pfx):].lstrip()
                        if base == lbl:
                            item.title = title
                            break
                except Exception as exc:
                    log_error(f"Model cache indicator update failed for '{lbl}': {exc}")

            # Post to main-thread queue so rumps UI stays thread-safe
            if hasattr(self.main_app, "_main_thread_queue"):
                self.main_app._main_thread_queue.put((_apply, [], {}))
            else:
                _apply()

    def change_model(self, sender):
        # Strip cache-status icon prefix (e.g. "🟢 Turbo" → "Turbo")
        clean_label = sender.title
        for pfx in (_ICON_CACHED, _ICON_DOWNLOAD):
            if clean_label.startswith(pfx):
                clean_label = clean_label[len(pfx):].lstrip()

        model_id = {lbl: mid for lbl, mid in WHISPER_MODELS}.get(clean_label)
        if not model_id:
            log_error(f"change_model: unknown label '{clean_label}'")
            return

        log_info(f"Switching model to {model_id}")
        self.main_app.update_config({"model_name": model_id})

        # Update UI: uncheck all, then check the selected item
        for item in self.menu["Model"].values():
            if hasattr(item, "state"):
                item.state = 0  # type: ignore
        sender.state = 1

    def _change_primary_language(self, sender):
        new_lang = sender.title.lower()
        log_info(f"Setting primary language to {new_lang}")

        self.config["primary_language"] = new_lang
        self.main_app.update_config({"primary_language": new_lang})

        # Update UI: uncheck others in the "Primary Language" submenu
        for item in self.menu["Primary Language"].values():
            if hasattr(item, "state"):
                item.state = 0  # type: ignore
        sender.state = 1

        self._update_language_hint_and_prompt()
        self.save_config()
        self.main_app.load_config_data(self.config)

        # Reset mtime tracker for the new language file so we don't falsely trigger it
        self._last_prompt_path = None
        self._last_prompt_mtime = 0.0

    def _toggle_additional_language(self, sender):
        lang = sender.title.lower()
        additional = list(self.config.get("additional_languages") or [])
        if not additional and isinstance(self.config.get("languages"), list) and len(self.config["languages"]) > 1:
            additional = [str(x).lower().strip() for x in self.config["languages"][1:] if x]
        if lang in additional:
            additional.remove(lang)
        else:
            additional.append(lang)
        self.config["additional_languages"] = additional
        self.main_app.update_config({"additional_languages": additional})
        sender.state = 1 if lang in additional else 0
        log_info(f"Additional languages: {additional}")

        self._update_language_hint_and_prompt()
        self.save_config()
        self.main_app.load_config_data(self.config)

    def _update_language_hint_and_prompt(self):
        """Setup initial_prompt: use user's custom text if exists, else generate a fresh auto-hint."""
        prompts = {
            "ru": "Русский язык.",
            "en": "English language.",
            "de": "Deutscher Text.",
            "es": "Texto en español.",
            "fr": "Texte en français.",
        }
        primary = get_primary_language(self.config)
        additional = self.config.get("additional_languages") or []
        
        custom_dict = self.config.get("custom_prompts", {})
        if primary in custom_dict and custom_dict[primary].strip():
            # Apply user's custom prompt for this language
            final_prompt = custom_dict[primary].strip()
        else:
            # Build and write a new base auto-hint for this language
            main_prompt = prompts.get(primary, "")
            extra_prompts_list = [prompts.get(str(l), "") for l in additional if prompts.get(str(l))]
            extra_prompts = " ".join(extra_prompts_list)
            final_prompt = f"{main_prompt} {extra_prompts}".strip()
            
            # Save it so it appears correctly if the user clicks "Edit Initial Prompt"
            custom_dict[primary] = final_prompt
            self.config["custom_prompts"] = custom_dict
            
            try:
                prompt_path = self._get_prompt_path(primary)
                with open(prompt_path, "w", encoding="utf-8") as f:
                    f.write(final_prompt)
            except Exception as e:
                log_error(f"Failed to auto-write warmup prompt for {primary}: {e}")
            
        self.config["initial_prompt"] = final_prompt

    def set_sensitivity(self, sender):
        delay_map = {"Fast (0.5s)": 0.5, "Normal (1.0s)": 1.0, "Slow (2.0s)": 2.0}
        val = delay_map.get(sender.title, 1.0)
        self.config["silence_duration"] = val
        self.save_config()

        for item in self.menu["Silence Delay"].values():
            item.state = 0
        sender.state = 1

        # Update app settings
        self.main_app.update_recorder_settings(silence_duration=val)

    def set_min_speech_duration(self, sender):
        speech_map = {"Short (0.3s)": 0.3, "Normal (1.0s)": 1.0, "Long (2.0s)": 2.0}
        val = speech_map.get(sender.title, 1.0)
        self.config["min_speech_duration"] = val
        self.save_config()

        for item in self.menu["Min Speech Duration"].values():
            item.state = 0
        sender.state = 1

        # Update app settings
        self.main_app.update_recorder_settings(min_speech_duration=val)

    def _refresh_last_phrases_submenu(self) -> None:
        """Rebuild the 'Last 5 phrases' submenu from the phrase history file."""
        parent = self._last_phrases_parent
        for key in list(parent.keys()):
            del parent[key]
        phrases = get_last_phrases(5)
        if not phrases:
            parent.add(rumps.MenuItem("No phrases yet", callback=None))
            return
        max_title_len = 56
        for _ts, text in phrases:
            title = (text[: max_title_len - 1] + "…") if len(text) > max_title_len else text
            if not title:
                title = "(empty)"
            parent.add(
                rumps.MenuItem(f"📋 {title}", callback=lambda s, t=text: copy_to_clipboard(t))
            )

    def refresh_last_phrases_submenu(self) -> None:
        """Public method for app to refresh the Last 5 phrases submenu after a new phrase is saved."""
        self._refresh_last_phrases_submenu()

    def open_config(self, _: rumps.MenuItem) -> None:
        """Opens config.json in the default editor (no shell)."""
        subprocess.run(["open", str(get_config_path())], check=True)

    def open_log_file(self, _: rumps.MenuItem) -> None:
        """Opens the app log file in the default editor (all recognition requests are logged there)."""
        log_path = get_log_file_path()
        if log_path.exists():
            subprocess.run(["open", str(log_path)], check=True)
        else:
            log_info("Log file not created yet (no logs written).")
            self.main_app.notify("Лог-файл", "Файл лога еще не создан. Он появится после первой записи.")

    def reload_config(self, _: rumps.MenuItem) -> None:
        """Reloads config from disk and refreshes the menu."""
        self.main_app.load_config(str(get_config_path()))
        self.main_app.notify("Конфигурация", "Настройки успешно перезагружены.")
        # Re-setup menu (simplest way to update states)
        self.menu.clear()
        self.setup_menu()

    def edit_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Opens the language-specific initial prompt in a text editor."""
        lang = get_primary_language(self.config)
        current_prompt = str(self.config.get("initial_prompt", ""))
            
        prompt_path = self._get_prompt_path(lang)
        try:
            with open(prompt_path, "w", encoding="utf-8") as f:
                f.write(current_prompt)
            self._last_prompt_mtime = prompt_path.stat().st_mtime
            self._last_prompt_path = prompt_path
            subprocess.run(["open", "-t", str(prompt_path)], check=False)
        except OSError as e:
            log_error(f"Failed to open initial prompt for editing: {e}")

    def update_initial_prompt_from_history(self, _: rumps.MenuItem) -> None:
        """Builds a new initial prompt from recent phrase history and applies it."""
        terms_hint = generate_terms_hint_from_history()
        if not terms_hint:
            self.main_app.notify("Настройки", "Не удалось сгенерировать подсказки из истории.")
            return

        lang = get_primary_language(self.config)
        custom_dict = self.config.get("custom_prompts", {})
        previous = custom_dict.get(lang, "")
        
        current_prompt = str(self.config.get("initial_prompt", "")).strip()
        new_prompt = f"{current_prompt}\n{terms_hint}".strip()
        
        if previous:
            prev_dict = self.config.get("previous_prompts", {})
            prev_dict[lang] = previous
            self.config["previous_prompts"] = prev_dict

        custom_dict[lang] = new_prompt
        self.config["custom_prompts"] = custom_dict
        self.config["initial_prompt"] = new_prompt
        
        prompt_path = self._get_prompt_path(lang)
        try:
            with open(prompt_path, "w", encoding="utf-8") as f:
                f.write(new_prompt)
        except Exception:
            pass

        self.save_config()
        self.main_app.load_config_data(self.config)
        self.main_app.notify("Настройки", f"Термины добавлены для {lang.upper()}.")

    def revert_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Reverts initial_prompt to the previous version if available."""
        lang = get_primary_language(self.config)
        previous_prompts = self.config.get("previous_prompts", {})
        prev = previous_prompts.get(lang, "")
        
        if not prev:
            self.main_app.notify("Настройки", f"Нет предыдущей версии подсказки для {lang.upper()}.")
            return

        custom_dict = self.config.get("custom_prompts", {})
        current = custom_dict.get(lang, "")
        
        custom_dict[lang] = prev
        previous_prompts[lang] = current
        
        self.config["custom_prompts"] = custom_dict
        self.config["previous_prompts"] = previous_prompts
        self.config["initial_prompt"] = prev
        
        prompt_path = self._get_prompt_path(lang)
        try:
            with open(prompt_path, "w", encoding="utf-8") as f:
                f.write(prev)
        except Exception:
            pass

        self.save_config()
        self.main_app.load_config_data(self.config)
        self.main_app.notify("Настройки", f"Подсказка для {lang.upper()} восстановлена.")

    def transcribe_audio_file(self, _: rumps.MenuItem) -> None:
        """Opens a file selection dialog and starts file transcription."""
        if self.main_app.is_recording or self.main_app.is_processing:
            self.main_app.notify("Занято", "Пожалуйста, дождитесь окончания текущего распознавания.")
            return

        try:
            # osascript dialog to pick a file
            script = 'set theFile to choose file with prompt "Select Audio File" of type {"public.audio", "wav", "m4a"} \n POSIX path of theFile'
            result = subprocess.check_output(['osascript', '-e', script])
            file_path = result.decode('utf-8').strip()
            
            if file_path and os.path.exists(file_path):
                self.main_app.start_file_transcription(file_path)
            
        except subprocess.CalledProcessError:
            # User canceled the dialog
            pass
        except Exception as e:
            log_error(f"Error selecting audio file: {e}")
            self.main_app.notify("Ошибка", "Не удалось открыть выбор файла.")

    def save_config(self) -> None:
        """Persists current config to config.json."""
        save_config_to_disk(self.config)

    def check_for_updates(self, _: rumps.MenuItem) -> None:
        """Check GitHub for a newer release; notify and open release page if found."""
        if check_for_update(open_url_if_new=True):
            return
        self.main_app.notify("Обновления", "У вас установлена последняя версия.")

    def _toggle_ai_editor(self, sender) -> None:
        """Toggle the AI Editor on/off and persist the setting."""
        new_state = not (sender.state == 1)
        sender.state = 1 if new_state else 0
        self.main_app.update_config({"ai_editor_enabled": new_state})
        log_info(f"AI Editor {'enabled' if new_state else 'disabled'}.")
        if new_state:
            self.main_app.notify("AI Editor", "Загрузка модели... Вы получите уведомление о готовности.")
        else:
            self.main_app.notify("AI Editor", "Умная очистка отключена.")

    def _download_ai_model(self, _) -> None:
        """Open a new Terminal window and run the download script with visible progress."""
        script_path = str(get_config_path().parent / "scripts" / "download_ai_model.py")
        venv_python = str(get_config_path().parent / "venv" / "bin" / "python")
        python_bin = venv_python if os.path.exists(venv_python) else sys.executable

        import shlex
        q_python = shlex.quote(python_bin)
        q_script = shlex.quote(script_path)
        
        # AppleScript: open a new Terminal tab and run the download script
        applescript = (
            'tell application "Terminal"\n'
            "    activate\n"
            f'    do script "{q_python} {q_script}"\n'
            "end tell"
        )
        try:
            subprocess.run(["osascript", "-e", applescript], check=False)
            self.main_app.notify("AI Editor", "Загрузка начата в Терминале. Перезапустите приложение после завершения.")
        except Exception as e:
            log_error(f"Failed to open Terminal for download: {e}")
            self.main_app.notify("AI Editor", "Запустите вручную: python scripts/download_ai_model.py")

    def toggle_autostart(self, sender):
        current_state = sender.state == 1
        new_state = not current_state

        # Get the path to the .app bundle: launcher sets CLICK_N_SPEAK_APP; py2app sets sys.frozen
        app_path = os.environ.get("CLICK_N_SPEAK_APP")
        if not app_path:
            if getattr(sys, "frozen", False) == "macosx_app":
                app_path = os.path.abspath(os.path.join(sys.executable, "../../.."))
            else:
                app_path = os.path.abspath(sys.argv[0])

        app_name = "Click-n-speak"
        safe_path = escape_applescript_string(app_path)
        safe_name = escape_applescript_string(app_name)

        try:
            if new_state:
                cmd = f'tell application "System Events" to make login item at end with properties {{path:"{safe_path}", name:"{safe_name}", hidden:false}}'
                subprocess.run(["osascript", "-e", cmd], check=True)
                self.main_app.notify("Автозапуск", "Приложение будет запускаться при входе в систему.")
            else:
                cmd = f'tell application "System Events" to delete login item "{safe_name}"'
                subprocess.run(["osascript", "-e", cmd], check=True)
                self.main_app.notify("Автозапуск", "Автозапуск отключен.")

            sender.state = 1 if new_state else 0
            self.config["autostart"] = new_state
            self.save_config()

        except Exception as e:
            log_error(f"Error toggling autostart: {e}")
            self.main_app.notify("Ошибка", "Не удалось обновить объекты входа.")

    def set_status(self, recording=False, processing=False):
        # Make the state highly visible in the menu bar; language from primary setting.
        s = get_ui_strings(get_primary_language(self.config))
        if recording:
            self.title = s["menu_recording"]
        elif processing:
            self.title = s["menu_processing"]
        else:
            self.title = ""
