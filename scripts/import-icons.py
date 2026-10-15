#!/usr/bin/env python3
"""Resolve upstream symlinks; retain only app-referenced names at 16, 22 and scalable sizes.

Supports size/context and context/size trees, and N x N Papirus directories.
Records a self-contained freedesktop index, so these subsets work with normal theme lookup.
An optional fourth argument strips upstream filename prefixes (Fluent uses default-).
"""
import pathlib
import re
import shutil
import sys

source, destination = map(pathlib.Path, sys.argv[1:3])
if not source.is_dir():
    raise SystemExit(f"Missing theme: {source}")
if destination.exists():
    raise SystemExit(f"Destination exists; choose an empty path: {destination}")
names = set()
for p in pathlib.Path("Sources").rglob("*.swift"):
    names.update(re.findall(r'"([a-z][a-z0-9.+-]*)"', p.read_text()))
names.update("folder unknown text-x-generic user-home user-desktop user-trash user-trash-full".split())
contexts = {"places", "mimetypes", "devices", "actions", "status", "emblems"}
candidates = {}
prefix = sys.argv[4] if len(sys.argv) > 4 else ""
for p in sorted(source.rglob("*")):
    name = p.stem.removeprefix(prefix) if prefix else p.stem
    name = {"folder-video": "folder-videos", "folder-publicshare": "folder-public"}.get(name, name)
    if p.suffix.lower() not in {".svg", ".png", ".pdf"} or name not in names or not p.is_file():
        continue
    parts = p.relative_to(source).parts
    context = next((part for part in parts[:-1] if part in contexts), None)
    if not context:
        continue
    size = next((part for part in parts[:-1] if re.fullmatch(r"\d+(?:x\d+)?", part)), "scalable")
    n = int(size.split("x")[0]) if size != "scalable" else 64
    candidates.setdefault((context, name), []).append((n, p))
dirs = set()
for (context, name), choices in sorted(candidates.items()):
    for target, pixels in [("16", 16), ("22", 22), ("scalable", 64)]:
        _, path = min(choices, key=lambda v: (abs(v[0] - pixels), v[1].suffix != ".svg", str(v[1])))
        directory = f"{target}/{context}"
        output = destination / directory / (name + path.suffix)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path.resolve(), output)
        dirs.add(directory)
(destination / "index.theme").write_text(
    "[Icon Theme]\nName=" + destination.name + "\nComment=Trimmed for Porpoise; see SOURCE.txt\nDirectories=" + ",".join(sorted(dirs)) + "\n" +
    "".join(f"\n[{d}]\nSize={64 if d.startswith('scalable') else d.split('/')[0]}\nType={'Scalable' if d.startswith('scalable') else 'Fixed'}\n" for d in sorted(dirs)))
licence = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
if licence and licence.is_file():
    shutil.copyfile(licence, destination / "LICENSE.txt")
print(f"{destination}: {sum(1 for p in destination.rglob('*') if p.is_file())} files")
