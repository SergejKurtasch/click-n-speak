from src.runtime_health import RestartDecision, TranscriberHealthMonitor


def test_three_consecutive_slow_warm_decodes_request_restart() -> None:
    monitor = TranscriberHealthMonitor(cooldown_seconds=0)

    assert monitor.record_decode(6.1, cold_start=False, now=1).should_restart is False
    assert monitor.record_decode(7.0, cold_start=False, now=2).should_restart is False
    decision = monitor.record_decode(6.5, cold_start=False, now=3)

    assert decision.should_restart is True
    assert decision.reason == "three_consecutive_slow_decodes"


def test_single_cold_decode_is_not_part_of_slow_streak() -> None:
    monitor = TranscriberHealthMonitor(cooldown_seconds=0)

    assert monitor.record_decode(25.0, cold_start=True, now=1).should_restart is False
    assert monitor.record_decode(7.0, cold_start=False, now=2).should_restart is False
    assert monitor.record_decode(7.0, cold_start=False, now=3).should_restart is False


def test_two_severe_decodes_request_restart() -> None:
    monitor = TranscriberHealthMonitor(cooldown_seconds=0)

    monitor.record_decode(10.1, cold_start=False, now=1)
    decision = monitor.record_decode(11.0, cold_start=False, now=2)

    assert decision.reason == "two_consecutive_severe_decodes"


def test_restart_cooldown_suppresses_repeated_decisions() -> None:
    monitor = TranscriberHealthMonitor(cooldown_seconds=100)
    monitor.mark_restarted(now=50)

    for now in (60, 61, 62):
        decision = monitor.record_decode(20.0, cold_start=False, now=now)

    assert decision.should_restart is False


def test_failed_and_severely_slow_prewarm_request_restart() -> None:
    monitor = TranscriberHealthMonitor(cooldown_seconds=0)

    assert monitor.record_prewarm(30.0, success=False, now=1).reason == "prewarm_failed"
    assert (
        monitor.record_prewarm(10.5, success=True, now=2).reason
        == "prewarm_severely_slow"
    )


def test_successful_restart_clears_previous_slow_window() -> None:
    monitor = TranscriberHealthMonitor(cooldown_seconds=0)
    monitor.record_decode(7.0, cold_start=False, now=1)
    monitor.record_decode(7.0, cold_start=False, now=2)

    monitor.mark_restarted(now=3)

    assert monitor.record_decode(7.0, cold_start=False, now=4).should_restart is False


def test_app_stores_first_health_restart_reason() -> None:
    import threading
    from unittest.mock import patch

    from src.app import SVoiceRecApp

    app = SVoiceRecApp.__new__(SVoiceRecApp)
    app.config = {"stt_backend": "local"}
    app._session_id = 9
    app._pending_transcriber_restart_reason = None
    app._health_decision_lock = threading.Lock()

    with patch("src.app.emit_runtime_event"):
        app._apply_health_decision(RestartDecision(True, "slow_decode"))
        app._apply_health_decision(RestartDecision(True, "later_reason"))

    assert app._pending_transcriber_restart_reason == "slow_decode"


def test_app_schedules_only_one_adaptive_restart_thread() -> None:
    import threading
    from unittest.mock import MagicMock, patch

    from src.app import SVoiceRecApp

    app = SVoiceRecApp.__new__(SVoiceRecApp)
    app.is_recording = False
    app.is_processing = False
    app._pending_transcriber_restart_reason = "slow_decode"
    app._health_decision_lock = threading.Lock()
    app._transcriber_restart_scheduled = False

    with patch("src.app.threading.Thread") as thread:
        thread.return_value = MagicMock()
        app._schedule_pending_transcriber_restart()
        app._schedule_pending_transcriber_restart()

    thread.assert_called_once()
    thread.return_value.start.assert_called_once_with()
