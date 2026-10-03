# LiveContainer+SideStore reliability changes

The refresh bridge reserves a task before launching LiveProcess. All lifecycle
state runs on the main queue. Each process has a generation and each refresh has
a task ID. Readiness requires an XPC client, the launch notification, and the
extension request's PID; these signals may arrive in any order.

Timeout, cancellation, interruption and invalidation clear the task exactly once
and retire the process generation. The bridge kills the old LiveProcess before
allowing a retry so its outstanding operation cannot overlap a new bridge task.
The iOS installation service may still complete an installation already handed
to it; a bridge timeout does not roll back an OS installation.

## Combined builds

CI builds SideStore at the commit pinned in `.github/workflows/build.yml` and
applies `scripts/patches/sidestore-combined-reinstall.patch` before compiling it.
The patch preserves certificate validation, adapts the resign screen for the
host, shows certificate/profile expiry dates, and rejects self-reinstall packages
without the configured source or required combined components.

`scripts/ci/configure_combined.py` injects the repository's combined update source
and release channel, validates both AppIntent type mappings, and records source
commits, the embedded IPA checksum, and the integration patch checksum in
`LCBuildManifest.json`. These values record provenance; they are not a signature
or remote attestation.

Local combined packaging requires `SIDESTORE_SOURCE_SHA`,
`SIDESTORE_IPA_PATH`, and `SIDESTORE_IPA_SHA256`. Set `GITHUB_REPOSITORY` to the
intended repository (default `joeshu/livecontainer`) and `LC_RELEASE_CHANNEL` to
`stable` or `nightly`. Apply the integration patch to the pinned SideStore before
building its IPA. Existing stable 1.4 builds predate this contract; a new host
rejects them during self-reinstall rather than silently downgrading. Publish a
new combined release with this contract before distributing a new stable build.
Changing the source URL does not rewrite an existing SideStore database entry;
refresh the source before retrying self-reinstall.

The combined source seed uses the published 1.4 combined artifact, version
3.8.9, and its actual asset size. The updater removes upstream and standalone
artifacts and uses the current local IPA's size when publishing nightly builds.
The `1.0` tag is a source distribution endpoint and is excluded from app release
selection. The nightly release job also updates its `apps_ss_lc.json` asset,
because releases created with `GITHUB_TOKEN` do not trigger another release
workflow automatically.

## Validation

Run:

```sh
python3 -m unittest discover -s scripts/ci/tests -p 'test_*.py' -v
python3 scripts/ci/verify_liveprocess_contract.py
python3 scripts/ci/verify_share_ipa_handoff.py
bash -n .github/build_github.sh
swiftc SideStoreSupport/RefreshTaskState.swift scripts/ci/tests/main.swift -o /tmp/refresh-tests
/tmp/refresh-tests
```

The macOS lifecycle CI job runs the Swift behavioral regressions and validates
the patch against pinned SideStore. The full Xcode job validates the final IPA's
manifest, dylib conversion, AppIntents metadata, extensions and Chinese resources.
The Swift lifecycle test exercises the production state coordinator; it does not
simulate Apple's private extension or AppIntents implementation.

Before release, validate on device: two simultaneous refresh triggers, refresh
cancellation, extension termination during startup and refresh, retry after
failure, notification permission denied/granted, and self-reinstallation while
preserving LiveContainer guest data and both extensions. A valid expired
certificate/profile still requires reinstallation with a valid signature.
