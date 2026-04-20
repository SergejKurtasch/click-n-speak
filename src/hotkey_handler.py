import threading

from pynput import keyboard
from pynput.keyboard import Key, KeyCode

from .utils import log_error, log_info


class CompatGlobalHotKeys(keyboard.GlobalHotKeys):
    """GlobalHotKeys that accepts both (key, injected) and (key) from pynput darwin backend.

    On macOS, the darwin backend sometimes calls on_press(key) with one argument
    (e.g. NSSystemDefined/media key path in _darwin.py), which would cause
    TypeError with the base class signature _on_press(key, injected).

    Also overrides canonical() to skip TSMGetInputSourceProperty for KeyCode objects.
    On macOS 15+ (Darwin 25+), TSMGetInputSourceProperty asserts it runs on the main
    thread; pynput calls it from the CGEventTap callback thread → EXC_BREAKPOINT crash.
    Our hotkeys use only Key.* members (alt, space) so KeyCode normalization is unused.
    """

    def canonical(self, key):
        if isinstance(key, KeyCode):
            # Skip TSM-based normalization — crashes on macOS 15+ from non-main thread.
            return key
        return super().canonical(key)

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
    def __init__(self, hotkey_str="<alt>+<space>", on_trigger=None, on_tap_failed=None):
        self.hotkey_str = hotkey_str
        self.on_trigger = on_trigger
        self.on_tap_failed = on_tap_failed
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
        threading.Thread(target=self._check_start_health, daemon=True).start()

    def _check_start_health(self) -> None:
        """Detect silent CGEventTap failure (e.g. missing Input Monitoring permission)."""
        import time
        # Poll with backoff: CGEventTap failure causes listener to exit quickly,
        # but on a loaded system initialisation can take >0.5s — avoid false positives.
        for delay in (0.2, 0.5, 1.0):
            time.sleep(delay)
            if self.listener and self.listener.running:
                return  # healthy
        if self.listener and not self.listener.running:
            log_error(
                "Hotkey listener exited immediately after start — CGEventTap "
                "creation likely failed. Add Click-n-speak to "
                "Privacy & Security → Input Monitoring."
            )
            if self.on_tap_failed:
                self.on_tap_failed()

    def is_listener_alive(self) -> bool:
        """Return True if the pynput listener thread is currently running."""
        return self.listener is not None and self.listener.running

    def stop(self):
        if self.listener:
            self.listener.stop()
            self.listener = None

    def restart(self) -> None:
        """Stop the current listener (if any) and start a fresh one."""
        self.stop()
        self.start()
