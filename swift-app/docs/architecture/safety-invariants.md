# Safety Invariants

Native startup calls `Config.loadValidated(from:)`. Missing configuration may
create a profile; invalid or unreadable configuration pauses startup before
runtime, dictionary, timer, or prompt-watcher activation.

Audio capture resources are generation-scoped. Accepted unprocessed work is
bounded; overflow, timeout, abort, and failure preserve an incomplete draft
while accepted chunks drain safely.

Telemetry never contains transcripts, prompts, clipboard contents,
credentials, or audio. Events include run identity, monotonic uptime, and wall
time, while session/chunk events retain explicit identifiers.

Downloads enforce byte ceilings, retries, exact resumed ranges, cancellation,
and integrity checks before activation. Update transactions durably stop,
install, launch, acknowledge, and finalize; recovery preserves artifacts when
rollback is incomplete.
