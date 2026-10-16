# S015 — Define and validate simple JSON themes

Priority: P0 / MVP  
Status: Implemented — independently reviewed, 171 tests and native preview checks pass  
Delivery phase: 3  
Depends on: [S014](014-appearance-and-monaco-defaults.md)  
Requirements: `FR-TH02`, `FR-TH04`, `FR-TH06`, `FR-TH07`, `INT-10`

## Story

As a theme author, I want to create a theme by copying and editing a small JSON file.

## Acceptance criteria

- [x] **S015-AC01:** Accept the v1 theme schema and supplied full/minimal examples; only version, id, name, and appearance are required.
- [x] **S015-AC02:** Resolve omitted fields against the matching built-in palette; an optional ANSI array replaces exactly 16 indexes. Custom terminal colors may override the dark defaults.
- [x] **S015-AC03:** Reject malformed JSON, duplicate keys, unknown fields, invalid IDs/colors, unsupported versions, wrong ANSI length, and files over 64 KiB before installation.
- [x] **S015-AC04:** Report field-path errors and advisory contrast warnings; preview text, selection, cursor, status, and ANSI colors. Theme files contain no scripts, remote includes, fonts, or executable content.

## Unit tests

These are test specifications to implement with the story, not executed tests. Names are proposed and may follow repository conventions once the Swift project exists. Isolate time, filesystem, process, Keychain, clipboard, and transport dependencies as relevant; assert observable behavior and failure safety.

| Test | Setup, action, and expected result |
| --- | --- |
| `S015_UT01_minimalThemeInheritsDefaults` | Validate the documented minimal fixture; override supplied colors and inherit all other matching built-in colors. |
| `S015_UT02_rejectMalformedThemeVariants` | Table-drive duplicate keys, extra fields, invalid hex/version/type/ID, 15/17 ANSI entries, and over-limit input; receive specific validation errors. |
| `S015_UT03_paletteIndexesKeepOrder` | Load 16 distinct colors; engine palette indexes 0–15 match the declared order. |
| `S015_UT04_contrastWarningsNamePairs` | Use low-contrast foreground/background, selection, and cursor pairs; produce advisory field-pair warnings without rejecting otherwise valid custom data. |

## Integration and manual verification

Load both committed example files into the real preview and render all palette entries. Measure built-in text contrast ≥4.5:1 and essential focus/boundaries ≥3:1.

## Completion evidence

See [S015 JSON theme evidence](../../docs/evidence/S015-json-themes.md) for implementation, passing tests, independent review fixes, native fixture/diagnostic checks, and the boundary with S016 theme installation.

## Source specifications

[Overview](../01-overview/README.md), [architecture](../02-architecture/README.md), [functional requirements](../03-functional-requirements/README.md), [quality requirements](../04-non-functional-requirements/README.md), [API](../05-api/README.md), [integrations](../06-integrations/README.md), [macOS support](../07-macos-support/README.md), [themes](../03-functional-requirements/themes/README.md)
