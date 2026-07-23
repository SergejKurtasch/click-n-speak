"""Minimal RIFF/WAVE reader for the files afconvert produces.

afconvert emits WAVE_FORMAT_EXTENSIBLE (format tag 65534) for mono 16-bit audio,
which Python's stdlib `wave` module rejects. The app already walks the RIFF
chunk tree manually for this reason (`_find_wav_data_chunk` in transcriber.py);
this mirrors that logic for the bake-off scripts.
"""
from __future__ import annotations

import struct
from pathlib import Path

import numpy as np


def _walk_chunks(data: bytes) -> dict[bytes, tuple[int, int]]:
    """Return {chunk_id: (start_offset, size)} for top-level RIFF chunks."""
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise RuntimeError("Not a valid RIFF/WAVE file")
    chunks: dict[bytes, tuple[int, int]] = {}
    pos = 12
    while pos + 8 <= len(data):
        chunk_id = data[pos:pos + 4]
        size = int.from_bytes(data[pos + 4:pos + 8], "little")
        start = pos + 8
        chunks.setdefault(chunk_id, (start, min(size, len(data) - start)))
        # RIFF chunks are word-aligned: odd sizes are padded by one byte.
        pos += 8 + size + (size & 1)
    return chunks


def read_pcm16_mono(path: Path) -> tuple[np.ndarray, int]:
    """Return (float32 samples in [-1, 1], sample_rate)."""
    raw = Path(path).read_bytes()
    chunks = _walk_chunks(raw)
    if b"fmt " not in chunks or b"data" not in chunks:
        raise RuntimeError(f"Missing fmt/data chunk in {path}")

    fmt_start, fmt_size = chunks[b"fmt "]
    fmt = raw[fmt_start:fmt_start + fmt_size]
    channels, sample_rate, _byte_rate, _align, bits = struct.unpack_from("<HIIHH", fmt, 2)
    if bits != 16:
        raise RuntimeError(f"Expected 16-bit PCM, got {bits}-bit in {path}")

    data_start, data_size = chunks[b"data"]
    pcm = np.frombuffer(raw[data_start:data_start + data_size], dtype=np.int16)
    if channels > 1:
        pcm = pcm.reshape(-1, channels).mean(axis=1).astype(np.int16)
    return pcm.astype(np.float32) / 32768.0, sample_rate


def duration_seconds(path: Path) -> float:
    samples, rate = read_pcm16_mono(path)
    return len(samples) / float(rate)
