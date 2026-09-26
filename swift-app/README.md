# Click-n-speak Swift application

`swift-app/` is the production application tree for Click-n-speak. It owns the
native SwiftPM application, its packages, native resources, focused tests,
release scripts, and living native documentation.

The application is being separated from the frozen Python implementation so
that it can be built, tested, packaged, and relocated independently. Future
Swift work belongs below this directory; do not add new production code to the
legacy tree.

## Development

Run Swift commands from this directory. The canonical checks are:

```bash
swift test --disable-index-store --package-path Packages/<Package>
swift test --disable-index-store --package-path ClickNSpeak
bash scripts/swift_verify.sh
```

The native tree must not resolve runtime resources or build inputs through
`legacy-python/` or through repository-root application paths.
