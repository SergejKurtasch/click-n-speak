import rumps
import json
import os
import sys
import subprocess
from .utils import send_notification, log_info, log_error

class ClickNSpeakApp(rumps.App):
    def __init__(self, main_app):
        super(ClickNSpeakApp, self).__init__("🎙️")
        self.main_app = main_app
        self.config = main_app.config
        
        # Build Menu
        self.setup_menu()
        
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
        
        # Languages
        langs = ["ru", "en", "de", "es", "fr"]
        lang_list = self.config.get("languages", ["ru"])
        primary = lang_list[0] if lang_list else "ru"
        
        self.menu.add("Primary Language")
        for l in langs:
            item = rumps.MenuItem(l.upper(), callback=self.change_language)
            if l == primary:
                item.state = 1
            self.menu["Primary Language"].add(item)
        
        # Sensitivity / Delays
        self.menu.add("Sensitivity")
        sensitivity_options = [
            ("Fast (0.5s)", 0.5),
            ("Normal (1.0s)", 1.0),
            ("Slow (2.0s)", 2.0)
        ]
        current_delay = self.config.get("silence_duration", 1.0)
        for title, val in sensitivity_options:
            item = rumps.MenuItem(title, callback=self.set_sensitivity)
            if (val == 0.5 and current_delay <= 0.6) or \
               (val == 1.0 and 0.6 < current_delay <= 1.2) or \
               (val == 2.0 and current_delay > 1.2):
                item.state = 1
            self.menu["Sensitivity"].add(item)
        self.menu.add(None) # Separator
        
        self.menu.add(rumps.MenuItem("Edit Config File", callback=self.open_config))
        self.menu.add(rumps.MenuItem("Reload Configuration", callback=self.reload_config))
        
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
            "Large": "mlx-community/whisper-large-v3-mlx"
        }
        new_model = model_map.get(sender.title)
        if not new_model:
            return

        log_info(f"Switching model to {new_model}")
        self.main_app.update_config({"model_name": new_model})
        
        # Update UI: uncheck others in the "Model" submenu
        for item in self.menu["Model"].values():
            if hasattr(item, "state"):
                item.state = 0 # type: ignore
        sender.state = 1

    def change_language(self, sender):
        new_lang = sender.title.lower()
        log_info(f"Setting primary language to {new_lang}")
        
        # Get current languages and update the first one
        current_langs = self.config.get("languages", ["ru"])
        if current_langs:
            current_langs[0] = new_lang
        else:
            current_langs = [new_lang]
            
        self.main_app.update_config({"languages": current_langs})
        
        # Update UI: uncheck others in the "Primary Language" submenu
        for item in self.menu["Primary Language"].values():
            if hasattr(item, "state"):
                item.state = 0 # type: ignore
        sender.state = 1
        
        # Update initial prompt based on languages
        prompts = {
            "ru": "Русский язык.",
            "en": "English language.",
            "de": "Deutscher Text.",
            "es": "Texto en español.",
            "fr": "Texte en français."
        }
        main_prompt = prompts.get(new_lang, "")
        # Get up to 2 extra languages from config for context
        other_langs = []
        cl = self.config.get("languages", ["ru"])
        if isinstance(cl, list) and len(cl) > 1:
            other_langs = cl[1:3]
            
        extra_prompts_list = []
        for l in other_langs:
            p = prompts.get(str(l))
            if p:
                extra_prompts_list.append(p)
        extra_prompts = " ".join(extra_prompts_list)
        
        self.config["initial_prompt"] = f"{main_prompt} {extra_prompts}".strip()
        self.main_app.load_config_data(self.config)

    def set_sensitivity(self, sender):
        delay_map = {
            "Fast (0.5s)": 0.5,
            "Normal (1.0s)": 1.0,
            "Slow (2.0s)": 2.0
        }
        val = delay_map.get(sender.title, 1.0)
        self.config["silence_duration"] = val
        self.save_config()
        
        for item in self.menu["Sensitivity"].values():
            item.state = 0
        sender.state = 1
        
        # Update app settings
        self.main_app.update_recorder_settings(silence_duration=val)

    def open_config(self, _):
        config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'config.json')
        os.system(f'open "{config_path}"')

    def reload_config(self, _):
        config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'config.json')
        self.main_app.load_config(config_path)
        send_notification("Click-n-speak", "Config Reloaded", "New settings applied.")
        # Re-setup menu (simplest way to update states)
        self.menu.clear()
        self.setup_menu()

    def save_config(self):
        try:
            config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'config.json')
            with open(config_path, "w") as f:
                json.dump(self.config, f, indent=4)
        except Exception as e:
            log_error(f"Error saving config: {e}")

    def toggle_autostart(self, sender):
        current_state = sender.state == 1
        new_state = not current_state
        
        # Get the path to the .app bundle if running as a bundle, or the script otherwise
        # In a py2app bundle, sys.frozen is set, but we want the .app path
        if getattr(sys, "frozen", False) == "macosx_app":
            # Path to Click-n-speak.app
            app_path = os.path.abspath(os.path.join(sys.executable, "../../.."))
        else:
            # Fallback for development (not very useful for actual login items, but for testing)
            app_path = os.path.abspath(sys.argv[0])
            
        app_name = "Click-n-speak"
        
        try:
            if new_state:
                cmd = f'tell application "System Events" to make login item at end with properties {{path:"{app_path}", name:"{app_name}", hidden:false}}'
                subprocess.run(['osascript', '-e', cmd], check=True)
                send_notification(app_name, "Autostart Enabled", "The app will launch at login.")
            else:
                cmd = f'tell application "System Events" to delete login item "{app_name}"'
                subprocess.run(['osascript', '-e', cmd], check=True)
                send_notification(app_name, "Autostart Disabled", "The app will no longer launch at login.")
            
            sender.state = 1 if new_state else 0
            self.config["autostart"] = new_state
            self.save_config()
            
        except Exception as e:
            log_error(f"Error toggling autostart: {e}")
            send_notification(app_name, "Error", "Could not update login items.")

    def set_status(self, recording=False, processing=False):
        if recording:
            self.title = "🔴"
        elif processing:
            self.title = "⏳"
        else:
            self.title = "🎙️"
