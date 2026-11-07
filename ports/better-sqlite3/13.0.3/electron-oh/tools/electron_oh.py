#!/usr/bin/env python3
"""Build an opt-in Electron-OH package without mutating the prepared Node port."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request

from release_materials import load_materials, notices

ELECTRON = Path(__file__).resolve().parents[1]
PORT = ELECTRON.parent
REL = Path("prebuilds/electron-oh/37.2.0/openharmony-arm64")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(*args, cwd=None):
    subprocess.run([str(a) for a in args], cwd=cwd, check=True)


def capture(*args):
    return subprocess.check_output([str(a) for a in args], text=True)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def snapshot(root):
    # These files must remain byte-identical, including every supported loader.
    paths = [root / "prebuilds/openharmony-arm64.node", root / "binding.gyp"]
    paths += sorted(p for p in (root / "lib").rglob("*.js") if not p.name.startswith("._"))
    return {str(p.relative_to(root)): sha(p) for p in paths}


def build(args):
    lock = json.loads((ELECTRON / "electron-oh.lock.json").read_text())
    release_materials, _ = load_materials()
    notice_bytes = notices()
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    require(not output.exists(), "output already exists; choose a new output directory")
    require(source not in output.parents and output not in source.parents,
            "source and output must be separate directories")
    meta = json.loads((source / "package.json").read_text())
    require(meta["name"] == "@ohos-ports/better-sqlite3" and
            meta["version"] == lock["upstreamVersion"], "prepare the existing 13.0.3 Node port first")
    require(not (source / REL).exists(), "source already contains Electron-OH assets")
    require(sha(source / "src/better_sqlite3.cpp") == lock["sourceSha256"], "unexpected addon source")
    before = snapshot(source)
    addon = source / "node_modules/node-addon-api"
    require(json.loads((addon / "package.json").read_text())["version"] == lock["nodeAddonApiVersion"],
            "install node-addon-api@" + lock["nodeAddonApiVersion"] + " with --ignore-scripts --no-save")
    shim = args.shim.resolve(strict=True) / "lib/libshim.a"
    require(sha(shim) == lock["shimSha256"], "shim checksum does not match the pinned runtime profile")
    require(sha(args.runtime_library) == lock["runtimeLibrarySha256"], "libelectron.so checksum mismatch")
    ndk = args.ndk.resolve(strict=True)
    tools = ndk / "llvm/bin"
    cc, cxx = tools / "clang", tools / "clang++"
    readelf, nm = tools / "llvm-readelf", tools / "llvm-nm"
    sdk_meta = json.loads((ndk / "oh-uni-package.json").read_text())
    sdk_inputs = release_materials["sdkInputs"]
    require(sdk_meta["version"] == sdk_inputs["version"] and
            sdk_meta["apiVersion"] == sdk_inputs["apiVersion"], "SDK does not match the pinned notices")
    for name, digest in sdk_inputs["sha256"].items():
        require(sha(ndk / name) == digest, "SDK input/notice checksum mismatch: " + name)
    require(args.sign_tool is not None or args.allow_unsigned or args.for_hap_distribution,
            "select local unsigned/self-sign testing, or an approved HAP-distribution build")
    if args.for_hap_distribution:
        authorization = release_materials["shimAuthorization"]
        decision = release_materials["signatureDecision"]
        require(authorization["status"] == "approved" and authorization.get("reviewUrl") and
                authorization.get("licenseDocument") in
                {item["file"] for item in release_materials["documents"]},
                "HAP-distribution build requires reviewed shim authorization and pinned license text")
        require(decision["status"] == "approved" and decision.get("reviewUrl") and
                decision["mode"] == "hap-consumer-signing",
                "HAP-distribution build requires maintainer approval of the signing policy")
    compiler = capture(cc, "--version").splitlines()[0]
    headers_lock = json.loads((ELECTRON / "node-api-headers.lock.json").read_text())
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="better-sqlite3-electron-oh-") as temp:
        work = Path(temp)
        headers = work / "headers"
        headers.mkdir()
        for name, digest in headers_lock.items():
            url = "https://raw.githubusercontent.com/nodejs/node/v22.17.0/src/" + name
            with urllib.request.urlopen(url, timeout=60) as response:
                (headers / name).write_bytes(response.read())
            require(sha(headers / name) == digest, "Node-API header checksum mismatch: " + name)
        # Use the generated upstream defines, never a second hand-maintained list.
        defines = ast.literal_eval((source / "deps/defines.gypi").read_text())["defines"]
        common = ["--target=aarch64-linux-ohos", "--sysroot=" + str(ndk / "sysroot"), "-O3", "-fPIC",
                  "-ffile-prefix-map=" + str(source) + "=/usr/src/better-sqlite3",
                  "-ffile-prefix-map=" + str(work) + "=/usr/src/better-sqlite3-build"]
        sqlite = source / "deps/sqlite3"
        run(cc, *common, "-std=c99", "-w", "-DNDEBUG", *["-D" + d for d in defines],
            "-I" + str(sqlite), "-c", sqlite / "sqlite3.c", "-o", work / "sqlite3.o")
        run(cxx, *common, "-std=c++20", "-fvisibility=hidden", "-fvisibility-inlines-hidden",
            "-DNAPI_VERSION=10", "-DNAPI_DISABLE_CPP_EXCEPTIONS",
            "-DNODE_API_SWALLOW_UNTHROWABLE_EXCEPTIONS", "-I" + str(addon),
            "-I" + str(headers), "-I" + str(sqlite), "-c", source / "src/better_sqlite3.cpp",
            "-o", work / "addon.o")
        binary = work / "better_sqlite3.node"
        run(cxx, *common[:2], "-shared", work / "addon.o", work / "sqlite3.o", shim,
            "-Wl,-z,max-page-size=0x1000", "-Wl,-Bsymbolic", "-Wl,--exclude-libs,ALL",
            "-Wl,--no-undefined", "-static-libstdc++", "-lc", "-lpthread", "-ldl", "-o", binary)
        run(tools / "llvm-strip", "--strip-unneeded", binary)
        signed = False
        if args.sign_tool:
            signed_file = work / "signed.node"
            run(args.sign_tool, "sign", "-selfSign", "1", "-inFile", binary, "-outFile", signed_file)
            shutil.move(signed_file, binary)
            signed = True
        require("AArch64" in capture(readelf, "-h", binary), "wrong ELF architecture")
        dynamic = capture(readelf, "-d", binary)
        needed = re.findall(r"Shared library: \[(.*?)\]", dynamic)
        require(needed == ["libc.so"], "unexpected dynamic dependencies: " + str(needed))
        require("napi_register_module_v1" in capture(nm, "-D", "--defined-only", binary),
                "missing Node-API registration export")
        require(not re.search(r"\b(?:napi_|node_api_|uv_)\w+", capture(nm, "-D", "--undefined-only", binary)),
                "unresolved Node-API/libuv symbols")
        require(not signed or ".codesign" in capture(readelf, "-S", binary), "signer produced no .codesign section")
        require(snapshot(source) == before, "Node source or prebuild changed during compilation")
        # Stage beside output, then rename only after every invariant has passed.
        staging = Path(tempfile.mkdtemp(prefix=".electron-oh-stage-", dir=output.parent))
        try:
            shutil.copytree(source, staging, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns("node_modules", "build", ".git", "._*"))
            run("patch", "--batch", "-p1", "-i", PORT / "patchs/0003-electron-oh-package.patch", cwd=staging)
            shutil.copy2(ELECTRON / "README.md", staging / "README.electron-oh.md")
            dest = staging / REL
            dest.mkdir(parents=True)
            shutil.copy2(binary, dest / binary.name)
            manifest = {
                "schemaVersion": 1, "packageVersion": lock["packageVersion"],
                "upstreamVersion": lock["upstreamVersion"], "electronOhVersion": lock["electronOhVersion"],
                "nodeVersion": lock["nodeVersion"], "napiVersion": lock["napiVersion"],
                "platform": "openharmony", "arch": "arm64", "maxPageSize": 4096,
                "runtimeLibrarySha256": lock["runtimeLibrarySha256"], "shimSha256": sha(shim),
                "nodeAddonApiVersion": lock["nodeAddonApiVersion"], "nodeApiHeaderSha256": headers_lock,
                "sdk": sdk_meta, "compiler": compiler, "sqliteDefines": defines,
                "sourcePathRemapping": {"source": "/usr/src/better-sqlite3", "temporary": "/usr/src/better-sqlite3-build"},
                "sqliteSourceSha256": sha(sqlite / "sqlite3.c"), "addonSourceSha256": lock["sourceSha256"],
                "binary": {"file": binary.name, "sha256": sha(binary), "needed": needed,
                           "signature": "self-signed-local-only" if signed else
                           "unsigned-for-hap-signing" if args.for_hap_distribution else "unsigned-local-only"},
                "redistributionNotices": release_materials["shimAuthorization"]["status"],
                "noticesSha256": hashlib.sha256(notice_bytes).hexdigest(),
                "releaseMaterialsLockSha256": sha(ELECTRON / "release-materials.lock.json"),
                "sdkInputSha256": sdk_inputs["sha256"],
                "nodeCompatibility": {"unchangedFiles": before},
                "validation": {"elf": "passed", "nodeRuntime": "not-run", "electronOhHap": "not-run"},
            }
            (dest / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            (dest / "THIRD_PARTY_NOTICES.txt").write_bytes(notice_bytes)
            require(snapshot(staging) == before, "packaging modified Node loaders or prebuild")
            staging.rename(output)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    print("Prepared " + str(output))
    print("Node files unchanged; runtime tests remain required. Nothing was published.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="prepared @ohos-ports/better-sqlite3@13.0.3")
    parser.add_argument("--output", type=Path, required=True, help="new, separate package directory")
    parser.add_argument("--ndk", type=Path, required=True, help="OHOS native SDK root (llvm/, sysroot/)")
    parser.add_argument("--shim", type=Path, required=True, help="electron-napi-library root")
    parser.add_argument("--runtime-library", type=Path, required=True, help="matching Electron-OH libelectron.so")
    signing = parser.add_mutually_exclusive_group(required=True)
    signing.add_argument("--sign-tool", type=Path, help="binary-sign-tool for local self-sign testing only")
    signing.add_argument("--allow-unsigned", action="store_true", help="local HAP tests only; never publish")
    signing.add_argument("--for-hap-distribution", action="store_true",
                         help="unsigned ELF for app-side HAP signing; requires approved release materials")
    args = parser.parse_args()
    try:
        build(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()
