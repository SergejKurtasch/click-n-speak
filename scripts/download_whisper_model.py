#!/usr/bin/env python3
"""
scripts/download_whisper_model.py

Downloads a Whisper MLX model into the local HuggingFace cache so that
Click-n-speak can load it instantly without any network access.

Usage (from the project root, with venv activated):
    python scripts/download_whisper_model.py --model mlx-community/whisper-large-v3-mlx

Features:
  - Resumes interrupted downloads automatically (HuggingFace Hub protocol).
  - Can be interrupted with Ctrl+C and resumed later without losing progress.
  - After completion, restart Click-n-speak and select the model from the menu.
"""

import argparse
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, PROJECT_ROOT)

MODEL_SIZES: dict[str, str] = {
    "mlx-community/whisper-large-v3-turbo": "~795 MB",
    "mlx-community/whisper-large-v3-mlx":   "~1.5 GB",
    "mlx-community/whisper-medium-mlx":      "~790 MB",
    "mlx-community/whisper-small-mlx":       "~244 MB",
    "mlx-community/whisper-base-mlx":        "~74 MB",
}


def download_model(model_id: str) -> None:
    from huggingface_hub import snapshot_download  # type: ignore

    size_str = MODEL_SIZES.get(model_id, "unknown size")
    cache_dir = os.environ.get(
        "HF_HOME",
        os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub"),
    )

    print(f"\n{'=' * 60}")
    print(f"  Whisper Model Downloader — Click-n-speak")
    print(f"{'=' * 60}")
    print(f"  Model : {model_id}")
    print(f"  Size  : {size_str}")
    print(f"  Cache : {cache_dir}")
    print(f"\n  The download can be interrupted with Ctrl+C and will")
    print(f"  resume from where it left off when you run this again.")
    print(f"{'=' * 60}\n")

    start = time.time()
    try:
        local_dir = snapshot_download(
            repo_id=model_id,
            cache_dir=cache_dir,
            resume_download=True,
            local_files_only=False,
        )
        elapsed = time.time() - start
        mins, secs = divmod(int(elapsed), 60)
        print(f"\n{'=' * 60}")
        print(f"  ✅  Download complete in {mins}m {secs}s")
        print(f"  Local path: {local_dir}")
        print(f"\n  Restart Click-n-speak, then select the model from the menu.")
        print(f"{'=' * 60}\n")
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
    parser = argparse.ArgumentParser(
        description="Download a Whisper MLX model for Click-n-speak."
    )
    parser.add_argument(
        "--model",
        required=True,
        help="HuggingFace model ID, e.g. mlx-community/whisper-large-v3-mlx",
    )
    args = parser.parse_args()

    try:
        from huggingface_hub import snapshot_download  # noqa: F401
    except ImportError:
        print("[error] huggingface_hub not installed. Run: pip install huggingface-hub")
        sys.exit(1)

    download_model(args.model)


if __name__ == "__main__":
    main()
