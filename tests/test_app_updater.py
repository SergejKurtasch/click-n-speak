"""
tests/test_app_updater.py

Unit tests for src/app_updater.py — staged update detection, version comparison,
download lifecycle, and installer script generation.

Network and filesystem operations are mocked throughout.
"""

import os
import plistlib
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.app_updater import (
    AppUpdater,
    check_staged_update_on_launch,
    swap_and_launch,
    _find_app_in_mount,
    _read_bundle_version,
    STAGED_PATH,
)
from src.updater import UpdateInfo


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_fake_app(parent: Path, version: str) -> Path:
    """Create a minimal .app bundle with an Info.plist."""
    app = parent / "Click-n-speak.app"
    contents = app / "Contents"
    contents.mkdir(parents=True)
    plist_data = {
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
    }
    with open(contents / "Info.plist", "wb") as f:
        plistlib.dump(plist_data, f)
    return app


# ---------------------------------------------------------------------------
# _read_bundle_version
# ---------------------------------------------------------------------------

class TestReadBundleVersion(unittest.TestCase):
    def test_reads_version_from_plist(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = _make_fake_app(Path(tmp), "1.2.3")
            self.assertEqual(_read_bundle_version(app), "1.2.3")

    def test_returns_none_for_missing_plist(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Fake.app"
            app.mkdir()
            self.assertIsNone(_read_bundle_version(app))


# ---------------------------------------------------------------------------
# _find_app_in_mount
# ---------------------------------------------------------------------------

class TestFindAppInMount(unittest.TestCase):
    def test_finds_app_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            mount = Path(tmp)
            (mount / "SomeFile.txt").touch()
            app = mount / "Click-n-speak.app"
            app.mkdir()
            found = _find_app_in_mount(mount)
            self.assertEqual(found, app)

    def test_returns_none_if_no_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            mount = Path(tmp)
            (mount / "README.txt").touch()
            self.assertIsNone(_find_app_in_mount(mount))


# ---------------------------------------------------------------------------
# check_staged_update_on_launch
# ---------------------------------------------------------------------------

class TestCheckStagedUpdateOnLaunch(unittest.TestCase):

    @patch("src.app_updater.STAGED_PATH")
    def test_returns_none_when_staged_path_missing(self, mock_staged):
        mock_staged.exists.return_value = False
        result = check_staged_update_on_launch()
        self.assertIsNone(result)

    def test_removes_staged_when_version_equal(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = _make_fake_app(Path(tmp), "1.1.0")
            with (
                patch("src.app_updater.STAGED_PATH", staged),
                patch("src.app_updater.get_current_version", return_value="1.1.0"),
            ):
                result = check_staged_update_on_launch()
                self.assertIsNone(result)
                self.assertFalse(staged.exists())

    def test_removes_staged_when_version_older(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = _make_fake_app(Path(tmp), "1.0.0")
            with (
                patch("src.app_updater.STAGED_PATH", staged),
                patch("src.app_updater.get_current_version", return_value="1.1.0"),
            ):
                result = check_staged_update_on_launch()
                self.assertIsNone(result)
                self.assertFalse(staged.exists())

    def test_returns_update_info_when_staged_is_newer(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = _make_fake_app(Path(tmp), "1.2.0")
            with (
                patch("src.app_updater.STAGED_PATH", staged),
                patch("src.app_updater.get_current_version", return_value="1.1.0"),
            ):
                result = check_staged_update_on_launch()
                self.assertIsNotNone(result)
                self.assertEqual(result.version_display, "v1.2.0")
                # Should NOT remove staged
                self.assertTrue(staged.exists())

    def test_removes_staged_when_plist_unreadable(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / "Click-n-speak.app"
            staged.mkdir()
            # No Contents/Info.plist
            with (
                patch("src.app_updater.STAGED_PATH", staged),
                patch("src.app_updater.get_current_version", return_value="1.0.0"),
            ):
                result = check_staged_update_on_launch()
                self.assertIsNone(result)
                self.assertFalse(staged.exists())


# ---------------------------------------------------------------------------
# swap_and_launch
# ---------------------------------------------------------------------------

class TestSwapAndLaunch(unittest.TestCase):
    def test_writes_and_launches_helper_script(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / "Click-n-speak.app.new"
            staged.mkdir()
            launched_args = []

            def fake_popen(args, **kw):
                launched_args.extend(args)
                return MagicMock()

            with (
                patch("src.app_updater.STAGED_PATH", staged),
                patch("src.app_updater.subprocess.Popen", side_effect=fake_popen),
            ):
                swap_and_launch()

            self.assertTrue(len(launched_args) > 0)
            self.assertEqual(launched_args[0], "/bin/bash")
            script_path = launched_args[1]
            # Script file is deleted by the script itself, but we can check it was created
            # (it may already be deleted if tests run quickly — check arg is a string path)
            self.assertTrue(script_path.endswith(".sh"))

    def test_does_nothing_when_staged_missing(self):
        with patch("src.app_updater.STAGED_PATH", Path("/nonexistent/path.app.new")):
            with patch("src.app_updater.subprocess.Popen") as mock_popen:
                swap_and_launch()
                mock_popen.assert_not_called()

    def test_script_contains_correct_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            staged = Path(tmp) / "Click-n-speak.app.new"
            staged.mkdir()
            script_contents = []

            def fake_popen(args, **kw):
                script_path = args[1]
                try:
                    with open(script_path) as f:
                        script_contents.append(f.read())
                except OSError:
                    pass
                return MagicMock()

            with (
                patch("src.app_updater.STAGED_PATH", staged),
                patch("src.app_updater.subprocess.Popen", side_effect=fake_popen),
            ):
                swap_and_launch()

            self.assertEqual(len(script_contents), 1)
            self.assertIn(str(os.getpid()), script_contents[0])


# ---------------------------------------------------------------------------
# AppUpdater — download lifecycle
# ---------------------------------------------------------------------------

class TestAppUpdaterDownload(unittest.TestCase):
    def _make_info(self, dmg_url="https://example.com/test.dmg"):
        return UpdateInfo(
            tag_name="v1.2.0",
            version_display="v1.2.0",
            html_url="https://github.com/test/releases/tag/v1.2.0",
            dmg_url=dmg_url,
            dmg_size=10_000_000,
        )

    def test_error_when_no_dmg_url(self):
        updater = AppUpdater()
        errors = []
        q = _FakeQueue()
        info = self._make_info(dmg_url=None)
        updater.start_download_and_stage(
            info, q,
            on_progress=lambda d, t: None,
            on_staged=lambda: None,
            on_error=errors.append,
            on_cancelled=lambda: None,
        )
        # Error callback is posted to queue — drain it.
        q.drain()
        self.assertEqual(len(errors), 1)
        self.assertIn("No DMG URL", errors[0])


class _FakeQueue:
    """Synchronous stand-in for _main_thread_queue in tests."""
    def __init__(self):
        self._items = []

    def put_nowait(self, item):
        fn, args, kwargs = item
        self._items.append((fn, args, kwargs))

    def drain(self):
        for fn, args, kwargs in self._items:
            fn(*args, **kwargs)
        self._items.clear()


if __name__ == "__main__":
    unittest.main()
