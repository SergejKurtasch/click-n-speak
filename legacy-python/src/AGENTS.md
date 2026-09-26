# Python Compatibility Guide

`src/` is the behavioral compatibility/reference layer, not the packaged
runtime. Preserve parity with the Swift implementation where it remains
maintained. UI work must use `_submit_for_main_thread()` or a documented helper
that dispatches internally.

Keep blocking transcriber calls, MLX serialization, clipboard restoration, and
atomic configuration writes safe across worker/UI boundaries.
