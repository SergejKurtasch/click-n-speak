import os
import sys
from pathlib import Path

_LABEL = "com.sergej.clicknspeak"
_PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{_LABEL}.plist"
_EXECUTABLE_NAME = "Click-n-speak"

_PLIST_TEMPLATE = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{executable}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
"""


def _get_executable() -> str | None:
    """Return absolute path to the app executable when running from a .app bundle."""
    bundle = os.environ.get("CLICK_N_SPEAK_APP")
    if bundle:
        return os.path.join(bundle, "Contents", "MacOS", _EXECUTABLE_NAME)
    if getattr(sys, "frozen", False):
        # py2app sets sys.executable to .../Click-n-speak.app/Contents/MacOS/Click-n-speak
        return os.path.abspath(sys.executable)
    return None


def is_launch_at_login_enabled() -> bool:
    return _PLIST_PATH.exists()


def set_launch_at_login(enabled: bool) -> None:
    """Enable or disable launch-at-login via a LaunchAgent plist.

    No TCC/Automation permission required — ~/Library/LaunchAgents is user-writable.
    Always rewrites the plist on enable so the executable path stays current
    if the app bundle is moved or rebuilt.

    Raises RuntimeError if called outside of a .app bundle (dev mode).
    """
    if enabled:
        executable = _get_executable()
        if not executable:
            raise RuntimeError("Not running from a .app bundle — cannot install LaunchAgent.")
        _PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
        _PLIST_PATH.write_text(
            _PLIST_TEMPLATE.format(label=_LABEL, executable=executable),
            encoding="utf-8",
        )
    else:
        if _PLIST_PATH.exists():
            _PLIST_PATH.unlink()
