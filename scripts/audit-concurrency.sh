#!/bin/bash
# Build an isolated working-tree snapshot with complete Swift concurrency diagnostics, preserving Swift 5 mode.
# Usage: scripts/audit-concurrency.sh /absolute/path/to/new-evidence-directory
set -euo pipefail
if [[ $# != 1 ]]; then
    echo 'Usage: scripts/audit-concurrency.sh /path/to/new-evidence-directory' >&2
    exit 2
fi
repo=$(git rev-parse --show-toplevel)
python3 - "$repo" "$1" <<'PY'
from pathlib import Path
import datetime, json, os, shutil, subprocess, sys, uuid
repo=Path(sys.argv[1]).resolve()
out=Path(sys.argv[2]).resolve()
if out.exists():
    raise SystemExit('Use a new evidence directory; existing audit results are never overwritten.')
out.mkdir(parents=True)
snapshot=repo/'.build'/'concurrency-audit'/str(uuid.uuid4())
snapshot.mkdir(parents=True)
files=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=repo).split(b'\0')
for raw in files:
    if not raw: continue
    relative=Path(os.fsdecode(raw))
    if relative.is_absolute() or '..' in relative.parts: raise SystemExit('Invalid snapshot path')
    source=repo/relative; target=snapshot/relative
    if not source.exists() and not source.is_symlink(): continue
    target.parent.mkdir(parents=True,exist_ok=True)
    if source.is_symlink(): target.symlink_to(os.readlink(source))
    elif source.is_file(): shutil.copy2(source,target)
command=['swift','build','--build-tests','-j','2','-Xswiftc','-strict-concurrency=complete']
metadata={
 'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),
 'dirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=repo)),
 'swift':subprocess.check_output(['swift','--version'],text=True).strip(),
 'snapshot':str(snapshot),'command':command,'startedUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
(out/'metadata.json').write_text(json.dumps(metadata,indent=2))
print('Isolated source:',snapshot,flush=True)
print('Diagnostic log:',out/'build.log',flush=True)
with (out/'build.log').open('w') as log:
    result=subprocess.run(command,cwd=snapshot,stdout=log,stderr=subprocess.STDOUT)
metadata.update(exit=result.returncode,finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
(out/'metadata.json').write_text(json.dumps(metadata,indent=2))
print('Build exit:',result.returncode,flush=True)
# Preserve snapshot and raw diagnostics for review; remove only this snapshot manually when no longer needed.
sys.exit(result.returncode)
PY
