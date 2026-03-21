import os
import queue
import subprocess
import sys

import rumps

from .log_analyzer import generate_terms_hint_from_log
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
    log_error,
    log_info,
    save_config_to_disk,
    send_notification,
)


class ClickNSpeakApp(rumps.App):
    def __init__(self, main_app):
        icon_path = str(get_menu_icon_path())
        super(ClickNSpeakApp, self).__init__("", icon=icon_path)
        self.main_app = main_app
        self.config = main_app.config

        # Build Menu
        self.setup_menu()

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

    def setup_menu(self):
        # Model Selection
        models = ["base", "small", "medium", "large"]
        current_model = self.config.get("model_name", "").lower()

        self.menu.add("Model")
        for m in models:
            item = rumps.MenuItem(m.capitalize(), callback=self.change_model)
            if m in current_model:
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
        self.menu.add("Sensitivity")
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
            self.menu["Sensitivity"].add(item)
        self.menu.add(None)  # Separator

        self.menu.add(rumps.MenuItem("Edit Config File", callback=self.open_config))
        self.menu.add(rumps.MenuItem("Open Log File", callback=self.open_log_file))
        self._last_phrases_parent = rumps.MenuItem("Last 5 phrases")
        self.menu.add(self._last_phrases_parent)
        self._refresh_last_phrases_submenu()
        self.menu.add(rumps.MenuItem("Show Initial Prompt", callback=self.show_initial_prompt))
        self.menu.add(rumps.MenuItem("Update Initial Prompt from Logs", callback=self.update_initial_prompt_from_logs))
        self.menu.add(rumps.MenuItem("Revert Initial Prompt", callback=self.revert_initial_prompt))
        self.menu.add(rumps.MenuItem("Reload Configuration", callback=self.reload_config))
        self.menu.add(rumps.MenuItem("Check for Updates", callback=self.check_for_updates))

        # Autostart option
        autostart_item = rumps.MenuItem("Launch at Login", callback=self.toggle_autostart)
        autostart_item.state = 1 if self.config.get("autostart", False) else 0
        self.menu.add(autostart_item)

        self.menu.add(None)

    def change_model(self, sender):
        model_map = {
            "Base": "mlx-community/whisper-base-mlx",
            "Small": "mlx-community/whisper-small-mlx",
            "Medium": "mlx-community/whisper-medium-mlx",
            "Large": "mlx-community/whisper-large-v3-mlx",
        }
        new_model = model_map.get(sender.title)
        if not new_model:
            return

        log_info(f"Switching model to {new_model}")
        self.main_app.update_config({"model_name": new_model})

        # Update UI: uncheck others in the "Model" submenu
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
        """Build language_hint from primary + additional and refresh initial_prompt."""
        prompts = {
            "ru": "Русский язык.",
            "en": "English language.",
            "de": "Deutscher Text.",
            "es": "Texto en español.",
            "fr": "Texte en français.",
        }
        primary = get_primary_language(self.config)
        additional = self.config.get("additional_languages") or []
        main_prompt = prompts.get(primary, "")
        extra_prompts_list = [prompts.get(str(l), "") for l in additional if prompts.get(str(l))]
        extra_prompts = " ".join(extra_prompts_list)
        language_hint = f"{main_prompt} {extra_prompts}".strip()
        self.config["language_hint"] = language_hint
        self.config["initial_prompt"] = build_initial_prompt(self.config)

    def set_sensitivity(self, sender):
        delay_map = {"Fast (0.5s)": 0.5, "Normal (1.0s)": 1.0, "Slow (2.0s)": 2.0}
        val = delay_map.get(sender.title, 1.0)
        self.config["silence_duration"] = val
        self.save_config()

        for item in self.menu["Sensitivity"].values():
            item.state = 0
        sender.state = 1

        # Update app settings
        self.main_app.update_recorder_settings(silence_duration=val)

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
            send_notification("Click-n-speak", "Log file", "Log file not created yet. It will appear after the app logs something.")

    def reload_config(self, _: rumps.MenuItem) -> None:
        """Reloads config from disk and refreshes the menu."""
        self.main_app.load_config(str(get_config_path()))
        send_notification("Click-n-speak", "Config Reloaded", "New settings applied.")
        # Re-setup menu (simplest way to update states)
        self.menu.clear()
        self.setup_menu()

    def show_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Shows the current initial prompt in a read-only window."""
        current_prompt = str(self.config.get("initial_prompt", ""))
        previous_prompt = str(self.config.get("previous_initial_prompt", ""))
        if previous_prompt:
            body = f"Current initial prompt:\n\n{current_prompt}\n\nPrevious version:\n\n{previous_prompt}"
        else:
            body = f"Current initial prompt:\n\n{current_prompt}"
        window = rumps.Window(
            message=body,
            title="Initial Prompt",
            default_text="",
            ok="Close",
            cancel=None,
        )
        window.run()

    def update_initial_prompt_from_logs(self, _: rumps.MenuItem) -> None:
        """Builds a new initial prompt from recent logs and applies it."""
        terms_hint = generate_terms_hint_from_log()
        if not terms_hint:
            send_notification(
                "Click-n-speak",
                "Initial Prompt",
                "Could not generate terms from logs. Speak more with technical terms and try again.",
            )
            return

        previous = str(self.config.get("initial_prompt", "")).strip()
        if previous:
            self.config["previous_initial_prompt"] = previous

        self.config["terms_hint"] = terms_hint
        self.config["initial_prompt"] = build_initial_prompt(self.config)
        self.save_config()
        self.main_app.load_config_data(self.config)
        send_notification(
            "Click-n-speak",
            "Initial Prompt",
            "Initial prompt has been updated from logs.",
        )

    def revert_initial_prompt(self, _: rumps.MenuItem) -> None:
        """Reverts initial_prompt to the previous version if available."""
        previous_prompt = str(self.config.get("previous_initial_prompt", "")).strip()
        if not previous_prompt:
            send_notification(
                "Click-n-speak",
                "Initial Prompt",
                "No previous initial prompt to revert to.",
            )
            return

        current_prompt = str(self.config.get("initial_prompt", "")).strip()
        self.config["initial_prompt"] = previous_prompt
        self.config["previous_initial_prompt"] = current_prompt
        self.save_config()
        self.main_app.load_config_data(self.config)
        send_notification(
            "Click-n-speak",
            "Initial Prompt",
            "Initial prompt has been reverted to the previous version.",
        )

    def save_config(self) -> None:
        """Persists current config to config.json."""
        save_config_to_disk(self.config)

    def check_for_updates(self, _: rumps.MenuItem) -> None:
        """Check GitHub for a newer release; notify and open release page if found."""
        if check_for_update(open_url_if_new=True):
            return
        send_notification("Click-n-speak", "No updates", "You are running the latest version.")

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
                send_notification(app_name, "Autostart Enabled", "The app will launch at login.")
            else:
                cmd = f'tell application "System Events" to delete login item "{safe_name}"'
                subprocess.run(["osascript", "-e", cmd], check=True)
                send_notification(app_name, "Autostart Disabled", "The app will no longer launch at login.")

            sender.state = 1 if new_state else 0
            self.config["autostart"] = new_state
            self.save_config()

        except Exception as e:
            log_error(f"Error toggling autostart: {e}")
            send_notification(app_name, "Error", "Could not update login items.")

    def set_status(self, recording=False, processing=False):
        # Make the state highly visible in the menu bar; language from primary setting.
        s = get_ui_strings(get_primary_language(self.config))
        if recording:
            self.title = s["menu_recording"]
        elif processing:
            self.title = s["menu_processing"]
        else:
            self.title = ""
