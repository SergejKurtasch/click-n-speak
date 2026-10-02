# Synthetic media fixtures

These files contain a 250 ms 440 Hz sine signal and no speech. Regenerate them
from the Swift application root with:

```sh
python3 scripts/generate_media_fixtures.py
```

Generation uses Python's standard-library `wave` module for PCM WAV,
`/usr/bin/afconvert` for CAF, and ffmpeg only at fixture-generation time for
AAC/M4A/Ogg/Opus. The application has no ffmpeg runtime dependency.

| Container | macOS 14 product policy | macOS 26.6.2 probe |
|---|---|---|
| WAV 16/44.1/48 kHz, mono/stereo | native decode | native decode |
| CAF PCM | native decode | native decode |
| M4A/AAC-LC | native decode | native decode |
| Raw AAC ADTS | `afconvert` to owned WAV | conversion succeeds |
| Ogg/Vorbis | unsupported | `afconvert` rejects fixture |
| Ogg/Opus | unsupported | `afconvert` rejects fixture |

The macOS 14 column is the conservative minimum-deployment contract. A real
macOS 14 fixture run remains a release-hardware gate; Ogg codecs stay
unadvertised even if a future host gains a compatible decoder.
