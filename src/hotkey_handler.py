from pynput import keyboard

from .utils import log_info


class CompatGlobalHotKeys(keyboard.GlobalHotKeys):
    """GlobalHotKeys that accepts both (key, injected) and (key) from pynput darwin backend.

    On macOS, the darwin backend sometimes calls on_press(key) with one argument
    (e.g. NSSystemDefined/media key path in _darwin.py), which would cause
    TypeError with the base class signature _on_press(key, injected).
    """

    def _on_press(self, key, *args) -> None:
        injected = args[0] if len(args) >= 1 else False
        if not injected:
            for hotkey in self._hotkeys:
                hotkey.press(self.canonical(key))

    def _on_release(self, key, *args) -> None:
        injected = args[0] if len(args) >= 1 else False
        if not injected:
            for hotkey in self._hotkeys:
                hotkey.release(self.canonical(key))


class HotkeyHandler:
    def __init__(self, hotkey_str="<alt>+<space>", on_trigger=None):
        """
        hotkey_str: pynput style hotkey string.
        on_trigger: callback function to call when hotkey is pressed.
        """
        self.hotkey_str = hotkey_str
        self.on_trigger = on_trigger
        self.listener = None

    def _on_activate(self) -> None:
        log_info(f"Hotkey {self.hotkey_str} activated!")
        if self.on_trigger:
            self.on_trigger()

    def start(self) -> None:
        """Starts the global hotkey listener in a background thread."""
        self.listener = CompatGlobalHotKeys({self.hotkey_str: self._on_activate})
        self.listener.start()
        log_info(f"Listening for hotkey: {self.hotkey_str}")

    def stop(self):
        if self.listener:
            self.listener.stop()
            self.listener = None

    def restart(self) -> None:
        """Stop the current listener (if any) and start a fresh one."""
        self.stop()
        self.start()
