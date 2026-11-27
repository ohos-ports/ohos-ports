#!/usr/bin/env python3
"""Independent build-only CI entry point. No npm credentials or publication."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import urllib.request

ELECTRON = Path(__file__).resolve().parents[1]
BASELINE_URL = 'https://registry.npmjs.org/@ohos-ports/better-sqlite3/-/better-sqlite3-13.0.3.tgz'
BASELINE_SHA256 = 'bcd5acef74f8077ba2d803b6297885668088eaa0cb9dc618a2b2a48ffd8aa83c'


def run(*args, cwd=None):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True, help='new directory')
    args = parser.parse_args()
    work = args.work_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    artifacts = work / 'artifacts'
    artifacts.mkdir()
    baseline = artifacts / 'baseline.tgz'
    with urllib.request.urlopen(BASELINE_URL, timeout=60) as reply:
        baseline.write_bytes(reply.read())
    assert hashlib.sha256(baseline.read_bytes()).hexdigest() == BASELINE_SHA256
    source = work / 'source'
    source.mkdir()
    with tarfile.open(baseline, 'r:gz') as archive:
        archive.extractall(source, filter='data')
    source = source / 'package'
    run('npm', 'install', '--ignore-scripts', '--omit=dev', '--no-save', '--package-lock=false',
        'node-addon-api@8.9.2', cwd=source)
    output = work / 'candidate'
    run('bash', ELECTRON / 'build-electron-oh.sh', '--source', source, '--output', output,
        '--ndk', os.environ['OHOS_NDK'], '--shim', os.environ['ELECTRON_OH_SHIM'],
        '--runtime-library', os.environ['ELECTRON_OH_RUNTIME_LIBRARY'], '--allow-unsigned')
    run('npm', 'pack', '--ignore-scripts', '--pack-destination', artifacts, cwd=output)
    candidates = [p for p in artifacts.glob('*.tgz') if p != baseline]
    assert len(candidates) == 1
    candidate = candidates[0]
    report = subprocess.check_output(['python3', str(ELECTRON / 'tests/verify-package.py'),
                                      str(baseline), str(candidate)], text=True)
    (artifacts / 'package-comparison.json').write_text(report)
    run('python3', ELECTRON / 'tests/test-package-contract.py', baseline, candidate)
    run('python3', ELECTRON / 'tests/test-release-guard.py', baseline, candidate)
    preflight = subprocess.run(['python3', str(ELECTRON / 'tools/check-release.py'),
                                str(baseline), str(candidate)], capture_output=True, text=True)
    result = json.loads(preflight.stdout)
    assert preflight.returncode == 1 and result['status'] == 'blocked'
    assert any('local test/self-signed' in error for error in result['errors'])
    (artifacts / 'release-preflight.json').write_text(preflight.stdout)
    print('PASS: release preflight rejects the local-only CI package')
    materials = json.loads((ELECTRON / 'release-materials.lock.json').read_text())
    (artifacts / 'build-result.json').write_text(json.dumps({
        'status':'built-not-published', 'candidateSha256':hashlib.sha256(candidate.read_bytes()).hexdigest(),
        'baselineSha256':BASELINE_SHA256, 'nodeRuntime':'not-run', 'electronOhHap':'not-run',
        'signature':'unsigned-local-only', 'notices':materials['shimAuthorization']['status']}, indent=2)+'\n')


if __name__ == '__main__':
    main()
