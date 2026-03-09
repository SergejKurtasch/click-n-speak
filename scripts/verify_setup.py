import sys
import os

print("--- SVoiceRec Verification ---")

# 1. Check Python version
print(f"Python Version: {sys.version}")

# 2. Check dependencies
required = ['mlx_whisper', 'mlx', 'pynput', 'sounddevice', 'numpy', 'AppKit']
missing = []
for lib in required:
    try:
        __import__(lib)
        print(f"[OK] {lib} is installed.")
    except ImportError:
        missing.append(lib)

if missing:
    print(f"[FAIL] Missing dependencies: {missing}")
else:
    print("[OK] All dependencies are present.")

# 3. Check config
config_path = "config.json"
if os.path.exists(config_path):
    print(f"[OK] {config_path} found.")
else:
    print(f"[FAIL] {config_path} not found.")

# 4. Check AppleScript permissions (can only be checked by running)
print("\n[INFO] To enable text injection, you will need to grant 'Accessibility' permissions to your terminal/Python when prompted.")
print("[INFO] To enable recording, you will need to grant 'Microphone' permissions.")

print("\nVerification complete.")
