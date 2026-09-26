# ClickNSpeak App Guide

`ClickNSpeak/` is the native composition root. Keep AppKit lifecycle work on
the main actor, assemble dependencies through the runtime factory, and retain
the startup/recovery boundary in the app coordinator. Changes here must not
silently bypass validated configuration or runtime-mutation ownership.

The packaged app is assembled at `dist/swift/Click-n-speak.app`; use the
release build entrypoint documented in `scripts/AGENTS.md`. Package-level
behavior belongs in `Packages/`, not the app target.
