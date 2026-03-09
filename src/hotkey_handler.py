from pynput import keyboard

class HotkeyHandler:
    def __init__(self, hotkey_str="<alt>+<space>", on_trigger=None):
        """
        hotkey_str: pynput style hotkey string.
        on_trigger: callback function to call when hotkey is pressed.
        """
        self.hotkey_str = hotkey_str
        self.on_trigger = on_trigger
        self.listener = None

    def _on_activate(self):
        print(f"Hotkey {self.hotkey_str} activated!")
        if self.on_trigger:
            self.on_trigger()

    def start(self):
        """Starts the global hotkey listener in a background thread."""
        self.listener = keyboard.GlobalHotKeys({
            self.hotkey_str: self._on_activate
        })
        self.listener.start()
        print(f"Listening for hotkey: {self.hotkey_str}")

    def stop(self):
        if self.listener:
            self.listener.stop()
