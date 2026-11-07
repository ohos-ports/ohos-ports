#!/usr/bin/env python3
"""Import an official Electron-OH release archive into a verified build cache."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import urllib.request
import zipfile

ELECTRON = Path(__file__).resolve().parents[1]


def digest(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def extract(archive, dest):
    for item in archive.infolist():
        name = PurePosixPath(item.filename)
        if name.is_absolute() or '..' in name.parts or '\\' in item.filename:
            raise ValueError('Unsafe archive path: ' + item.filename)
        if (item.external_attr >> 16) & 0o170000 == 0o120000:
            raise ValueError('Archive symlinks are not supported: ' + item.filename)
    archive.extractall(dest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='local official release ZIP; preferred for authenticated downloads')
    parser.add_argument('--output', type=Path, required=True, help='new cache directory')
    args = parser.parse_args()
    lock = json.loads((ELECTRON / 'electron-oh.lock.json').read_text())
    source = lock['runtimeSource']
    output = args.output.resolve()
    if output.exists():
        parser.error('output exists; choose a new directory')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.electron-oh-', dir=output.parent) as temp:
        cache = Path(temp)
        archive = args.archive
        if archive is None:
            archive = cache / 'release.zip'
            try:
                with urllib.request.urlopen(source['url'], timeout=60) as reply, archive.open('wb') as out:
                    shutil.copyfileobj(reply, out)
            except OSError as error:
                raise SystemExit('Official download failed; obtain the same release using upstream authentication and pass --archive. ' + str(error))
        if digest(archive) != source['archiveSha256']:
            raise ValueError('Official release archive checksum mismatch')
        runtime = cache / 'runtime'
        with zipfile.ZipFile(archive) as release:
            shim_names = [n for n in release.namelist() if n.endswith(source['shimArchiveSuffix'])]
            if len(shim_names) != 1:
                raise ValueError('Expected one bundled shim archive')
            shim_bytes = release.read(shim_names[0])
            if hashlib.sha256(shim_bytes).hexdigest() != source['shimArchiveSha256']:
                raise ValueError('Bundled shim archive checksum mismatch')
            extract(release, runtime)
        with zipfile.ZipFile(io.BytesIO(shim_bytes)) as shim_zip:
            extract(shim_zip, cache / 'shim')
        shims = list((cache / 'shim').rglob('libshim.a'))
        engines = list(runtime.rglob('libelectron.so'))
        shims = [p for p in shims if digest(p) == lock['shimSha256']]
        engines = [p for p in engines if digest(p) == lock['runtimeLibrarySha256']]
        if len(shims) != 1 or len(engines) != 1:
            raise ValueError('Pinned shim/runtime not uniquely found')
        profile = {'source': source, 'shim': str(shims[0].parent.parent.relative_to(cache)),
                   'runtimeLibrary': str(engines[0].relative_to(cache))}
        (cache / 'profile.json').write_text(json.dumps(profile, indent=2) + '\n')
        (cache / 'release.zip').unlink(missing_ok=True)
        shutil.move(cache, output)
    print(json.dumps({'cache': str(output), **profile}, indent=2))


if __name__ == '__main__':
    main()
