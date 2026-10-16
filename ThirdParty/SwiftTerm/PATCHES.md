# Trellis's SwiftTerm source snapshot

Upstream: SwiftTerm 1.20.0, revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`, from https://github.com/migueldeicaza/SwiftTerm. MIT license: [LICENSE](LICENSE).

This directory contains the upstream `Sources/SwiftTerm` tree and a minimal macOS library package. The shader resource retains its `SwiftTerm_SwiftTerm.bundle` identity. Demo applications, command-line tools, documentation plugins, and unrelated dependencies are omitted. `SwiftTermBuildInfo.swift` records the pinned upstream identity with the modified-build flag, replacing the upstream build-info generator.

The exact engine delta is [trellis.patch](trellis.patch). It changes four upstream files:

- `Apple/AppleTerminalView.swift`: a font change resizes without DECSTR. Upstream's view-level resize soft-resets application cursor mode, attributes, and other live parser state.
- `Buffer.swift`: an opt-in `reflowCursorLine` flag permits normal-buffer current-line reflow. It captures the logical cursor cell offset before resize clamps the cursor, maps it to a destination row object, and restores its position after reflow and history trimming. Destination identity handles eviction of earlier rows in the same logical group; wide-character wrap padding and pending-wrap boundaries are accounted for. The wider reflow loop reads the current wrapped group's first row, rather than row zero of the entire buffer.
- `KittyGraphics.swift`: Kitty graphics file (`t=f`), temporary-file (`t=t`), and shared-memory (`t=s`) transmission are refused with `ENOTSUP`. Terminal output is untrusted (NFR-S05); it must not make the app read, probe for, or unlink local files or POSIX shared memory. Direct (`t=d`) transmission is unchanged.
- `Terminal.swift`: exposes the normal-buffer opt-in. Trellis enables it only during font changes. Ordinary frame resizing and alternate-screen reflow policies remain upstream behavior.

The wrapper still preserves native selections independently with logical Unicode offsets. Explicit history eviction clears selections whose text was removed, rather than selecting another identical occurrence. Alternate-screen applications own their screen contents and redraw after a geometry change; cells clipped by their screen-oriented resize are outside the retained-text selection guarantee.

For an update, replace the source tree from a verified upstream revision, reapply or retire each delta, update this provenance/build identity, and run the complete Trellis suite plus native appearance, zoom, clipboard, search, and alternate-screen checks. `TerminalSelectionBookmarkTests` and `TerminalAppearanceTests` cover current/completed row selection, repeated/wide/combining/ZWJ text, cursor continuation after narrow/wide reflow, history reduction, and live session/mode preservation. Regenerate `trellis.patch` against the recorded upstream snapshot after changing the delta.
