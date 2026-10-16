# S015 JSON theme format and validation

Date: 2026-10-16. Implemented, independently reviewed, and verified in the native app.

## Behavior

`ThemeValidator` accepts the v1 schema with only version, id, name, and appearance required. Omitted colors inherit from the matching complete built-in palette; both built-ins retain dark terminal defaults. A supplied ANSI array replaces all sixteen indexes in order. Opaque `#RRGGBB` colors accept either hex case, including custom light terminal backgrounds. Color documents do not contain font settings or executable features.

The UTF-8 reader rejects malformed JSON, decoded duplicate object keys (including escaped spellings), unknown fields, wrong types, unsupported versions, invalid identifiers/colors, non-16 ANSI arrays, and inputs over 65,536 bytes. Nesting is bounded. Errors identify paths such as `$.terminal.background` or `$.terminal.ansi[3]`. Schema version comparison is exact, so floating-point rounding cannot accept a different numeric value. Display-name length counts Unicode scalar values as JSON Schema requires. The reserved `trellis-` namespace is exposed for S016 installation policy; this story installs no files.

Resolved colors include application chrome, default terminal colors, independent cursor text, selection colors, and ANSI indexes. Contrast checks use sRGB luminance and report named foreground/background pairs. Normal text, labels, selected text, cursor text, and status text target 4.5:1; focus and essential boundaries target 3:1 against adjacent application and terminal surfaces. Warnings remain advisory for custom colors. Both complete built-in palettes pass these checks.

Settings → Theme Preview provides the bundled minimal/full-light/full-dark examples and a local JSON file chooser. The file reader runs off the main actor, checks for a regular file, and reads at most 64 KiB plus one byte before validation. A failed load preserves the last valid sample. The preview contains a stopped native terminal with Unicode and all ANSI indexes, labeled color swatches, application/sidebar/tab colors, selected text, cursor text, and status labels. It never installs a theme, updates workspace settings, or starts a process. Theme installation/export/reload/selection remain S016.

The core resource bundle is copied into the development app and loaded from its native Resources directory, avoiding a dependency on an absolute SwiftPM build-resource path for bundled examples.

## Review and validation

Independent review added eight regression tests and identified cursor-query consistency after OSC12 overrides plus a missing contrast check against terminal backgrounds. Applying a palette now resets the engine's cursor color as well as the rendered caret. Focus and divider contrast include the terminal canvas; the built-in/full-example light focus ring was adjusted to `#2869B5` to pass 3:1 on the dark terminal. The engine uses the standard xterm 256-color strategy so changing base theme colors does not recolor indexes 16–255; true-color cell attributes remain intact.

Full regression suite: **171 tests passed, zero failures**. After the final resource lookup and labeled-swatch adjustments, all **17 theme tests** passed again. The packaged native app builds and its ad-hoc signature verifies.

Tests cover the four named story cases, exact/over-size inputs, escaped duplicate keys, malformed numeric/string/Unicode input, scalar name length, schema/property parity, committed/bundled fixture parity, full/minimal resolution, named advisory contrast warnings, actual engine palette queries for all sixteen declared indexes, standard index 21, unchanged true-color attributes/selection, reset OSC4/OSC12 overrides, zero outbound input during palette application, and preview isolation from workspace/session state.

Native QA loaded Minimal → My Midnight, Dark → My Dark, and Light → My Light. Each displayed Unicode terminal text, ANSI samples, selection/cursor text, status labels, and matching application sample colors. Opening an invalid local file displayed `$.terminal.background: Use an opaque #RRGGBB color.` while retaining My Light and its valid palette. The workspace fixture remained exited, with its original output. The final package displayed all sixteen labeled ANSI swatches. Its minimal example loaded with the SwiftPM build-resource bundle temporarily hidden, confirming that the shipped resource path works; the build resource bundle was then restored.

macOS/Intel/display and release performance qualification remain S031/S032 work. Import, replacement, deletion, export, reload, and persistent custom-theme activation are deliberately S016 work.
