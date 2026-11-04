# Roadmap

Make Porpoise the file manager people want to use every day: fast, polished and dependable.

## Next

- [x] Remove the UI freeze when opening Compact view in folders with many short filenames.
- [x] Measure and fix remaining delays in navigation, Back, sorting and view changes in large folders.
- [x] Keep browsing and searching responsive while previews load and transfers run.
- [x] Polish keyboard navigation, hover feedback, accessibility and loading/conflict messages.

## Then

- [x] Improve memory use and responsiveness during long sessions with many tabs.
- [x] Check copy, move, rename and Undo using local files, mounted disk images and
  controlled server/cloud fixtures, including disconnections and permission errors.
- [ ] Validate the published app on macOS 15, 26 and 27; check bundled tools on Apple M5.

Automated coverage and remaining hardware/account checks: [validation notes](docs/validation/DAILY-USE-RELIABILITY.md).

## Later

- [ ] Enable OneDrive after app registration and live sign-in checks are available.
- [ ] Enable Box after app registration and live sign-in checks are available.
- [ ] Test physical USB drives and Android devices when hardware is available.

## Research

- [ ] Find out which “Open in Finder” actions can reliably open Porpoise instead.
- [ ] Work out how Porpoise could fit into macOS Open/Save dialogs.
- [ ] Explore reading ext4 drives and disk images inside Porpoise.
- [ ] Investigate NTFS writing and system-wide filesystem mounting: what is practical,
  safe to distribute and maintain?

## Ideas to discuss

These need brainstorming before deciding whether to build them.

- Browse disk images and VM partitions without booting a virtual machine.
- Search screenshots and scanned documents by the text inside them.
- Write and verify OS images on USB drives and SD cards.
- Share files with nearby phones, Windows PCs and Linux computers.
- Find other substantial features that would make Porpoise worth installing on their own.

## Updating this file

Add new ideas here. Move selected ideas into Next or Then, and check items off as they
are completed. Keep entries short; put implementation details and research in linked docs.
