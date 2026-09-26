import sys
from pathlib import Path
from unittest.mock import MagicMock

# Make `import src.*` work regardless of how pytest was invoked (whole suite
# vs. single file vs. single test). Without this, running a single test file
# fails with ModuleNotFoundError — pytest only adds the rootdir to sys.path
# when explicitly configured via `pythonpath`, which we don't rely on.
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

# Mock out heavy or native dependencies for testing logic
sys.modules['mlx_whisper'] = MagicMock()
sys.modules['sounddevice'] = MagicMock()
sys.modules['rumps'] = MagicMock()
sys.modules['pynput'] = MagicMock()
sys.modules['pynput.keyboard'] = MagicMock()
sys.modules['ApplicationServices'] = MagicMock()
sys.modules['Foundation'] = MagicMock()
