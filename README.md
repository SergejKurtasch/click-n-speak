# Click-n-speak

Click-n-speak is a macOS menu-bar speech-to-text application. This repository
contains the SwiftPM application, packages, native resources, tests, release
scripts, and current documentation:

The former Python implementation is frozen outside Git at
`/Users/sergej/Click-n-speak-python-legacy-archive` for rollback reference;
the repository has no runtime or parity dependency on it.

## Development

```bash
swift test --disable-index-store --package-path Packages/<Package>
swift test --disable-index-store --package-path ClickNSpeak
bash scripts/swift_verify.sh
```
