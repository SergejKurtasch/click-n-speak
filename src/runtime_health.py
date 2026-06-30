import time
from collections import deque
from dataclasses import dataclass


@dataclass(frozen=True)
class RestartDecision:
    should_restart: bool
    reason: str | None = None


class TranscriberHealthMonitor:
    """Detect sustained warm-latency degradation without restart thrashing."""

    def __init__(
        self,
        *,
        slow_seconds: float = 6.0,
        severe_seconds: float = 10.0,
        severe_prewarm_seconds: float = 10.0,
        cooldown_seconds: float = 20 * 60,
        long_uptime_seconds: float = 24 * 60 * 60,
    ) -> None:
        self.slow_seconds = slow_seconds
        self.severe_seconds = severe_seconds
        self.severe_prewarm_seconds = severe_prewarm_seconds
        self.cooldown_seconds = cooldown_seconds
        self.long_uptime_seconds = long_uptime_seconds
        self._warm_decode_durations: deque[float] = deque(maxlen=6)
        self._last_restart_at = float("-inf")
        self._process_started_at = time.monotonic()

    def _cooldown_elapsed(self, now: float) -> bool:
        return now - self._last_restart_at >= self.cooldown_seconds

    def record_decode(
        self,
        duration_seconds: float,
        *,
        cold_start: bool,
        now: float | None = None,
    ) -> RestartDecision:
        current = time.monotonic() if now is None else now
        if cold_start:
            return RestartDecision(False)

        self._warm_decode_durations.append(duration_seconds)
        if not self._cooldown_elapsed(current):
            return RestartDecision(False)

        values = list(self._warm_decode_durations)
        if len(values) >= 2 and all(value >= self.severe_seconds for value in values[-2:]):
            return RestartDecision(True, "two_consecutive_severe_decodes")
        if len(values) >= 3 and all(value >= self.slow_seconds for value in values[-3:]):
            return RestartDecision(True, "three_consecutive_slow_decodes")
        if len(values) == 6 and sum(value >= self.slow_seconds for value in values) >= 4:
            return RestartDecision(True, "four_slow_decodes_in_window")
        if (
            current - self._process_started_at >= self.long_uptime_seconds
            and duration_seconds >= self.slow_seconds
        ):
            return RestartDecision(True, "slow_decode_after_long_uptime")
        return RestartDecision(False)

    def record_prewarm(
        self,
        duration_seconds: float,
        *,
        success: bool,
        now: float | None = None,
    ) -> RestartDecision:
        current = time.monotonic() if now is None else now
        if not self._cooldown_elapsed(current):
            return RestartDecision(False)
        if not success:
            return RestartDecision(True, "prewarm_failed")
        if duration_seconds >= self.severe_prewarm_seconds:
            return RestartDecision(True, "prewarm_severely_slow")
        return RestartDecision(False)

    def mark_restarted(self, now: float | None = None) -> None:
        current = time.monotonic() if now is None else now
        self._last_restart_at = current
        self._process_started_at = current
        self._warm_decode_durations.clear()
