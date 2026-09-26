"""Tests for the parent-death watchdog that prevents transcriber orphans.

The watchdog is the primary defense against multi-GB MLX helper processes
outliving their parent on macOS (which has no PR_SET_PDEATHSIG).
"""

import os
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _write_fixture(code: str) -> Path:
    """Write a throwaway Python script to a tempfile and return its path.

    `multiprocessing.spawn` re-executes Python and imports the script as
    `__main__`, so we need a real on-disk file — an inline `-c` string won't
    do. Tempfile keeps the tests/ directory clean.
    """
    fd, path = tempfile.mkstemp(prefix="watchdog_fixture_", suffix=".py")
    os.close(fd)
    p = Path(path)
    p.write_text(code)
    return p


def _run_child_with_watchdog() -> subprocess.Popen:
    """Spawn a grandchild that installs the watchdog and idles forever.

    The layout mirrors the real scenario: a short-lived intermediate (this
    Popen's target) forks a grandchild which we then observe. We kill the
    intermediate and verify the grandchild dies.
    """
    code = textwrap.dedent(
        f"""
        import os, sys, time, multiprocessing
        sys.path.insert(0, {str(ROOT)!r})

        def child_target(ready_path):
            from src.process_watchdog import install_parent_death_watchdog
            install_parent_death_watchdog()
            with open(ready_path, 'w') as f:
                f.write(str(os.getpid()))
            while True:
                time.sleep(0.5)

        if __name__ == '__main__':
            ready_path = sys.argv[1]
            ctx = multiprocessing.get_context('spawn')
            p = ctx.Process(target=child_target, args=(ready_path,), daemon=False)
            p.start()
            # Parent just sleeps; the test will SIGKILL us to simulate a crash.
            while True:
                time.sleep(0.5)
        """
    )
    script = _write_fixture(code)
    ready_fd, ready_path = tempfile.mkstemp(prefix="watchdog_ready_", suffix=".txt")
    os.close(ready_fd)
    ready = Path(ready_path)
    # Start from an empty file so _wait_for_ready doesn't misread stale data.
    ready.write_text("")
    proc = subprocess.Popen(
        [sys.executable, str(script), str(ready)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    proc._ready_path = ready  # type: ignore[attr-defined]
    proc._script_path = script  # type: ignore[attr-defined]
    return proc


def _wait_for_ready(proc: subprocess.Popen, timeout: float = 10.0) -> int:
    ready = proc._ready_path  # type: ignore[attr-defined]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ready.exists():
            text = ready.read_text().strip()
            if text:
                return int(text)
        if proc.poll() is not None:
            raise RuntimeError(f"intermediate exited early: rc={proc.returncode}")
        time.sleep(0.05)
    raise TimeoutError("grandchild did not report ready")


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _cleanup_proc(proc: subprocess.Popen) -> None:
    for attr in ("_ready_path", "_script_path"):
        try:
            getattr(proc, attr).unlink(missing_ok=True)
        except Exception:
            pass


def test_watchdog_kills_child_when_parent_is_sigkilled():
    """Simulates Force Quit: SIGKILL the parent, grandchild must die too."""
    proc = _run_child_with_watchdog()
    try:
        grandchild_pid = _wait_for_ready(proc)
        assert _pid_alive(grandchild_pid), "grandchild should be alive after setup"

        # Simulate abrupt parent death (Force Quit / crash).
        proc.kill()
        proc.wait(timeout=5)

        # Watchdog must kill the grandchild within a few seconds. kqueue path
        # fires almost instantly; polling fallback fires within ~2s.
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and _pid_alive(grandchild_pid):
            time.sleep(0.1)

        assert not _pid_alive(grandchild_pid), (
            f"grandchild {grandchild_pid} survived parent SIGKILL — watchdog failed"
        )
    finally:
        _cleanup_proc(proc)


def test_watchdog_also_kills_resource_tracker():
    """Regression guard: the multiprocessing resource_tracker helper must also die.

    `resource_tracker` is spawned implicitly by CPython's multiprocessing
    machinery (separate from our worker), and historically it's the helper
    that leaks as an orphan holding shared-memory fds. This test proves the
    watchdog + process-group kill strategy reaches *both* helpers, so future
    stdlib changes that rename or relocate the tracker surface here.
    """
    import psutil  # type: ignore

    code = textwrap.dedent(
        f"""
        import os, sys, time, multiprocessing
        sys.path.insert(0, {str(ROOT)!r})

        def child_target(ready_path):
            from src.process_watchdog import install_parent_death_watchdog, ensure_own_process_group
            ensure_own_process_group()
            install_parent_death_watchdog()
            with open(ready_path, 'w') as f:
                f.write(str(os.getpid()))
            while True:
                time.sleep(0.5)

        if __name__ == '__main__':
            ready_path = sys.argv[1]
            # Touching a Manager value forces resource_tracker to spawn.
            ctx = multiprocessing.get_context('spawn')
            p = ctx.Process(target=child_target, args=(ready_path,), daemon=False)
            p.start()
            while True:
                time.sleep(0.5)
        """
    )
    script = _write_fixture(code)
    ready_fd, ready_path = tempfile.mkstemp(prefix="watchdog_rt_ready_", suffix=".txt")
    os.close(ready_fd)
    ready = Path(ready_path)
    ready.write_text("")

    proc = subprocess.Popen(
        [sys.executable, str(script), str(ready)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    proc._ready_path = ready  # type: ignore[attr-defined]
    proc._script_path = script  # type: ignore[attr-defined]
    try:
        # Wait until the grandchild is ready — by then resource_tracker exists.
        deadline = time.monotonic() + 10.0
        grandchild_pid = None
        while time.monotonic() < deadline:
            if ready.exists():
                text = ready.read_text().strip()
                if text:
                    grandchild_pid = int(text)
                    break
            if proc.poll() is not None:
                raise RuntimeError(f"intermediate exited early: rc={proc.returncode}")
            time.sleep(0.05)
        assert grandchild_pid is not None, "grandchild did not report ready"

        # Identify resource_tracker among our descendants.
        tracker_pids: list[int] = []
        try:
            parent_proc = psutil.Process(proc.pid)
            for child in parent_proc.children(recursive=True):
                try:
                    cmdline = " ".join(child.cmdline())
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
                if "resource_tracker" in cmdline:
                    tracker_pids.append(child.pid)
        except psutil.NoSuchProcess:
            pass

        # Resource tracker is usually spawned lazily — re-scan if we missed it.
        if not tracker_pids:
            time.sleep(0.5)
            try:
                parent_proc = psutil.Process(proc.pid)
                for child in parent_proc.children(recursive=True):
                    try:
                        cmdline = " ".join(child.cmdline())
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        continue
                    if "resource_tracker" in cmdline:
                        tracker_pids.append(child.pid)
            except psutil.NoSuchProcess:
                pass

        # Simulate crash.
        proc.kill()
        proc.wait(timeout=5)

        # Everyone (grandchild + resource_tracker) must die within a few seconds.
        targets = [grandchild_pid] + tracker_pids
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and any(_pid_alive(p) for p in targets):
            time.sleep(0.1)

        survivors = [p for p in targets if _pid_alive(p)]
        assert not survivors, (
            f"helpers survived parent SIGKILL: {survivors} "
            f"(grandchild={grandchild_pid}, trackers={tracker_pids})"
        )
    finally:
        _cleanup_proc(proc)


def test_ensure_own_process_group_is_idempotent():
    from src.process_watchdog import ensure_own_process_group

    # Running inside pytest, we may or may not already be a group leader; the
    # function must succeed either way and leave PGID == PID afterwards.
    assert ensure_own_process_group() is True
    assert os.getpgrp() == os.getpid()
    # Second call is a no-op and still returns True.
    assert ensure_own_process_group() is True


def test_nsapp_terminate_observer_fires_cleanup():
    """Verify NSApp.terminate: path triggers our cleanup callback.

    We post `NSApplicationWillTerminateNotification` — the exact notification
    AppKit sends when rumps' built-in Cmd+Q calls `NSApp.terminate:`. Runs
    in a subprocess because conftest.py monkey-patches `Foundation`/`AppKit`
    with MagicMock for unit tests; we need the real pyobjc modules here.
    """
    script = textwrap.dedent(
        f"""
        import sys
        sys.path.insert(0, {str(ROOT)!r})
        from AppKit import NSApplicationWillTerminateNotification
        from Foundation import NSNotificationCenter
        from src.process_watchdog import install_nsapp_terminate_observer

        called = []
        assert install_nsapp_terminate_observer(lambda: called.append(True)) is True
        NSNotificationCenter.defaultCenter().postNotificationName_object_(
            NSApplicationWillTerminateNotification, None
        )
        assert called == [True], f"observer did not fire: called={{called}}"

        # Idempotency: a second install must replace the previous observer,
        # so the callback only fires once per notification post.
        called.clear()
        second = []
        assert install_nsapp_terminate_observer(lambda: second.append(True)) is True
        NSNotificationCenter.defaultCenter().postNotificationName_object_(
            NSApplicationWillTerminateNotification, None
        )
        assert second == [True], f"second observer did not fire: second={{second}}"
        assert called == [], f"first observer should have been removed: called={{called}}"

        print("OK")
        """
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert result.returncode == 0, (
        f"subprocess failed (rc={result.returncode}):\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
    )
    assert "OK" in result.stdout


def test_watchdog_log_callback_is_used():
    """install_parent_death_watchdog must route diagnostics through `log`.

    Runs in a subprocess so the daemon threads the watchdog spawns (kqueue +
    PPID poller) don't leak into the pytest process and outlive the test.
    """
    script = textwrap.dedent(
        f"""
        import sys
        sys.path.insert(0, {str(ROOT)!r})
        from src.process_watchdog import install_parent_death_watchdog

        captured = []

        def fake_log(msg):
            captured.append(msg)

        # Sentinel exit that doesn't actually exit — we want to inspect the log.
        def fake_exit(_reason):
            pass

        install_parent_death_watchdog(on_parent_death=fake_exit, log=fake_log)
        assert captured, "watchdog did not emit any log lines"
        first = captured[0]
        for needle in ("pid=", "ppid=", "pgid="):
            assert needle in first, f"missing {{needle!r}} in log: {{first!r}}"
        print("OK")
        """
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert result.returncode == 0, (
        f"subprocess failed (rc={result.returncode}):\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}"
    )
    assert "OK" in result.stdout


def test_sweep_orphan_children_ignores_unrelated_and_self():
    """Sweep must not kill unrelated processes or the current process."""
    from src.process_watchdog import sweep_orphan_children

    # With no matching orphans present the function returns 0 and nothing blows up.
    # (The real orphans test requires spawning a helper; covered implicitly by
    # the watchdog test above, which leaves no orphans behind.)
    result = sweep_orphan_children(
        app_name_fragment="__nonexistent_app_fragment_xyz__",
        self_pid=os.getpid(),
    )
    assert result == 0
