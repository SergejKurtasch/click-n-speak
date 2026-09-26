# Swift Packages Guide

Each package owns its domain and exposes narrow protocols rather than reaching
across package internals. Put shared configuration, paths, model registry,
telemetry, and cross-package protocols in `CNSCore`; keep UI and AppKit
dependencies out of packages that do not own them. Preserve replacement-service
lifetimes through router interfaces and avoid cyclic dependencies.

Read an owning package guide before changing its state or persistence rules.
