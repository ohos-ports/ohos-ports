#!/usr/bin/env python3
"""Compare the actual npm tarballs, including every original Node loader."""
import hashlib
import json
from pathlib import Path
import sys
import tarfile


def read_package(path):
    with tarfile.open(path, "r:gz") as archive:
        return {item.name.removeprefix("package/"): archive.extractfile(item).read()
                for item in archive.getmembers() if item.isfile()}


def verify(baseline, candidate):
    original, updated = read_package(baseline), read_package(candidate)
    # No original file is allowed to change or disappear except package metadata.
    for name, content in original.items():
        if name != "package.json":
            assert updated.get(name) == content, "original package file changed/missing: " + name
    old, new = json.loads(original["package.json"]), json.loads(updated["package.json"])
    assert new["version"] == "13.0.3-electron-oh.0"
    new["version"] = old["version"]
    new["files"].remove("README.electron-oh.md")
    assert old == new, "unexpected package metadata change"
    prefix = "prebuilds/electron-oh/37.2.0/openharmony-arm64/"
    manifest = json.loads(updated[prefix + "manifest.json"])
    binary = updated[prefix + "better_sqlite3.node"]
    assert binary[:4] == b"\x7fELF"
    assert binary[18:20] == b"\xb7\x00", "expected AArch64 ELF"
    assert hashlib.sha256(binary).hexdigest() == manifest["binary"]["sha256"]
    assert hashlib.sha256(updated[prefix + "THIRD_PARTY_NOTICES.txt"]).hexdigest() == \
        manifest["noticesSha256"], "notice text checksum mismatch"
    assert manifest["nodeCompatibility"]["unchangedFiles"]["prebuilds/openharmony-arm64.node"] == \
        hashlib.sha256(original["prebuilds/openharmony-arm64.node"]).hexdigest()
    assert updated["README.electron-oh.md"]
    allowed = {"README.electron-oh.md", prefix + "manifest.json", prefix + "better_sqlite3.node",
               prefix + "THIRD_PARTY_NOTICES.txt"}
    assert set(updated) - set(original) == allowed, "unexpected new package files"
    print(json.dumps({"status": "passed", "originalFilesCompared": len(original),
                      "addedFiles": sorted(allowed), "electronBinarySha256": manifest["binary"]["sha256"]}, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: verify-package.py baseline.tgz candidate.tgz")
    verify(Path(sys.argv[1]), Path(sys.argv[2]))
