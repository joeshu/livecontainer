# Project review — 2026-10-03

This review follows the host startup, local/URL IPA import, archive extraction,
app replacement, file sharing, combined background refresh, signing settings,
localization and build/package paths. It is a source and automated behavior
review, not a claim that every dependency or iOS private API has been verified.

## Confirmed issues addressed in this change

| Path | Problem | Result |
| --- | --- | --- |
| Startup / unused containers | `hasDirectoryPath` examines URL syntax rather than filesystem type | Enumerate actual directories; regular files are excluded |
| Startup | A shared-storage error aborted subsequent container/tweak indexing | Storage areas are indexed independently |
| Startup | App initialization and URL-scheme conversion were force-unwrapped | Conditional initialization and typed string collection |
| Download | Retained continuation allowed duplicate or old callbacks to finish a later request | Checked continuation, current request ID and one-shot completion |
| Download cancellation | A late successful download could write a staged file after cleanup | Cancel claims the delegate completion before retiring the request |
| Download progress | Unknown/zero lengths caused invalid fractions and misleading totals | Clamp known progress; use indeterminate display for unknown totals |
| Download session | Session/delegate lifetime was not explicitly ended | Invalidate after completion and cancellation |
| URL installation | Remote filenames reused global temporary paths; failed cleanup appeared as install failure | Unique request directory and best-effort deferred cleanup |
| IPA extraction | Global Payload directory could collide; failures left extracted files | Unique extraction directory with cleanup on exit |
| Archive reader | Disk/header failures could still return success | Propagate unsuccessful extraction and close failures |
| Archive boundary | Member traversal, absolute paths and escaping links were not explicitly checked | Reject traversal/absolute members, escaping symlinks and hardlinks; libarchive secure link checks |
| Bundle metadata | Missing identifier was converted to `Unknown` before validation; identifier force unwraps remained | Validate source plist identifier/type/path before model creation |
| App replacement | Old bundle deleted before replacement move succeeded | Preserve old bundle until move succeeds; restore on move failure |
| Debug signing exports | Documents URL force unwrap; certificate write was non-atomic | Guard unavailable directory and atomically write certificate data |

Replacement rollback covers a failed filesystem move, not a crash between two
renames or a signing failure after installation. A failed rollback retains the
backup directory. Existing behavior allowing unsigned imports after signing
errors is preserved. The archive reader deliberately rejects hardlinks and
escaping/absolute links; legitimate internal relative symlinks remain supported.

## Existing protections checked

- Sharing stages IPA files into the App Group before extension completion.
- Background refresh generations, cancellation, reconnect, persistent recovery,
  worker leases and scoped directory identities remain covered by regressions.
- The embedded SideStore revision and full patch are pinned; source/channel and
  standalone/combined IPA contracts are checked during the build.
- Module-owned localization checks cover explicit static text calls and format
  arguments. Model/user values are preserved in localized templates.

## Verification

Local Python package/source regressions, sharing and LiveProcess contracts pass.
macOS CI compiles production filesystem and download components and exercises
real replacement/rollback, malformed identifiers, unknown progress, stale task
completion, cancellation-before-late-success, synchronous staging and HTTP errors.
It compiles the production Objective-C extractor against libarchive and uses
actual valid, damaged and boundary-violating ZIP fixtures plus a blocked output.
The complete iOS build checks host integration and embedded SideStore packaging.
See PR #22 for the latest CI results and the matching IPA artifact.

## Device validation still needed

Background URLSession transitions when iOS suspends or terminates the app;
Files/iCloud imports and storage exhaustion; replacing a running guest app;
locked-device refresh and installation accepted by iOS before bridge interruption;
small-screen and Dynamic Type layouts; guest runtime hooks on supported iOS
versions. The new download lifecycle does not restore an in-flight download
across process death. Persistent, crash-safe installation transactions and a
full metadata schema migration are separate follow-up work.
