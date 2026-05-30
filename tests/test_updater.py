"""
tests/test_updater.py

Unit tests for src/updater.py — version parsing, update detection, DMG asset
extraction. No network calls: urlopen is mocked throughout.
"""

import json
import sys
import os
import unittest
from unittest.mock import MagicMock, patch
from io import BytesIO

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from src.updater import (
    UpdateInfo,
    _find_dmg_asset,
    _parse_version,
    check_for_update,
    get_current_version,
)


class TestParseVersion(unittest.TestCase):
    def test_plain_semver(self):
        self.assertEqual(_parse_version("1.2.3"), (1, 2, 3))

    def test_v_prefix(self):
        self.assertEqual(_parse_version("v1.2.3"), (1, 2, 3))

    def test_two_parts(self):
        self.assertEqual(_parse_version("0.9"), (0, 9))

    def test_leading_whitespace(self):
        self.assertEqual(_parse_version("  v2.0.0  "), (2, 0, 0))

    def test_empty_string(self):
        self.assertEqual(_parse_version(""), (0,))

    def test_prerelease_hyphen(self):
        # "v1.3.0-beta" → (1, 3, 0, 0) — non-numeric stripped
        result = _parse_version("v1.3.0-beta")
        self.assertEqual(result[:3], (1, 3, 0))


class TestFindDmgAsset(unittest.TestCase):
    def test_finds_dmg_asset(self):
        assets = [
            {"name": "click-n-speak.zip", "browser_download_url": "https://ex.com/a.zip", "size": 10},
            {"name": "click-n-speak.dmg", "browser_download_url": "https://ex.com/a.dmg", "size": 42_000_000},
        ]
        url, size = _find_dmg_asset(assets)
        self.assertEqual(url, "https://ex.com/a.dmg")
        self.assertEqual(size, 42_000_000)

    def test_returns_none_when_no_dmg(self):
        assets = [{"name": "click-n-speak.zip", "browser_download_url": "https://ex.com/a.zip", "size": 5}]
        url, size = _find_dmg_asset(assets)
        self.assertIsNone(url)
        self.assertEqual(size, 0)

    def test_empty_assets(self):
        url, size = _find_dmg_asset([])
        self.assertIsNone(url)
        self.assertEqual(size, 0)

    def test_case_insensitive(self):
        assets = [{"name": "App.DMG", "browser_download_url": "https://ex.com/App.DMG", "size": 1}]
        url, size = _find_dmg_asset(assets)
        self.assertEqual(url, "https://ex.com/App.DMG")


class TestCheckForUpdate(unittest.TestCase):
    def _make_release(self, tag: str, dmg: bool = True) -> dict:
        assets = []
        if dmg:
            assets.append({
                "name": "click-n-speak.dmg",
                "browser_download_url": f"https://ex.com/{tag}.dmg",
                "size": 50_000_000,
            })
        return {
            "tag_name": tag,
            "html_url": f"https://github.com/SergejKurtasch/click-n-speak/releases/tag/{tag}",
            "assets": assets,
        }

    def _mock_urlopen(self, release_data: dict):
        body = json.dumps(release_data).encode()
        mock_resp = MagicMock()
        mock_resp.read.return_value = body
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        return mock_resp

    @patch("src.updater.get_current_version", return_value="1.0.0")
    @patch("src.updater.urlopen")
    def test_returns_update_info_when_newer(self, mock_open, _mock_ver):
        mock_open.return_value = self._mock_urlopen(self._make_release("v1.1.0"))
        info = check_for_update()
        self.assertIsNotNone(info)
        self.assertEqual(info.version_display, "v1.1.0")
        self.assertEqual(info.dmg_url, "https://ex.com/v1.1.0.dmg")
        self.assertEqual(info.dmg_size, 50_000_000)

    @patch("src.updater.get_current_version", return_value="1.1.0")
    @patch("src.updater.urlopen")
    def test_returns_none_when_same_version(self, mock_open, _mock_ver):
        mock_open.return_value = self._mock_urlopen(self._make_release("v1.1.0"))
        self.assertIsNone(check_for_update())

    @patch("src.updater.get_current_version", return_value="2.0.0")
    @patch("src.updater.urlopen")
    def test_returns_none_when_older(self, mock_open, _mock_ver):
        mock_open.return_value = self._mock_urlopen(self._make_release("v1.9.9"))
        self.assertIsNone(check_for_update())

    @patch("src.updater.get_current_version", return_value="1.0.0")
    @patch("src.updater.urlopen")
    def test_dmg_url_is_none_when_no_asset(self, mock_open, _mock_ver):
        mock_open.return_value = self._mock_urlopen(self._make_release("v1.1.0", dmg=False))
        info = check_for_update()
        self.assertIsNotNone(info)
        self.assertIsNone(info.dmg_url)
        self.assertEqual(info.dmg_size, 0)

    @patch("src.updater.get_current_version", return_value="1.0.0")
    @patch("src.updater.urlopen", side_effect=OSError("network error"))
    def test_returns_none_on_network_error(self, _mock_open, _mock_ver):
        self.assertIsNone(check_for_update())

    @patch("src.updater.get_current_version", return_value=None)
    def test_returns_none_when_current_version_unknown(self, _mock_ver):
        self.assertIsNone(check_for_update())

    @patch("src.updater.get_current_version", return_value="1.0.0")
    @patch("src.updater.urlopen")
    def test_version_display_has_v_prefix(self, mock_open, _mock_ver):
        # tag_name without "v" prefix — should normalise
        mock_open.return_value = self._mock_urlopen(self._make_release("1.2.0"))
        info = check_for_update()
        self.assertIsNotNone(info)
        self.assertTrue(info.version_display.startswith("v"))


class TestUpdateInfoStaged(unittest.TestCase):
    def test_staged_sets_version_display(self):
        info = UpdateInfo.staged("1.3.0")
        self.assertEqual(info.version_display, "v1.3.0")
        self.assertIsNone(info.dmg_url)

    def test_staged_with_v_prefix(self):
        info = UpdateInfo.staged("v2.0.0")
        self.assertEqual(info.version_display, "v2.0.0")
        self.assertEqual(info.tag_name, "v2.0.0")


if __name__ == "__main__":
    unittest.main()
