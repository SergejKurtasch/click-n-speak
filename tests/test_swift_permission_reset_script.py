from __future__ import annotations

import os
import subprocess
from pathlib import Path


def test_permission_reset_targets_only_click_n_speak(tmp_path: Path) -> None:
    fake_tccutil = tmp_path / "tccutil"
    calls_file = tmp_path / "calls.txt"
    fake_tccutil.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "printf '%s\\n' \"$*\" >> \"$CNS_TCC_CALLS_FILE\"\n",
        encoding="utf-8",
    )
    fake_tccutil.chmod(0o755)

    repo_root = Path(__file__).resolve().parents[1]
    script = repo_root / "scripts" / "swift_reset_permissions_for_testing.sh"
    environment = os.environ.copy()
    environment["CNS_TCCUTIL_BIN"] = str(fake_tccutil)
    environment["CNS_TCC_CALLS_FILE"] = str(calls_file)

    subprocess.run(
        [str(script), "--confirm-reset"],
        check=True,
        cwd=repo_root,
        env=environment,
        capture_output=True,
        text=True,
    )

    assert calls_file.read_text(encoding="utf-8").splitlines() == [
        "reset Accessibility com.sergej.clicknspeak",
        "reset Microphone com.sergej.clicknspeak",
    ]
