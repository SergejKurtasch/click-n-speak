# Tests Guide

Tests own deterministic fixtures and isolated state. Keep fixtures scoped to
the package or test module that uses them; avoid user configuration, clipboard,
network, and model dependencies by default. Parity tests describe maintained
Swift/Python compatibility boundaries.

Real-model tests are opt-in only and require explicit local model paths. Add
tests for observable behavior, including failure and cancellation paths.
