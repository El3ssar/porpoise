# Daily-use reliability

Baseline: v0.19.3, `455ceb4c`. This pass covers the roadmap's second group using
owned temporary files/volumes, controlled servers, isolated settings and hosted Macs.
No local Porpoise window was ordered or activated, and no personal account was used.

## Parked tabs and previews

Hidden inspector/Columns previews retained decoded images and could restart background
work after detachment. Clearing a column did not clear its content. Cleanup now releases
images, posters, media, code and metadata, cancels pending detail/hover work and removes
thumbnail interest. A shared thumbnail still finishes for another visible owner. Returning
to a tab restores its current selection; same-turn layout reparenting preserves its preview.
Delayed callbacks cannot restart a parked column or inspector.

The original fixture reproduced three failures. Closed tabs/models were already released,
so this does not introduce a speculative global cache rewrite. Existing listing, history,
thumbnail and text-layout caches remain bounded.

Optimized before/after measurements on Apple M5, macOS 27.0.1, Swift 6.4.2: one warmup
pair followed by five alternating fresh-process pairs, with no concurrent build/test.
Each fixture parks 24 retained columns with distinct, touched 4 MiB bitmaps:

| Measurement | Before | After |
| --- | ---: | ---: |
| Retained images after parking, every measured run | 24 | 0 |
| Known decoded bitmap payload still retained | 96 MiB | 0 MiB |
| Median process resident-memory growth | 146.125 MiB | 49.875 MiB |
| Median process resident memory after parking | 214.953 MiB | 118.781 MiB |

[Raw pairs, binary hashes and source identities](data/parked-preview-memory.json).
[Repeatable command](../../Benchmarks/Browsing/README.md#parked-preview-memory).
RSS includes AppKit/allocator overhead; the exact ownership evidence is the weak-image
count and known payload. This is synthetic offscreen evidence, not a multiday/provider soak.

## Transfers, disconnections and Undo

Undo previously swallowed rollback failures and restored an obsolete full history record.
An arrival at a rollback destination could leave part of an operation undone while the
history still described its original state. Recovery now retains the remaining valid
record and the inverse of confirmed applied steps. The existing ordering/generation guards
still handle a new action recorded during Undo/Redo. Changed/ambiguous paths require manual
review; connected batch-rename chains involving temporary paths do not receive unsafe split
Undo/Redo entries. All involved paths are reported. Trash rollback failures retain origins.
A file already absent before Undo keeps its retryable record.

Regression controls using the old failure propagation produced six filesystem issues and
13 controller issues. The ordinary rollback test was corrected to actually execute an
initial successful move before the failing one. Tests cover independent move/Trash/rename
subsets, a dependent rename cycle, replacement rollback sources, copy-then-throw ambiguity,
synchronous/worker Undo and Redo, and newer actions invalidating stale Redo.

An active-disconnect fixture writes a 16 MiB staged move to its own APFS disk image, then
force-detaches only that volume at a progress checkpoint. It verifies the original source
bytes survive; after reattachment the previous destination is unchanged, a skipped retry
preserves both, and a retry into a new directory plus Undo succeeds. Disk-image fixtures also
exercise APFS, FAT32 and exFAT behavior. These use real filesystem drivers and mounted block
devices; they do not simulate USB bus/power failures or certify physical drives.

The shared [provider contract](PROVIDER-PARITY.md) checks local/mounted-local, loopback FTP
and SFTP, and controlled S3/Drive/Dropbox/Box/OneDrive operations, conflicts, token expiry,
paging and outage/reconnect. SMB remains a mounted-local delegation boundary, not a real
SMB authentication/reconnect test. Cloud fixtures are not real account acceptance.

Final optimized local runs: 91 filesystem tests in 11 suites and 64 service tests in 10
suites passed. The focused app run reported 14 tests in three suites (the opt-in benchmark
was skipped there); all 12 separate paired benchmark processes passed. No timeout or safety
assertion was relaxed. Hosted full validation is recorded separately on the delivery PR.

## macOS compatibility

The app supports Apple Silicon and macOS 15+. Native CI previously ran only on macOS 26.
The existing UI workflow now accepts a manual `runner=macos-15` choice, with macOS 26 still
the default for ordinary CI. Only these two hosted labels can be selected. Toolchain/OS and
arm64 identity are recorded. The job runs light/dark native acceptance and executes the
bundled CLI's help plus fd, rg and ffmpeg version commands on that OS.

```sh
gh workflow run ui-acceptance.yml --ref main -f runner=macos-15
```

Release validation now checks every bundled Mach-O arm64 slice, macOS deployment floor
and executable dependency graph, including nested Sparkle tools. It rejects non-system
absolute dependencies and unresolved bundled loads. Nine deterministic fixture tests passed;
the existing local test bundle's nine images passed static inspection. Static load checks
cannot prove symbol availability, dynamically opened libraries, signing or actual runtime
behavior. Hosted macOS 15/26 results and final release packaging are separate evidence.

No physical external drive was available. Local tests use the owned M5 Mac offscreen;
hosted Apple Silicon desktops are virtual machines. Wider hardware, physical USB and attended
VoiceOver checks remain unverified.

## First-install cloud setup

Callback parsing treated every OAuth error as cancellation, hiding provider/configuration
failures. Only consent denial retains cancellation behavior; malformed callbacks and other
provider failures now produce readable retry messages. Redirect/state checks still run
first and provider-supplied descriptions are not echoed. Shared configuration, timeout and
invalid-response errors now have useful copy. Drive rejects an empty first refresh token,
so an unusable account is not persisted; retry with a durable token succeeds.

The new cloud fixtures reproduced 21 issues before the fix and pass in the integrated
service run. They use in-memory account/credential stores, fake HTTP and a real ephemeral
loopback callback, without launching a browser or using the system Keychain.

Configuration-presence audit of release settings and installed v0.19.3 metadata:

| Service | Built-in registration | Remaining acceptance |
| --- | --- | --- |
| Drive | Client ID/secret present | Actual new-user consent, publication/scopes and account eligibility |
| Dropbox | App key present | Registered redirects, permissions and actual new-user consent |
| OneDrive | Client ID absent | Add a suitable Entra app registration; verify redirects/account types and consent |
| Box | Client ID/secret absent | Add an app registration; verify redirects/scopes and account/admin authorization |
| S3-compatible | Uses saved access keys, no bundled OAuth client | Actual endpoint/region/bucket permission checks |

Missing services are labelled “Unavailable in this build”. Missing Drive configuration no
longer points to a settings field that release builds do not offer. Registration values,
user tokens and credentials were not displayed or recorded. No registrations were invented.

A cookie-free public authorization preflight reached Drive's login page. Dropbox returned
HTTP 200 for its configured ports but could not be positively classified. Neither result
proves consent, durable account setup or first-user eligibility; actual live sign-in remains
pending. [Google native-app OAuth](https://developers.google.com/identity/protocols/oauth2/native-app)
and [Dropbox OAuth](https://developers.dropbox.com/oauth-guide) describe registration/redirect
requirements. [RFC 6749 section 4.1.2.1](https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1)
distinguishes authorization failures from consent cancellation.
