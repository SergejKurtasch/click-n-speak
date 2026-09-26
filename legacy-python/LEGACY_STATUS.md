# Legacy Python status

Status: frozen rollback-only reference.

The Swift application in `swift-app/` is the production implementation and
receives normal feature development. The Python tree is retained to support
rollback, migration investigation, and reproducibility during the split.

## Change policy

- Do not develop new product behavior in this tree.
- Keep the tree self-contained and runnable from `legacy-python/`.
- Accept only rollback, reproducibility, security, or maintenance fixes.
- Record any approved maintenance change in this document and in the commit
  message.

The split preserves existing Application Support paths and data formats. It
changes repository ownership and paths only; it does not authorize deleting
legacy runtime data or user configuration.
