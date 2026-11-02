# Product differentiators under discussion

Reviewed 2026-11-02. These are candidate directions, not scheduled features. The operator rejected the previous shortlist of picker assistance, guided SD import, private vaults and drive troubleshooting as insufficiently compelling. Do not reintroduce those as approved roadmap items.

The desired bar is an additional capability substantial enough to be a reason to install Porpoise by itself. It must coexist with a fast, polished file manager and a free-to-maintain product.

| Direction | Concrete promise to investigate | Existing foundation vs new work | Main uncertainty |
| --- | --- | --- | --- |
| Windows/Linux drive access | Read a Linux drive or write an NTFS disk through an integrated, understandable experience | Porpoise has provider/copy contracts; filesystem engines and OS mounts are new | Engine correctness, signing, licensing, supported filesystem features; see [filesystem investigation](filesystem-support.md) |
| A drive-image workbench | Inspect a Raspberry Pi/VM disk image, navigate its partitions and extract a file without booting the VM | Archive/provider UI can be reused; partition/image-format readers and filesystem access are new | Start with raw images; do not imply QCOW2/VHDX/encryption/compression support without implementation and validation |
| Find files by what is inside an image | Search a screenshot or scanned document by words visible in it; optionally evaluate visual/semantic search later | Existing search/index lifecycle can be reused; explicit opt-in OCR/index content is new | Accuracy, index privacy/storage and energy budgets; semantic models are a separate experiment, not free functionality supplied by OCR |
| A verified image writer | Flash an OS image to an SD card/USB drive with clear device identity and read-back verification | Existing progress presentation is reusable; destructive raw-device writing is entirely new | Device authorization/identity, interruption, repair boundaries and supported image types; substantial separate safety work |
| Cross-platform nearby sharing | Send selected files to a phone or Windows/Linux computer through a paired local browser session, without a cloud account | Existing transfer engine can supply progress; pairing, transport and receiving UI are new | Peer authentication, local-network permission, HTTPS/browser constraints, resumability and receiver compatibility |

Relevant primary references:

- [Apple Vision](https://developer.apple.com/documentation/vision/) supplies text-recognition and image-analysis APIs. This is a technical building block, not proof of an accurate or energy-efficient whole-disk search product.
- [balena Etcher](https://etcher-docs.balena.io/) is a reference for the standalone value of an image writer. Its existence does not establish that Porpoise should absorb this scope or that its code can be redistributed without review.
- [Filesystem investigation](filesystem-support.md) records current FSKit, NTFS and Linux-engine sources and blockers.

Recommendation for discussion: treat filesystem access and image inspection as one coherent interoperability direction. Evaluate image-content search separately against the performance/energy goal. Defer destructive image writing and a network-sharing service until demand justifies owning those additional subsystems. None is approved for implementation merely by being listed here.
