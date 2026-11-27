#!/usr/bin/env python3
"""Offline release preflight; never publishes or supplies authorization itself."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys

from release_materials import ROOT, load_materials, notices


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_release(baseline, candidate, evidence_path):
    spec = importlib.util.spec_from_file_location("verify_package", ROOT / "tests/verify-package.py")
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    with contextlib.redirect_stdout(io.StringIO()):
        verifier.verify(baseline, candidate)
    policy, _ = load_materials()
    files = verifier.read_package(candidate)
    prefix = "prebuilds/electron-oh/37.2.0/openharmony-arm64/"
    manifest = json.loads(files[prefix + "manifest.json"])
    errors = []
    if sha(baseline) != policy["nodeBaselineSha256"]:
        errors.append("Node baseline does not match the pinned published tarball")
    if files[prefix + "THIRD_PARTY_NOTICES.txt"] != notices():
        errors.append("candidate notices do not match the pinned release materials")
    if manifest.get("releaseMaterialsLockSha256") != sha(ROOT / "release-materials.lock.json"):
        errors.append("candidate was built with different release materials")
    if manifest.get("sdkInputSha256") != policy["sdkInputs"]["sha256"]:
        errors.append("candidate SDK inputs do not match the pinned notice provenance")
    runtime = json.loads((ROOT / "electron-oh.lock.json").read_text())
    for key in ("packageVersion", "upstreamVersion", "electronOhVersion", "nodeVersion", "napiVersion",
                "shimSha256", "runtimeLibrarySha256", "nodeAddonApiVersion"):
        if manifest.get(key) != runtime[key]:
            errors.append("candidate runtime/input identity mismatch: " + key)
    if manifest.get("redistributionNotices") != "approved":
        errors.append("candidate notices have not been approved for redistribution")
    authorization = policy["shimAuthorization"]
    if authorization["status"] != "approved" or not authorization.get("reviewUrl"):
        errors.append("shim redistribution authorization is pending")
    elif not authorization.get("licenseDocument") or authorization["licenseDocument"] not in {
            item["file"] for item in policy["documents"]}:
        errors.append("approved shim license text must be included in the pinned documents")
    decision = policy["signatureDecision"]
    if decision["status"] != "approved" or not decision.get("reviewUrl"):
        errors.append("maintainer approval of the signing policy is pending")
    if decision["mode"] != "hap-consumer-signing":
        errors.append("this preflight only supports the documented HAP consumer signing route")
    if manifest["binary"]["signature"] != "unsigned-for-hap-signing":
        errors.append("candidate is a local test/self-signed build, not a HAP-distribution build")
    evidence = json.loads(evidence_path.read_text()) if evidence_path else {}
    if evidence.get("candidateSha256") != sha(candidate):
        errors.append("runtime evidence is not bound to this exact tarball")
    if evidence.get("electronBinarySha256") != manifest["binary"]["sha256"]:
        errors.append("runtime evidence identifies a different Electron ELF")
    if evidence.get("baselineSha256") != sha(baseline):
        errors.append("runtime evidence identifies a different Node baseline")
    for host in policy["requiredRuntimeEvidence"]:
        run = evidence.get("runtimeResults", {}).get(host, {})
        if run.get("status") != "passed" or not run.get("reportUrl"):
            errors.append("missing reviewed runtime evidence: " + host)
    hap = evidence.get("hapSigning", {})
    if hap.get("codeSignVerified") is not True or not hap.get("reportUrl") or not hap.get("hapSha256"):
        errors.append("signed HAP identity and code-sign verification report are required")
    if not evidence.get("maintainerReviewUrl"):
        errors.append("maintainer review of release evidence is required")
    return {"status": "blocked" if errors else "ready-for-maintainer-publication",
            "candidateSha256": sha(candidate), "errors": errors,
            "note": "Report URLs require human review; this tool does not authenticate approvals or publish."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", nargs="?", type=Path)
    parser.add_argument("candidate", nargs="?", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--check-materials", action="store_true",
                        help="check source document hashes only; not a release approval")
    args = parser.parse_args()
    try:
        if args.check_materials:
            if args.baseline or args.candidate or args.evidence:
                parser.error("--check-materials cannot be combined with package/evidence arguments")
            policy, texts = load_materials()
            result = {"status": "materials-integrity-passed", "documents": len(texts),
                      "shimAuthorization": policy["shimAuthorization"]["status"],
                      "signatureDecision": policy["signatureDecision"]["status"],
                      "releaseReadiness": "not-checked"}
        else:
            if not args.baseline or not args.candidate:
                parser.error("provide baseline.tgz candidate.tgz [--evidence report.json]")
            result = verify_release(args.baseline, args.candidate, args.evidence)
        print(json.dumps(result, indent=2))
        return 1 if result["status"] == "blocked" else 0
    except (ValueError, OSError, KeyError, AssertionError) as error:
        print(json.dumps({"status": "blocked", "errors": [str(error)]}, indent=2))
        return 1


if __name__ == "__main__":
    sys.exit(main())
