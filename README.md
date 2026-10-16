# uTerm

Native Swift terminal for macOS. Product direction: light Native calm chrome, dark terminal panes, Monaco, sidebar windows and independent renameable tabs with nested splits.

Implementation is progressing one story at a time; see the [story plan](specs/00-stories/README.md) and [evidence](docs/evidence/).

## Development

Requires Xcode 26 / Swift 6.2, provisionally macOS 14 or later. This is a feasibility host, not the finished application.

```sh
swift build
swift test
swift run uTerm
swift run uTerm --fixture
```

`--fixture` runs a fixed, isolated shell demonstration and exits its child with code 7; the window remains inspectable. The ordinary host starts a new login shell in your home directory. Use Quit to close it with confirmation. Terminal output and typed input are not logged.

SwiftTerm is pinned to 1.20.0, with the exact revision in Package.resolved. Its MIT license notice is included in ThirdParty. Engine-specific APIs stay inside UTermTerminal; UTermCore contains the engine-independent adapter.
