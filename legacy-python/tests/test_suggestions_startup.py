import importlib
import queue
import sys
import types
from types import SimpleNamespace
from unittest.mock import MagicMock

import AppKit
import pytest


class _FakeAlert:
    def __init__(self) -> None:
        self.buttons: list[str] = []

    @classmethod
    def alloc(cls) -> "_FakeAlert":
        return cls()

    def init(self) -> "_FakeAlert":
        return self

    def setMessageText_(self, text: str) -> None:
        self.message = text

    def setInformativeText_(self, text: str) -> None:
        self.informative_text = text

    def addButtonWithTitle_(self, title: str) -> None:
        self.buttons.append(title)

    def runModal(self) -> int:
        return 1000


@pytest.fixture
def menu_bar_module(monkeypatch: pytest.MonkeyPatch) -> types.ModuleType:
    fake_rumps = types.SimpleNamespace(
        App=object,
        MenuItem=object,
        timer=lambda _interval: (lambda fn: fn),
    )
    monkeypatch.setitem(sys.modules, "rumps", fake_rumps)
    monkeypatch.delitem(sys.modules, "src.menu_bar", raising=False)
    return importlib.import_module("src.menu_bar")


def _app_with_queue(click_app_cls: type) -> tuple[object, queue.Queue]:
    main_queue: queue.Queue = queue.Queue()
    app = object.__new__(click_app_cls)
    app.main_app = SimpleNamespace(_main_thread_queue=main_queue)
    app.config = {
        "pending_suggestions": {"ru": [{"term": "ветку", "count": 12}]},
        "prompt_update_mode": "suggest",
    }
    app._suggestions_panel = MagicMock()
    return app, main_queue


def test_startup_alert_view_list_defers_panel_open(monkeypatch, menu_bar_module) -> None:
    monkeypatch.setattr(AppKit, "NSAlert", _FakeAlert)
    app, main_queue = _app_with_queue(menu_bar_module.ClickNSpeakApp)
    open_mock = MagicMock()
    app._open_suggestions_panel = open_mock

    app._show_suggestions_alert(1, {"ru": [{"term": "ветку", "count": 12}]})

    open_mock.assert_not_called()
    queued_fn, args, kwargs = main_queue.get_nowait()
    assert queued_fn is open_mock
    assert args == []
    assert kwargs == {}


def test_schedule_open_suggestions_panel_falls_back_without_queue(menu_bar_module) -> None:
    app = object.__new__(menu_bar_module.ClickNSpeakApp)
    app.main_app = SimpleNamespace()
    open_mock = MagicMock()
    app._open_suggestions_panel = open_mock

    app._schedule_open_suggestions_panel()

    open_mock.assert_called_once_with()
