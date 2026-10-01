# CNSDictionary Guide

`DictionaryCoordinator` owns dictionary-derived configuration, correction
persistence, metrics transactions, and explicit persisted acknowledgements.
Treat rejected replacements as durable tombstones. Do not split persistence
ownership between UI, session, or router code; preserve acknowledgement and
learning semantics across failures and restarts.
