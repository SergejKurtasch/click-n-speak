import sys
from unittest.mock import MagicMock

# Mock out heavy or native dependencies for testing logic
sys.modules['mlx_whisper'] = MagicMock()
sys.modules['sounddevice'] = MagicMock()
sys.modules['rumps'] = MagicMock()
sys.modules['pynput'] = MagicMock()
sys.modules['pynput.keyboard'] = MagicMock()
sys.modules['ApplicationServices'] = MagicMock()
sys.modules['Foundation'] = MagicMock()
