#!/usr/bin/env python3
"""Deduplicate complete-concurrency diagnostics without losing occurrences or unknown warnings.

Usage: concurrency-diagnostics.py EVIDENCE_DIRECTORY
Reads metadata.json/build.log from audit-concurrency.sh. Writes diagnostics.json/csv,
summary.json and files.md. Risk routing is conservative triage, not a race detector.
"""
import collections
import csv
import json
from pathlib import Path
import re
import sys


def triage(file, message):
    if any(marker in message for marker in ['[#NoUsage]', '[#DeprecatedDeclaration]', '[#UnnecessaryEffectMarker]', '[#TrailingClosureMatching]', 'does not unwrap optional', "'@discardableResult' declared on a function returning 'Void' is unnecessary"]):
        return 'P3-other', 'Non-concurrency compiler warning', 'Review the unused result separately; retained so the audit does not discard unrelated warnings.'
    if "struct 'Lost'" in message and "Shell.Result" in message:
        return 'P2-value', 'Error payload is a value result without declared Sendable conformance', 'Give Shell.Result checked Sendable conformance after verifying all stored fields are Sendable; preserve error payloads.'
    if file == 'Sources/PorpoiseHelper/main.swift':
        return 'P2-queue', 'Connection count and idle work are main-queue confined', 'Express main-owned connection lifecycle separately from nonisolated XPC request methods; preserve synchronous admission ordering.'
    if file.endswith('/FolderSearch.swift') or file.endswith('/SearchIndex.swift'):
        return 'P2-synchronization', 'Joined workers mutate a collection under a dedicated lock', 'Replace captured mutable arrays with a checked locked state container; retain group join, ordering and cancellation.'
    if '/checkouts/' in file or file.startswith('Vendor/'):
        return 'P3-vendor', 'Upstream dependency', 'Upgrade or patch upstream with its own concurrency tests; retain diagnostics here.'
    if file.startswith('Tests/'):
        return 'P2-test', 'Test harness or fixture boundary', 'Annotate UI tests with MainActor; use Sendable immutable fixtures and locked recorders before Swift 6.'
    if 'NameIndexSearch.swift' in file or 'PhysicalTreeScanner.swift' in file:
        return 'P2-parallel', 'Joined parallel traversal with pointer or local-function captures', 'Prove lifetime and disjoint writes; introduce checked scoped worker values and Sendable cancellation contracts.'
    if any(s in file for s in ['TrashService.swift', 'SaveWatcher.swift', 'ArchiveProvider.swift', 'LocalFileServer.swift', 'AndroidTools.swift']):
        return 'P2-synchronization', 'Lock or serial queue ownership requires explicit compiler-visible contract', 'Audit every field and callback against its lock/queue; isolate worker state before adding any unchecked conformance.'
    if any(s in file for s in ['/FileOperations/', 'SearchRunner.swift', 'SpotlightQuery.swift', 'DirectoryModel', 'RemoteFolderTree.swift', '/Media/', 'RemoteOpener.swift', 'RemoteEditSession.swift', 'LocalNetworkAccess.swift', '/Cloud/', '/Locations/', '/Remote/']):
        return 'P1-boundary', 'Mutable service facade crosses worker/main/async boundaries', 'Prioritize actor facade plus immutable Sendable worker request/result; audit cancellation and stale completion before Swift 6.'
    if file.startswith('Sources/Porpoise/'):
        return 'P2-UI', 'AppKit facade or callback actor contract', 'Make UI ownership MainActor and explicitly deliver callback ingress; do not transfer AppKit values through workers.'
    if 'static property' in message or 'static var' in message or 'shared mutable' in message:
        return 'P1-global', 'Shared state ownership not proved to compiler', 'Choose main actor for UI state or a lock/actor for non-UI state; audit reads as well as writes.'
    return 'P1-review', 'Unproved Sendable or isolation boundary', 'Review this exact site before migration; avoid blanket unchecked Sendable or preconcurrency suppression.'


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    folder = Path(sys.argv[1])
    metadata = json.loads((folder / 'metadata.json').read_text())
    prefix = metadata['snapshot'].rstrip('/') + '/'
    found = {}
    recoveries = []
    snapshot = Path(metadata['snapshot'])
    known_paths = [str(path.relative_to(snapshot)) for root in ['Sources', 'Tests'] for path in (snapshot / root).rglob('*.swift')]
    lines = (folder / 'build.log').read_text(errors='replace').splitlines()
    for index, line in enumerate(lines):
        match = re.match(r'(.+?):(\d+):(\d+): (warning|error): (.+)', line)
        if match:
            file, row, column, kind, message = match.groups()
            if file.startswith('macro expansion '):
                for origin in lines[index + 1:index + 4]:
                    source = re.search(r'(?:`- )(.+?):(\d+):(\d+): note: expanded code originates here', origin)
                    if source:
                        message = f'[{file}:{row}:{column}] {message}'
                        file, row, column = source.groups()
                        break
            file = file.removeprefix(prefix)
            if not file.startswith(('Sources/', 'Tests/', '.build/')):
                matches = [path for path in known_paths if path.endswith(file)]
                if len(matches) == 1:
                    recoveries.append(dict(reportedFile=file, resolvedFile=matches[0], line=int(row), column=int(column), reason='Unique source suffix after interleaved build progress truncated the path'))
                    file = matches[0]
            # Snapshot .build dependency paths remain visible and separately owned.
            key = (file, int(row), int(column), kind, message)
        else:
            match = re.match(r'^(warning|error): (.+)', line)
            if not match:
                continue
            kind, message = match.groups()
            key = ('<driver>', 0, 0, kind, message)
        if key in found:
            found[key]['occurrences'] += 1
            continue
        file, row, column, kind, message = key
        risk, ownership, plan = triage(file, message)
        found[key] = dict(file=file, line=row, column=column, kind=kind, message=message,
                          occurrences=1, risk=risk, ownership=ownership, plan=plan)
    diagnostics = sorted(found.values(), key=lambda d: (d['file'], d['line'], d['column'], d['message']))
    (folder / 'location-recoveries.json').write_text(json.dumps(recoveries, indent=2) + '\n')
    (folder / 'diagnostics.json').write_text(json.dumps(diagnostics, indent=2) + '\n')
    fields = ['file', 'line', 'column', 'kind', 'message', 'occurrences', 'risk', 'ownership', 'plan']
    with (folder / 'diagnostics.csv').open('w', newline='') as output:
        writer = csv.DictWriter(output, fieldnames=fields)
        writer.writeheader()
        writer.writerows(diagnostics)
    summary = dict(buildExit=metadata.get('exit'), unique=len(diagnostics),
                   occurrences=sum(d['occurrences'] for d in diagnostics),
                   byKind=dict(collections.Counter(d['kind'] for d in diagnostics)),
                   byRisk=dict(collections.Counter(d['risk'] for d in diagnostics)))
    (folder / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    files = collections.defaultdict(list)
    for diagnostic in diagnostics:
        files[diagnostic['file']].append(diagnostic)
    lines = ['# Diagnostic files', '', 'Generated conservative triage; individual sites and occurrence counts are in diagnostics.csv.', '',
             '| File | Unique sites/messages | Risk | Ownership |', '| --- | ---: | --- | --- |']
    for file, items in sorted(files.items()):
        lines.append(f"| {file} | {len(items)} | {', '.join(sorted(set(d['risk'] for d in items)))} | {items[0]['ownership']} |")
    (folder / 'files.md').write_text('\n'.join(lines) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
