# Runtime Ownership

The app target is the composition root: it validates configuration, constructs
services, and publishes a fully formed runtime descriptor. Package routers own
their service domains and retain replaced services through every active use.

Recording drafts and file jobs snapshot their runtime descriptor, language,
prompt, dictionary hints, replacement policy, and editor choice when work
starts. Runtime replacement is prepared outside the session reservation, then
committed while the session mutation boundary is held; no half-committed STT
and editor pair may become visible.

Recording, file transcription, injection, reload, runtime mutation, warmup,
and shutdown are mutually coordinated activities. Shutdown is terminal and
waits for owned work and already-started persistence.
