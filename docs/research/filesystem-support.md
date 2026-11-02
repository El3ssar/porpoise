# Filesystem compatibility investigation

Reviewed 2026-11-02 against Porpoise 0.18.0 (`efd41202`). This is a feasibility decision record, not a shipped capability or a certification of the projects linked below. No driver was installed, device mounted, or personal disk inspected.

## Product goal

Connect a Windows or Linux disk and understand what Porpoise can do with it, without having to research drivers or use a terminal. Distinguish three outcomes:

1. Detect the filesystem and explain the current access mode.
2. Browse and copy files **inside Porpoise** through a provider.
3. Mount the filesystem under `/Volumes` so **all applications** can use it.

The second outcome does not imply the third. A file browser cannot give other applications access to its private provider URLs merely by exposing them in its sidebar.

## Verified platform facts

- macOS can read ordinary NTFS volumes but does not provide ordinary NTFS writing. NTFS is therefore primarily a write-access gap, rather than an entirely unmountable format. [Apple](https://support.apple.com/en-ie/101830)
- FSKit implements filesystems in user-space app extensions and integrates with Disk Arbitration and mounting tools. It supplies the platform interface, not an ext4 or NTFS implementation. [Apple FSKit](https://developer.apple.com/documentation/fskit/)
- FSKit modules declare `com.apple.developer.fskit.fsmodule`. Existing FSKit projects document the need for an entitlement-authorizing provisioning profile. Porpoise's current self-signed release process is not evidence that an FSKit extension can be distributed through that process. Verify signing/provisioning before committing to an integrated installer. [Apple entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule), [xlinuxfs build requirements](https://github.com/HuanchuanTech/xlinuxfs#build--provisioning)
- macFUSE offers both a kernel backend and a newer FSKit backend on macOS 15.4+. The latter avoids a kernel extension but currently has capability and performance limitations. It is incorrect to say every macFUSE configuration requires Reduced Security. [Upstream backend comparison](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- The macFUSE binary license has a restriction on bundling with commercial software, including automated installation. Source/binary redistribution terms must be evaluated for the exact product/distribution; it is not a generic unrestricted dependency. [Upstream license](https://github.com/macfuse/macfuse/blob/release/macfuse/LICENSE.txt)

## Engine candidates, not selections

| Candidate | What upstream implements or claims | Evaluation needed |
| --- | --- | --- |
| xntfs / ntfs-3g | FSKit NTFS read/write; different mount workflows on macOS 15, 26 and 27 | Signing, actual supported-OS mounts, metadata/ADS, dirty/hibernated media, lifetime/rename/crash behaviour, engine and adapter licenses |
| xlinuxfs / LKL | FSKit bridge to Linux ext2/3/4, XFS and Btrfs implementations | Large native dependency, feature compatibility, real OS-mounted validation, cancellation, corruption handling and Linux GPLv2 redistribution boundaries |
| ext4fuse | Read-only ext4 FUSE implementation | Actual supported ext4 feature flags, current Apple Silicon/backend compatibility, maintenance and redistribution |
| fuse-ext2 | ext2/3/4 FUSE implementation | Upstream explicitly warns about write safety and broken multithreading; not a suitable default write engine on that evidence |

Primary sources: [xntfs](https://github.com/HuanchuanTech/xntfs), [xlinuxfs](https://github.com/HuanchuanTech/xlinuxfs), [ext4fuse](https://github.com/gerard/ext4fuse), [fuse-ext2](https://github.com/alperakcan/fuse-ext2).

Published project features and upstream test claims are not Porpoise verification. No performance, safety, full ext4-feature support, or license compatibility is assumed from a README. In particular, do not link a GPLv2-only engine into this GPLv3 app on the assumption that both being GPL resolves compatibility. Packaging separate components also requires an actual redistribution review.

## Recommended first experiment

Use owned synthetic **read-only ext4 disk images**, not raw devices or user data. Determine whether a maintained engine can list directories and stream file contents into Porpoise's existing provider/copy contract with bounded memory and cancellation. This can establish useful application-local access without requiring system-wide mounts.

Measure and check:

- Known file hashes, Unicode names, symlinks, hard links, sparse files and large directories.
- ext4 feature masks, dirty journals, truncated images, invalid lengths and unsupported encryption/features. Unsupported media gets a truthful explanation rather than silent omissions.
- First listing time, sustained reads, peak memory, cancellation latency and work remaining after cancellation.
- No image writes, journal replay, automatic repair or source modification.
- Provider capabilities accurately expose read-only access, export/materialization and unsupported mutations.

Only after this experiment should we select an engine or promise a supported ext4 configuration.

## Separate system-wide mounting milestone

Before implementing an integrated FSKit module, resolve the signing/provisioning path and current no-paid-maintainer-services policy, supported OS floor (FSKit is newer than Porpoise's macOS 15.0 minimum), extension enablement and removal UX, source/license obligations and update compatibility.

Test on actual owned devices and each supported OS, including power loss/unplugging, sleep, Windows Fast Startup/hibernation, dirty volumes, full disks, concurrent readers and metadata round trips. NTFS writing is a separate qualification from read-only Linux access. Do not make a recovered/unclean disk writable simply because an engine accepts a write flag.

The existing privileged helper is descriptor-scoped; this investigation does not authorize turning it into a general arbitrary-device mount/repair service. Raw device access and installation require their own reviewed implementation.

## Status

Feasibility researched; no engine selected, bundled, downloaded, installed or enabled. Next deliverable is an isolated synthetic-image experiment and a component/signing decision, not a public claim of batteries-included drive support.
