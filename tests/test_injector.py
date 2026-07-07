from unittest.mock import MagicMock, patch

from src.injector import (
    InjectionResult,
    PasteboardSnapshot,
    QuartzKeyboardAdapter,
    inject_text,
)


class FakeClipboard:
    def __init__(self, *, available: bool = True, changed: bool = False) -> None:
        self.available = available
        self.changed = changed
        self.snapshot_value = PasteboardSnapshot(
            items=((('public.utf8-plain-text', b'original'),),)
        )
        self.text = ""
        self.restored = False

    def is_available(self) -> bool:
        return self.available

    def snapshot(self) -> PasteboardSnapshot:
        return self.snapshot_value

    def set_text(self, text: str) -> int:
        self.text = text
        return 7

    def restore_if_unchanged(
        self,
        snapshot: PasteboardSnapshot,
        expected_change_count: int,
    ) -> bool:
        assert snapshot == self.snapshot_value
        assert expected_change_count == 7
        self.restored = not self.changed
        return self.restored


def test_atomic_paste_uses_one_shortcut_and_restores_clipboard() -> None:
    clipboard = FakeClipboard()
    keyboard = MagicMock()

    with patch("src.injector.is_accessibility_trusted", return_value=True):
        result = inject_text(
            "Привет\nworld",
            clipboard=clipboard,
            keyboard=keyboard,
            restore_delay=0.0,
        )

    assert result.success is True
    assert result.method == "paste"
    assert clipboard.text == "Привет\nworld"
    assert clipboard.restored is True
    keyboard.type_text.assert_not_called()
    keyboard.paste.assert_called_once_with()


def test_new_user_clipboard_is_not_overwritten() -> None:
    clipboard = FakeClipboard(changed=True)

    with patch("src.injector.is_accessibility_trusted", return_value=True):
        result = inject_text(
            "text",
            clipboard=clipboard,
            keyboard=MagicMock(),
            restore_delay=0.0,
        )

    assert result.success is True
    assert clipboard.restored is False


def test_unavailable_clipboard_falls_back_to_throttled_typing() -> None:
    keyboard = MagicMock()

    with patch("src.injector.is_accessibility_trusted", return_value=True), patch(
        "src.injector.time.sleep"
    ):
        result = inject_text(
            "abc",
            clipboard=FakeClipboard(available=False),
            keyboard=keyboard,
        )

    assert result == InjectionResult(True, "typing", 3, result.duration_seconds)
    keyboard.type_text.assert_called_once_with("abc")


def test_failed_paste_restores_clipboard_before_typing_fallback() -> None:
    clipboard = FakeClipboard()
    keyboard = MagicMock()
    keyboard.paste.side_effect = RuntimeError("paste shortcut failed")

    with patch("src.injector.is_accessibility_trusted", return_value=True), patch(
        "src.injector.time.sleep"
    ):
        result = inject_text(
            "abc",
            clipboard=clipboard,
            keyboard=keyboard,
        )

    assert clipboard.restored is True
    assert result.success is True
    assert result.method == "typing"


def test_missing_accessibility_returns_failure() -> None:
    with patch("src.injector.is_accessibility_trusted", return_value=False), patch(
        "src.injector.send_notification"
    ):
        result = inject_text("abc", clipboard=FakeClipboard())

    assert result.success is False
    assert result.method == "none"
    assert "Accessibility" in (result.error or "")


def test_quartz_paste_posts_command_v_without_text_services() -> None:
    adapter = QuartzKeyboardAdapter()
    key_down = MagicMock(name="key_down")
    key_up = MagicMock(name="key_up")

    with (
        patch(
            "src.injector.CGEventCreateKeyboardEvent",
            side_effect=[key_down, key_up],
        ) as create_event,
        patch("src.injector.CGEventSetFlags") as set_flags,
        patch("src.injector.CGEventPost") as post_event,
        patch("src.injector.kCGEventFlagMaskCommand", 1),
        patch("src.injector.kCGHIDEventTap", 0),
    ):
        adapter.paste()

    assert create_event.call_args_list == [
        ((None, 9, True),),
        ((None, 9, False),),
    ]
    assert set_flags.call_count == 2
    assert post_event.call_args_list == [((0, key_down),), ((0, key_up),)]


def test_focus_must_be_confirmed_before_injection() -> None:
    from src.app import SVoiceRecApp

    app = SVoiceRecApp.__new__(SVoiceRecApp)
    app._start_injection_worker = MagicMock()
    running_app = MagicMock()
    frontmost_app = MagicMock()
    frontmost_app.processIdentifier.return_value = 42
    workspace = MagicMock()
    workspace.frontmostApplication.return_value = frontmost_app

    with patch("src.app.NSRunningApplication") as running_apps, patch(
        "src.app.NSWorkspace"
    ) as workspaces, patch("src.app.FOCUS_RESTORE_STABLE_CHECKS", 1):
        running_apps.runningApplicationWithProcessIdentifier_.return_value = running_app
        workspaces.sharedWorkspace.return_value = workspace

        app._activate_previous_app_and_inject(42, "hello")

    running_app.activateWithOptions_.assert_called_once_with(0)
    app._start_injection_worker.assert_called_once_with("hello")


def test_missing_target_pid_copies_instead_of_typing_blindly() -> None:
    from src.app import SVoiceRecApp

    app = SVoiceRecApp.__new__(SVoiceRecApp)
    app._start_injection_worker = MagicMock()

    with patch("src.app.copy_to_clipboard") as copy, patch(
        "src.app.send_notification"
    ), patch("src.app.threading.Thread") as thread:
        app._activate_previous_app_and_inject(None, "hello")

    app._start_injection_worker.assert_not_called()
    thread.assert_called_once()
    assert thread.call_args.kwargs["target"] is copy
