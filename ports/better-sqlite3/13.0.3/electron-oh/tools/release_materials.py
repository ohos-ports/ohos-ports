"""Read pinned notice texts. Integrity checks do not constitute license approval."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_materials():
    policy = json.loads((ROOT / "release-materials.lock.json").read_text())
    runtime = json.loads((ROOT / "electron-oh.lock.json").read_text())
    if policy["schemaVersion"] != 1 or policy["packageVersion"] != runtime["packageVersion"]:
        raise ValueError("release materials do not match the runtime lock")
    if policy["shimAuthorization"]["shimSha256"] != runtime["shimSha256"]:
        raise ValueError("shim authorization identifies a different binary")
    if policy["shimAuthorization"]["runtimeArchiveSha256"] != runtime["runtimeSource"]["archiveSha256"]:
        raise ValueError("shim authorization identifies a different runtime archive")
    texts = []
    seen = set()
    for item in policy["documents"]:
        name = item["file"]
        path = (ROOT / name).resolve()
        if path.parent != (ROOT / "licenses").resolve() or name in seen:
            raise ValueError("invalid or duplicate license document path")
        seen.add(name)
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise ValueError("license document checksum mismatch: " + name)
        texts.append((name, data.decode("utf-8")))
    if not texts:
        raise ValueError("no license documents")
    return policy, texts


def notices():
    policy, texts = load_materials()
    summary = (
        "Electron-OH additional third-party notices\n"
        "Retain the baseline better-sqlite3 LICENSE and SQLite source dedication.\n"
        "The following texts are retained verbatim from the pinned sources.\n"
        "Shim authorization status: " + policy["shimAuthorization"]["status"] + "\n"
        "The shim is statically linked; do not infer its license from Electron's name.\n"
        "Release readiness must be checked separately with tools/check-release.py.\n"
    )
    return (summary + "".join("\n===== " + name + " =====\n" + text + "\n"
                              for name, text in texts)).encode("utf-8")
