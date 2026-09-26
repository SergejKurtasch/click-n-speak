#!/usr/bin/env python3
"""
scripts/download_ai_model.py

Downloads the AI Editor LLM (Qwen2.5-7B-Instruct-4bit) into the
local HuggingFace cache so that Click-n-speak can load it instantly.

Features:
  - Resumes interrupted downloads automatically (HuggingFace Hub protocol).
  - Shows a clear tqdm progress bar per file.
  - Can be interrupted with Ctrl+C and resumed later without losing progress.
  - Reads the model name from config.json so it stays in sync with the app.

Usage (from the project root, with venv activated):
  python scripts/download_ai_model.py

After completion, restart Click-n-speak. The AI Editor will load in ~10 seconds.
"""

import json
import os
import sys
import time

# ── Make sure project root is importable ──────────────────────────────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, PROJECT_ROOT)


def load_model_name() -> str:
    """Read the AI editor model name from config.json (falls back to default)."""
    default = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    config_path = os.path.join(PROJECT_ROOT, "config.json")
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        name = cfg.get("ai_editor_model", default).strip()
        return name if name else default
    except Exception as e:
        print(f"[warning] Could not read config.json ({e}). Using default model.")
        return default


def check_already_cached(model_name: str) -> bool:
    """Return True if all required model files are already in HF cache."""
    try:
        from huggingface_hub import try_to_load_from_cache  # type: ignore

        config_hit = try_to_load_from_cache(repo_id=model_name, filename="config.json")
        if config_hit is None:
            return False
        weight_hit = (
            try_to_load_from_cache(repo_id=model_name, filename="model.safetensors")
            or try_to_load_from_cache(
                repo_id=model_name,
                filename="model-00001-of-00002.safetensors",
            )
            or try_to_load_from_cache(repo_id=model_name, filename="weights.npz")
        )
        return weight_hit is not None
    except Exception:
        return False


def download_model(model_name: str) -> None:
    """Download the model using HuggingFace Hub snapshot_download with resume support."""
    from huggingface_hub import snapshot_download  # type: ignore

    cache_dir = os.environ.get(
        "HF_HOME",
        os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub"),
    )

    print(f"\n{'='*60}")
    print(f"  AI Editor Model Downloader")
    print(f"{'='*60}")
    print(f"  Model : {model_name}")
    print(f"  Cache : {cache_dir}")
    print(f"  Size  : ~4.3 GB")
    print(f"\n  The download can be interrupted with Ctrl+C and will")
    print(f"  resume from where it left off when you run this script again.")
    print(f"{'='*60}\n")

    start = time.time()
    try:
        local_dir = snapshot_download(
            repo_id=model_name,
            cache_dir=cache_dir,
            resume_download=True,       # Resume partial downloads
            local_files_only=False,
        )
        elapsed = time.time() - start
        mins, secs = divmod(int(elapsed), 60)
        print(f"\n{'='*60}")
        print(f"  ✅  Download complete in {mins}m {secs}s")
        print(f"  Local path: {local_dir}")
        print(f"\n  Restart Click-n-speak — the AI Editor will activate automatically.")
        print(f"{'='*60}\n")
    except KeyboardInterrupt:
        elapsed = time.time() - start
        print(f"\n\n  ⏸  Download paused after {elapsed:.0f}s.")
        print(f"  Run this script again to resume from where it left off.\n")
        sys.exit(0)
    except Exception as e:
        print(f"\n  ❌  Download failed: {e}")
        print(f"  Check your internet connection and try again.\n")
        sys.exit(1)


def main() -> None:
    # Verify mlx-lm is installed
    try:
        import mlx_lm  # noqa: F401
        from huggingface_hub import snapshot_download  # noqa: F401
    except ImportError as e:
        print(f"[error] Missing dependency: {e}")
        print("Run:  pip install mlx-lm")
        sys.exit(1)

    model_name = load_model_name()

    if check_already_cached(model_name):
        print(f"\n✅  Model '{model_name}' is already downloaded and ready.")
        print("    Restart Click-n-speak if the AI Editor is not active yet.\n")
        sys.exit(0)

    download_model(model_name)


if __name__ == "__main__":
    main()
