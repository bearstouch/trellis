# S030 terminal security and diagnostics

Date: 2026-10-16. Implemented with an independent security review and fixes, including one vendored-engine patch. Covered by automated tests; native checks are **pending**.

## Behavior

### Clipboard

Terminal output cannot reach the clipboard. OSC 52 writes and queries are no-ops: `clipboardCopy` does nothing and `clipboardRead` returns nil, so nothing is ever sent back to the program. Copy and paste remain explicit user actions. The v1 API has no clipboard capability, and the app keeps no clipboard history.

### Links

`LinkPolicy` decides which links may open:

- Only `http`, `https`, and `mailto`, with schemes compared case-insensitively.
- Web links need a host and must not carry credentials.
- No control characters or spaces; at most 2,048 characters.
- `mailto:` drafts keep only `subject` and `body`; other headers, such as `bcc`, are removed.

SwiftTerm requests a link only on a Cmd-click `mouseUp` that is not a selection drag. Trellis records that click on the view, opens the link only within 1.5 s, consumes the gesture with the first open, and clears it once the click has been handled. Output alone never opens anything. OSC 1337 and OSC 777 requests are no-ops, and title-report queries return empty strings.

### Engine file access

Kitty graphics `t=f`, `t=t`, and `t=s` would otherwise let terminal output read files, probe whether they exist, and unlink temp files or shared memory. They are refused with `ENOTSUP` in vendored SwiftTerm; direct `t=d` images still work. The patch is recorded in `ThirdParty/SwiftTerm/PATCHES.md` and `trellis.patch`.

### Logging, telemetry, and errors

- The engine's `log` and `error` output is silenced in every build (`silentLog = true`), because it could echo escape-sequence content.
- Trellis sources contain no `print`, `NSLog`, or `os_log` calls.
- There is no networking or telemetry.
- Control errors are fixed strings (S021/S022) and never echo input or tokens.

### Diagnostics export

Help → **Export Diagnostics…** builds a report only from allow-listed structured facts:

- app and macOS version, and architecture
- window, tab, and pane counts, and session-state counts
- saved-host, active-grant, and custom-theme counts
- the appearance mode and whether the control socket is running
- known stable error codes, such as `UI_ERROR` or `CONFLICT`

The report never contains names, titles, directories, commands, output, hosts, tokens, or the text of UI errors, and it lists what it excludes. `SecretRedactor` runs over it as defense in depth, removing tokens, hashes, private-key blocks, email addresses, and the home path.

The user sees the exact text in a preview. **Save…** writes that same text atomically with 0600 permissions; Cancel writes nothing.

## Tests

- `testS030_UT01_osc52CannotReadOrWriteClipboard`: four OSC 52 variants (write, primary, and two query forms) leave the pasteboard change count unchanged, with no reads or writes and no PTY reply. A `CSI 5n` control proves replies would be observed. Engine logging is silent.
- `testS030_UT02_validateUrlAndGesture`:
  - Without a gesture, nothing opens.
  - http, https, and mailto open after a click.
  - Ten forbidden links are refused: file, javascript, custom and ssh/vnc schemes, credentials, spaces, an ESC character, a missing host, and an overlong link.
  - A stale gesture is refused, and one gesture opens only one link.
  - A real `mouseUp` clears the gesture.
- `testS030_UT03_sanitizeErrorsAndDiagnostics`: secret window, tab, and pane names, a command, a password, a directory, a token, and IDs are all absent from the report, while counts, states, and known codes are present. The redactor handles tokens, hashes, keys, email, and the home path. Mailto header stripping and unknown error codes are also covered.
- `testS030_UT04_diagnosticCancelCreatesNoExport`: Cancel shows the preview and calls no write. Save writes exactly the previewed text, without the secret window name, the UI error path, or the error text.
- Review test `testKittyGraphicsCannotReadOrUnlinkLocalFiles`: a file and a temp-file transmission leave the file intact with no `OK` reply. A direct transmission does reply `OK`, which shows the check is meaningful.

Full suite: **295 tests passed, 0 failures**. Lint is clean, the build has zero warnings, and the app packages and verifies.

## Independent review

**Crucial (fixed):** Kitty graphics file, temp-file, and shared-memory transmission let any output — including from a remote SSH host or a `cat`ed file — read local files, probe whether they exist, and delete matching temp files or shared memory. A minimal engine patch now refuses these modes, and a regression test covers them.

The review also tightened gesture lifetime and made UT01 provably observe replies. I added mailto header stripping and the error-code allow-list.

Follow-ups, not applied:

- DECRQCRA can return checksums of the pane's own screen.
- OSC 8 link text may differ from the target; showing the URL on hover or confirming would help.
- Bidi formatting characters may appear in links. They are percent-encoded when the link opens.

## Pending manual verification

These checks were not performed and are **not** marked passed:

- Cmd-click links in a live pane.
- Confirm that OSC 52 output from a real program does not change the clipboard.
- Export diagnostics through the native sheet and inspect the saved file.
