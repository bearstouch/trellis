# Notices for the static Linux remote helpers

`scripts/build-remote-helpers.sh` links `trellis-broker` statically with the Swift static Linux SDK 0.1.0 (Swift 6.4.1).
Besides Trellis's own code, the binaries contain, per the SDK's `sbom.spdx.json` and checked in the binaries:

| Component | Version | License | Notice |
| --- | --- | --- | --- |
| musl libc | 1.2.5 | MIT | `musl-COPYRIGHT.txt` (upstream `COPYRIGHT` at tag v1.2.5) |
| mimalloc | 2.2.4 | MIT | `mimalloc-LICENSE.txt` (upstream `LICENSE` at tag v2.2.4) |
| musl-fts (`fts_open` and friends, used by FoundationEssentials) | 1.2.7 | BSD-3-Clause | `musl-fts-COPYING.txt` (upstream `COPYING` at tag v1.2.7) |
| Swift runtime, FoundationEssentials, Dispatch | 6.4.1 | Apache-2.0 with the Runtime Library Exception | None required for compiled code |

The build script copies these notices beside the helpers, so they ship in `Trellis.app/Contents/Resources/remote/`.
Re-check this list when the SDK version or the helper's imports change.
