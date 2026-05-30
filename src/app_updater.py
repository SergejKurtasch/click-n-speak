"""
src/app_updater.py

In-app update manager: background download, staging, and relaunch.

Flow:
  AppUpdater.start_download_and_stage()
      → child process downloads .dmg via HTTP streaming
      → parent mounts .dmg, copies .app to /Applications/Click-n-speak.app.new
      → on_staged() callback fires (main thread, via _main_thread_queue)

  AppUpdater.swap_and_launch()
      → writes a bash helper that waits for this PID to exit, then mv .app.new
        over .app, and relaunches
      → returns; caller should quit the app normally

  check_staged_update_on_launch()
      → synchronous; reads /Applications/Click-n-speak.app.new version
      → if version > current: returns UpdateInfo (show "Restart to apply")
      → if version <= current (already installed): removes .new, returns None
"""

import logging
import multiprocessing
import os
import plistlib
import queue
import shutil
import stat
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Callable, Optional

from .updater import UpdateInfo, _parse_version, get_current_version
from .utils import log_error, log_info, log_warning

logger = logging.getLogger(__name__)

APP_NAME = "Click-n-speak.app"
INSTALL_DIR = Path("/Applications")
STAGED_PATH = INSTALL_DIR / (APP_NAME[:-4] + ".app.new")  # /Applications/Click-n-speak.app.new
UPDATES_DIR = Path.home() / "Library" / "Application Support" / "Click-n-speak" / "updates"

_DOWNLOAD_CHUNK = 256 * 1024   # 256 KB
_PROGRESS_INTERVAL = 0.2       # seconds between progress queue pushes
_MOUNT_TIMEOUT = 30.0          # seconds for hdiutil attach
_COPY_TIMEOUT = 60.0           # seconds for .app copy


# ---------------------------------------------------------------------------
# Child-process download worker (no imports from parent — spawn-safe)
# ---------------------------------------------------------------------------

def _download_worker(url: str, dest: str, progress_q, result_q) -> None:
    """Runs in a child process. Downloads url → dest, reports progress."""
    import urllib.request
    import os

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Click-n-speak/updater"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            last_report = 0.0
            tmp = dest + ".part"
            with open(tmp, "wb") as f:
                while True:
                    chunk = resp.read(_DOWNLOAD_CHUNK)
                    if not chunk:
                        break
                    f.write(chunk)
                    done += len(chunk)
                    now = time.monotonic()
                    if now - last_report >= _PROGRESS_INTERVAL:
                        try:
                            progress_q.put_nowait((done, total))
                        except Exception:
                            pass
                        last_report = now
            os.replace(tmp, dest)
        result_q.put(("ok", dest))
    except Exception as e:
        try:
            os.unlink(dest + ".part")
        except OSError:
            pass
        result_q.put(("error", str(e)))


# ---------------------------------------------------------------------------
# Staging helpers (parent process, runs in a daemon thread)
# ---------------------------------------------------------------------------

def _read_bundle_version(app_path: Path) -> Optional[str]:
    plist = app_path / "Contents" / "Info.plist"
    if not plist.exists():
        return None
    try:
        with open(plist, "rb") as f:
            data = plistlib.load(f)
        return data.get("CFBundleShortVersionString") or data.get("CFBundleVersion")
    except (OSError, plistlib.InvalidFileException) as e:
        log_error(f"app_updater: could not read plist at {plist}: {e}")
        return None


def _mount_dmg(dmg_path: Path) -> Optional[Path]:
    """Mount dmg and return the mount-point path, or None on failure."""
    mount_point = Path(tempfile.mkdtemp(prefix="cns-update-"))
    try:
        result = subprocess.run(
            [
                "hdiutil", "attach",
                "-nobrowse", "-quiet",
                "-mountpoint", str(mount_point),
                str(dmg_path),
            ],
            timeout=_MOUNT_TIMEOUT,
            capture_output=True,
        )
        if result.returncode != 0:
            log_error(f"hdiutil attach failed: {result.stderr.decode(errors='replace')}")
            mount_point.rmdir()
            return None
        return mount_point
    except (subprocess.TimeoutExpired, OSError) as e:
        log_error(f"hdiutil attach error: {e}")
        try:
            mount_point.rmdir()
        except OSError:
            pass
        return None


def _detach_dmg(mount_point: Path) -> None:
    try:
        subprocess.run(
            ["hdiutil", "detach", str(mount_point), "-quiet"],
            timeout=10,
            capture_output=True,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        log_warning(f"hdiutil detach failed (non-fatal): {e}")


def _find_app_in_mount(mount_point: Path) -> Optional[Path]:
    for item in mount_point.iterdir():
        if item.suffix == ".app":
            return item
    return None


def _copy_app_to_staged(src: Path, dest: Path) -> bool:
    """Copy src .app bundle to dest atomically via a sibling tmp then rename."""
    tmp_dest = dest.parent / (dest.name + ".copying")
    try:
        if tmp_dest.exists():
            shutil.rmtree(tmp_dest)
        shutil.copytree(str(src), str(tmp_dest), symlinks=True)
        # Remove quarantine attribute so Gatekeeper doesn't block the new build.
        # Bounded by _COPY_TIMEOUT so a hung xattr can't freeze the staging thread
        # (and with it the update state machine) indefinitely.
        try:
            subprocess.run(
                ["xattr", "-dr", "com.apple.quarantine", str(tmp_dest)],
                capture_output=True,
                timeout=_COPY_TIMEOUT,
            )
        except subprocess.TimeoutExpired as e:
            log_warning(f"app_updater: xattr cleanup timed out (non-fatal): {e}")
        if dest.exists():
            shutil.rmtree(dest)
        tmp_dest.rename(dest)
        return True
    except (OSError, shutil.Error) as e:
        log_error(f"app_updater: copy failed: {e}")
        try:
            if tmp_dest.exists():
                shutil.rmtree(tmp_dest)
        except OSError:
            pass
        return False


def _copy_with_admin(src: Path, dest: Path) -> bool:
    """Fallback: copy via osascript with administrator privileges."""
    log_info("app_updater: falling back to privileged copy via osascript")
    script = (
        f'do shell script "rm -rf {shlex_quote(str(dest))} && '
        f'cp -R {shlex_quote(str(src))} {shlex_quote(str(dest))}" '
        f'with administrator privileges'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            timeout=120,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, OSError) as e:
        log_error(f"Privileged copy failed: {e}")
        return False


def shlex_quote(s: str) -> str:
    import re
    if re.search(r"[^\w@%+=:,./-]", s):
        return "'" + s.replace("'", "'\\''") + "'"
    return s or "''"


# ---------------------------------------------------------------------------
# Staged-update check (called at startup, before network)
# ---------------------------------------------------------------------------

def check_staged_update_on_launch() -> Optional[UpdateInfo]:
    """Check if a staged .app.new is newer than the running version.

    Returns UpdateInfo if restart is still needed, None otherwise.
    Deletes .app.new if it is not newer (already installed or stale).
    """
    if not STAGED_PATH.exists():
        return None

    staged_version = _read_bundle_version(STAGED_PATH)
    current_version = get_current_version()

    if staged_version is None:
        log_warning(f"app_updater: staged .app has no readable version — removing.")
        shutil.rmtree(STAGED_PATH, ignore_errors=True)
        return None

    if current_version and _parse_version(staged_version) <= _parse_version(current_version):
        log_info(
            f"app_updater: staged version {staged_version} <= current {current_version} "
            f"— update already applied, removing staged copy."
        )
        shutil.rmtree(STAGED_PATH, ignore_errors=True)
        return None

    log_info(f"app_updater: staged update {staged_version} waiting to be applied.")
    return UpdateInfo.staged(staged_version)


# ---------------------------------------------------------------------------
# AppUpdater — manages the download child process
# ---------------------------------------------------------------------------

class AppUpdater:
    """Download a DMG and stage it as /Applications/Click-n-speak.app.new."""

    def __init__(self) -> None:
        self._child: Optional[multiprocessing.Process] = None
        self._monitor_thread: Optional[threading.Thread] = None
        self._cancelled = threading.Event()

    def start_download_and_stage(
        self,
        info: UpdateInfo,
        main_thread_queue,
        on_progress: Callable[[int, int], None],
        on_staged: Callable[[], None],
        on_error: Callable[[str], None],
        on_cancelled: Callable[[], None],
    ) -> None:
        """Start download + staging in background. All callbacks fire on main thread."""
        if info.dmg_url is None:
            main_thread_queue.put_nowait((on_error, ("No DMG URL available",), {}))
            return

        self._cancelled.clear()
        UPDATES_DIR.mkdir(parents=True, exist_ok=True)
        dest = UPDATES_DIR / f"click-n-speak-{info.tag_name}.dmg"

        ctx = multiprocessing.get_context("spawn")
        progress_q: multiprocessing.Queue = ctx.Queue()
        result_q: multiprocessing.Queue = ctx.Queue()

        self._child = ctx.Process(
            target=_download_worker,
            args=(info.dmg_url, str(dest), progress_q, result_q),
            daemon=True,
        )
        self._child.start()

        self._monitor_thread = threading.Thread(
            target=self._monitor,
            args=(dest, progress_q, result_q, main_thread_queue,
                  on_progress, on_staged, on_error, on_cancelled),
            daemon=True,
            name="app-updater-monitor",
        )
        self._monitor_thread.start()

    def cancel(self) -> None:
        self._cancelled.set()
        if self._child and self._child.is_alive():
            self._child.terminate()

    def _monitor(
        self,
        dest: Path,
        progress_q,
        result_q,
        main_thread_queue,
        on_progress, on_staged, on_error, on_cancelled,
    ) -> None:
        last_progress = 0.0

        while self._child and self._child.is_alive():
            if self._cancelled.is_set():
                try:
                    dest.unlink()
                except OSError:
                    pass
                main_thread_queue.put_nowait((on_cancelled, (), {}))
                return

            # Drain progress queue.
            now = time.monotonic()
            if now - last_progress >= _PROGRESS_INTERVAL:
                try:
                    done, total = progress_q.get_nowait()
                    main_thread_queue.put_nowait((on_progress, (done, total), {}))
                    last_progress = now
                except queue.Empty:
                    pass

            time.sleep(0.1)

        if self._cancelled.is_set():
            try:
                dest.unlink()
            except OSError:
                pass
            main_thread_queue.put_nowait((on_cancelled, (), {}))
            return

        # Child finished — read result.
        try:
            status, payload = result_q.get_nowait()
        except queue.Empty:
            main_thread_queue.put_nowait((on_error, ("Download process exited without result",), {}))
            return

        if status == "error":
            main_thread_queue.put_nowait((on_error, (payload,), {}))
            return

        # Download OK — stage the .app.
        dmg_path = Path(payload)
        log_info(f"app_updater: download complete ({dmg_path.stat().st_size // 1024} KB), staging...")
        error = self._stage(dmg_path, main_thread_queue, on_staged, on_error)
        if not error:
            try:
                dmg_path.unlink()
            except OSError:
                pass

    def _stage(self, dmg_path: Path, main_thread_queue, on_staged, on_error) -> bool:
        """Mount DMG, copy .app to staged path. Returns True on error."""
        mount_point = _mount_dmg(dmg_path)
        if mount_point is None:
            main_thread_queue.put_nowait((on_error, ("Could not mount DMG",), {}))
            return True

        try:
            app_in_dmg = _find_app_in_mount(mount_point)
            if app_in_dmg is None:
                main_thread_queue.put_nowait((on_error, ("No .app found in DMG",), {}))
                return True

            ok = _copy_app_to_staged(app_in_dmg, STAGED_PATH)
            if not ok:
                ok = _copy_with_admin(app_in_dmg, STAGED_PATH)

            if not ok:
                main_thread_queue.put_nowait((on_error, ("Could not copy .app to staging area",), {}))
                return True

            log_info(f"app_updater: staged to {STAGED_PATH}")
            main_thread_queue.put_nowait((on_staged, (), {}))
            return False
        finally:
            _detach_dmg(mount_point)
            try:
                mount_point.rmdir()
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Swap and relaunch (called when user clicks "Restart to apply")
# ---------------------------------------------------------------------------

def swap_and_launch() -> None:
    """Write a helper script that swaps .app.new → .app after this process exits."""
    if not STAGED_PATH.exists():
        log_error("app_updater: swap_and_launch called but staged path does not exist")
        return

    target = INSTALL_DIR / APP_NAME
    my_pid = os.getpid()

    # Swap strategy: move the current bundle aside first, put the staged build in
    # place, and only delete the backup once that succeeds. If the second move
    # fails, roll the backup back so the user is never left without an app.
    script = f"""#!/bin/bash
# Click-n-speak auto-update installer (PID {my_pid})
PARENT_PID={my_pid}
STAGED="{STAGED_PATH}"
TARGET="{target}"
BACKUP="${{TARGET}}.bak"
SCRIPT="$0"

# Wait for the old process to exit (max 30s).
for i in $(seq 1 150); do
    kill -0 $PARENT_PID 2>/dev/null || break
    sleep 0.2
done

sleep 0.3

# Swap .app.new → .app with rollback protection.
if [ -d "$STAGED" ]; then
    rm -rf "$BACKUP"
    if [ -d "$TARGET" ]; then
        if ! mv "$TARGET" "$BACKUP"; then
            echo "installer: could not move current app aside; aborting" >&2
            open -n "$TARGET" 2>/dev/null || true
            rm -f "$SCRIPT"
            exit 1
        fi
    fi
    if mv "$STAGED" "$TARGET"; then
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
        rm -rf "$BACKUP"
    else
        # Roll back: restore the previous bundle.
        echo "installer: install failed, rolling back" >&2
        rm -rf "$TARGET"
        [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET"
    fi
fi

# Relaunch.
open -n "$TARGET"

rm -f "$SCRIPT"
"""

    fd, tmp_name = tempfile.mkstemp(prefix="cns-installer-", suffix=".sh")
    script_path = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(script)
        script_path.chmod(script_path.stat().st_mode | stat.S_IEXEC)
        subprocess.Popen(
            ["/bin/bash", str(script_path)],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log_info(f"app_updater: installer script launched (pid={my_pid})")
    except OSError as e:
        log_error(f"app_updater: could not launch installer script: {e}")
