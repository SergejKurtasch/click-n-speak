#!/usr/bin/env python3
"""Generate deterministic, speech-free media fixtures for Swift tests."""

from __future__ import annotations

import argparse
import hashlib
import logging
import math
import shutil
import struct
import subprocess
import wave
from pathlib import Path


LOGGER = logging.getLogger(__name__)
DEFAULT_OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "Packages"
    / "CNSTranscription"
    / "Tests"
    / "CNSTranscriptionTests"
    / "Fixtures"
    / "Media"
)
GENERATED_FIXTURES = (
    "signal-16k-mono.wav",
    "signal-44k-mono.wav",
    "signal-48k-stereo.wav",
    "signal-48k-stereo.caf",
    "signal.m4a",
    "signal.aac",
    "signal.ogg",
    "signal.opus",
)


def write_wav(path: Path, sample_rate: int, channels: int) -> None:
    """Write a 250 ms, 440 Hz signed-16-bit PCM signal."""
    frame_count = sample_rate // 4
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        for index in range(frame_count):
            sample = int(8_000 * math.sin(2 * math.pi * 440 * index / sample_rate))
            frame = struct.pack("<h", sample) * channels
            output.writeframesraw(frame)


def run(command: list[str]) -> None:
    """Run one fixture conversion and log it without leaking file contents."""
    LOGGER.info("Running %s", " ".join(command))
    subprocess.run(command, check=True, capture_output=True)


def generate(output_directory: Path) -> None:
    """Generate the fixture matrix and its SHA-256 manifest."""
    afconvert = shutil.which("afconvert")
    ffmpeg = shutil.which("ffmpeg")
    if afconvert is None or ffmpeg is None:
        missing = "afconvert" if afconvert is None else "ffmpeg"
        raise RuntimeError(f"Required fixture generator is unavailable: {missing}")

    output_directory.mkdir(parents=True, exist_ok=True)
    for name in (*GENERATED_FIXTURES, "SHA256SUMS"):
        (output_directory / name).unlink(missing_ok=True)

    write_wav(output_directory / "signal-16k-mono.wav", 16_000, 1)
    write_wav(output_directory / "signal-44k-mono.wav", 44_100, 1)
    write_wav(output_directory / "signal-48k-stereo.wav", 48_000, 2)

    source = output_directory / "signal-44k-mono.wav"
    run([
        afconvert,
        str(source),
        str(output_directory / "signal-48k-stereo.caf"),
        "-f", "caff", "-d", "LEI16@48000", "-c", "2",
    ])
    common_ffmpeg = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source)]
    run(common_ffmpeg + ["-c:a", "aac", "-b:a", "64k", str(output_directory / "signal.m4a")])
    run(common_ffmpeg + [
        "-c:a", "aac", "-b:a", "64k", "-f", "adts", str(output_directory / "signal.aac")
    ])
    run(common_ffmpeg + [
        "-ac", "2", "-c:a", "vorbis", "-strict", "experimental",
        str(output_directory / "signal.ogg")
    ])
    run(common_ffmpeg + ["-ar", "48000", "-c:a", "libopus", str(output_directory / "signal.opus")])

    fixture_paths = [output_directory / name for name in sorted(GENERATED_FIXTURES)]
    manifest = "".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in fixture_paths
    )
    (output_directory / "SHA256SUMS").write_text(manifest, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> None:
    """Generate all fixtures."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    args = parse_args()
    generate(args.output.resolve())


if __name__ == "__main__":
    main()
