"""Tests for accessibility permission checking logic."""
import time
from unittest.mock import MagicMock, patch

import pytest


class TestIsAccessibilityTrusted:
    """Tests for is_accessibility_trusted()."""

    @patch("src.utils.log_error")
    def test_returns_true_when_trusted(self, mock_log):
        with patch.dict("sys.modules", {"ApplicationServices": MagicMock()}):
            import importlib
            import src.utils as utils_mod

            mock_as = MagicMock()
            mock_as.AXIsProcessTrusted.return_value = True

            with patch.dict("sys.modules", {"ApplicationServices": mock_as}):
                result = utils_mod.is_accessibility_trusted()
            assert result is True

    @patch("src.utils.log_error")
    def test_returns_false_when_not_trusted(self, mock_log):
        mock_as = MagicMock()
        mock_as.AXIsProcessTrusted.return_value = False
        with patch.dict("sys.modules", {"ApplicationServices": mock_as}):
            from src.utils import is_accessibility_trusted
            result = is_accessibility_trusted()
        assert result is False

    @patch("src.utils.log_error")
    def test_returns_true_on_import_error(self, mock_log):
        """Fallback: assume trusted if ApplicationServices is not available."""
        with patch.dict("sys.modules", {"ApplicationServices": None}):
            from src.utils import is_accessibility_trusted
            # When the module is None, import will raise ImportError
            # But the function catches ImportError and returns True
            result = is_accessibility_trusted()
        # The function should return True as fallback
        assert result is True


class TestEnsureAccessibilityPermission:
    """Tests for ensure_accessibility_permission()."""

    @patch("src.utils.send_notification")
    @patch("src.utils.open_accessibility_settings")
    @patch("src.utils.is_accessibility_trusted")
    def test_skips_prompt_when_already_trusted(self, mock_trusted, mock_open, mock_notify):
        """If already trusted, should NOT call AXIsProcessTrustedWithOptions."""
        mock_trusted.return_value = True

        from src.utils import ensure_accessibility_permission
        result = ensure_accessibility_permission()

        assert result is True
        mock_open.assert_not_called()
        mock_notify.assert_not_called()

    @patch("src.utils.send_notification")
    @patch("src.utils.open_accessibility_settings")
    @patch("src.utils.is_accessibility_trusted")
    def test_shows_prompt_when_not_trusted(self, mock_trusted, mock_open, mock_notify):
        """When NOT trusted, should show prompt and open settings."""
        mock_trusted.return_value = False

        # Mock AXIsProcessTrustedWithOptions to still return False
        mock_as = MagicMock()
        mock_as.AXIsProcessTrustedWithOptions.return_value = False
        mock_foundation = MagicMock()

        with patch.dict("sys.modules", {
            "ApplicationServices": mock_as,
            "Foundation": mock_foundation,
        }):
            from src.utils import ensure_accessibility_permission
            result = ensure_accessibility_permission()

        assert result is False
        mock_open.assert_called_once()
        mock_notify.assert_called_once()


class TestWaitForAccessibility:
    """Tests for wait_for_accessibility()."""

    @patch("src.utils.is_accessibility_trusted")
    def test_returns_true_immediately_when_trusted(self, mock_trusted):
        mock_trusted.return_value = True

        from src.utils import wait_for_accessibility
        result = wait_for_accessibility(timeout=5.0, poll_interval=0.1)

        assert result is True
        assert mock_trusted.call_count == 1

    @patch("src.utils.is_accessibility_trusted")
    def test_returns_true_after_permission_granted(self, mock_trusted):
        """Simulates permission being granted on the 3rd poll."""
        mock_trusted.side_effect = [False, False, True]

        from src.utils import wait_for_accessibility
        result = wait_for_accessibility(timeout=5.0, poll_interval=0.05)

        assert result is True
        assert mock_trusted.call_count == 3

    @patch("src.utils.is_accessibility_trusted")
    def test_returns_false_on_timeout(self, mock_trusted):
        """Should return False if permission is never granted."""
        mock_trusted.return_value = False

        from src.utils import wait_for_accessibility
        start = time.monotonic()
        result = wait_for_accessibility(timeout=0.3, poll_interval=0.1)
        elapsed = time.monotonic() - start

        assert result is False
        assert elapsed >= 0.3
        assert elapsed < 1.0  # Should not take too long


class TestHotkeyHandlerRestart:
    """Tests for HotkeyHandler.restart()."""

    def test_restart_calls_stop_and_start(self):
        from src.hotkey_handler import HotkeyHandler
        handler = HotkeyHandler(hotkey_str="<alt>+<space>")

        handler.stop = MagicMock()
        handler.start = MagicMock()

        handler.restart()

        handler.stop.assert_called_once()
        handler.start.assert_called_once()
