#!/bin/sh
set -e

# Repack official vite-plus with an OpenHarmony binding embedded. The upstream
# loader (binding/index.cjs) already has an openharmony/arm64 branch that tries
# ./vite-plus.openharmony-arm64.node first, so the repacked package works with
# no loader patch and no postinstall wiring.
#
# Two trees:
#   vite-plus-src/   — source tarball, only for compiling the binding
#   vite-plus-<ver>/ — official npm tgz, becomes the published package

VERSION=0.2.8
PKG=vite-plus
VITE_TASK_REV="5c1d02c750ac21c6f4cf0528062590a145e87fd1"

# setup-tools.sh only installs node/python/devel-base.
brew install -y rust git cmake
npm install -g pnpm@10

# ── 1. Source tree: build the OHOS napi binding ──────────────────────

curl -fsSL "https://github.com/voidzero-dev/${PKG}/archive/refs/tags/v${VERSION}.tar.gz" \
  -o src.tar.gz
tar -zxf src.tar.gz
rm src.tar.gz
mv "${PKG}-${VERSION}" "${PKG}-src"

cd "${PKG}-src"

patch -p1 < ../patchs/0002-remove-package-manager-pin.patch
patch -p1 < ../patchs/0003-enable-local-vite-task-patch-section.patch

export NPM_CONFIG_MANAGE_PACKAGE_MANAGER_VERSIONS=false
export npm_config_manage_package_manager_versions=false

# Unlocks `-Z bindeps` on stable rust (fspy preload artifact deps).
export RUSTC_BOOTSTRAP=1

# @napi-rs/cli builds the ohos linker/cc/ar paths from this; must be set
# before pnpm build compiles the rolldown binding. devel-base pulls in
# harmonybrew's ohos-sdk bottle; resolve via brew (the prefix is not
# necessarily under $HOME in CI containers).
if [ -z "$OHOS_SDK_NATIVE" ]; then
  SDK_DIR="$(brew --prefix)/opt/ohos-sdk"
  if [ -d "$SDK_DIR/native" ]; then
    export OHOS_SDK_NATIVE="$SDK_DIR/native"
  fi
fi

if ! curl -fsIL --max-time 8 -o /dev/null "https://index.crates.io/config.json" 2>/dev/null; then
  export CARGO_REGISTRIES_CRATES_IO_INDEX="sparse+https://rsproxy.cn/index/"
fi

VITE_TASK_DIR="../vite-task"
if [ ! -d "$VITE_TASK_DIR/.git" ]; then
  git clone https://github.com/voidzero-dev/vite-task.git "$VITE_TASK_DIR"
  cd "$VITE_TASK_DIR"
  git fetch --depth 1 origin "$VITE_TASK_REV"
  git checkout "$VITE_TASK_REV"
  cd -
fi

cd "$VITE_TASK_DIR"
patch -p1 < ../patchs/0004-fspy-ohos-exemption.patch
cd -

# Fetch the pinned external repos (rolldown, vite) that pnpm-workspace
# references but the source tarball does not contain.
node packages/tools/src/index.ts sync-remote

pnpm install

# Upstream publishes no openharmony napi bindings; reuse linux-arm64-musl
# builds (same libc/ABI family, cf. opentui-core) for every store package
# declaring a *-linux-arm64-musl optional dependency (yuku-*, @ast-grep/napi,
# ...). Fabricated modules land next to each package (module-resolution path)
# and inside it (__dirname-relative fallbacks), then get signed — OHOS
# refuses to dlopen unsigned ELF shared objects and the musl builds ship
# unsigned.
SIGN_TOOL="$(brew --prefix)/bin/binary-sign-tool"
node -e '
const { readFileSync, readdirSync, mkdirSync, copyFileSync, writeFileSync, existsSync } = require("fs");
const { join } = require("path");
const signTool = process.argv[1], signArgs = ["sign", "-selfSign", "1"];
const { execFileSync } = require("child_process");
for (const scopeDir of readdirSync("node_modules/.pnpm")) {
  const nm = join("node_modules/.pnpm", scopeDir, "node_modules");
  let entries;
  try { entries = readdirSync(nm); } catch { continue; }
  // @scope packages nest one level under the scope directory.
  const pkgs = [];
  for (const entry of entries) {
    if (entry.startsWith("@")) {
      for (const inner of readdirSync(join(nm, entry))) {
        pkgs.push(join(entry, inner));
      }
    } else {
      pkgs.push(entry);
    }
  }
  for (const pkgPath of pkgs) {
    const pkgDir = join(nm, pkgPath);
    let manifest;
    try { manifest = JSON.parse(readFileSync(join(pkgDir, "package.json"), "utf8")); }
    catch { continue; }
    if (!manifest || typeof manifest.name !== "string") continue;
    const deps = manifest.optionalDependencies ?? {};
    const muslDep = Object.keys(deps).find((d) => d.endsWith("-linux-arm64-musl"));
    if (!muslDep) continue;

    const [scope, muslBase] = muslDep.startsWith("@")
      ? [muslDep.split("/")[0], muslDep.split("/")[1]]
      : [null, muslDep];
    const ohosBase = muslBase.replace("-linux-arm64-musl", "-openharmony-arm64");
    const ohosModule = scope ? `${scope}/${ohosBase}` : ohosBase;
    const version = manifest.version;

    // Fetch the musl tarball (cached in the parent dir across retries).
    const tgz = `../musl-napi-${muslDep.replace("/", "-")}-${version}.tgz`;
    if (!existsSync(tgz)) {
      execFileSync("curl", ["-fSL", "--retry", "5", "-o", tgz,
        `https://registry.npmmirror.com/${muslDep}/-/${muslBase}-${version}.tgz`],
        { stdio: "inherit" });
    }
    execFileSync("tar", ["xzf", tgz]);
    const stage = "package";
    let nodeSrc;
    const walk = (dir) => {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, e.name);
        if (e.isDirectory()) { nodeSrc = walk(p) || nodeSrc; }
        else if (e.name.endsWith(".node") && !nodeSrc) nodeSrc = p;
      }
      return nodeSrc;
    };
    nodeSrc = walk(stage);
    if (!nodeSrc) throw new Error(`no .node found in ${tgz}`);
    const nodeBase = nodeSrc.split("/").pop();
    // Loader conventions differ: yuku wants a bare "<pkg>.node",
    // ast-grep wants "<bin>.openharmony-arm64.node".
    const nodeOhosName = nodeBase.replace("-linux-arm64-musl", "-openharmony-arm64");
    const pkgLeaf = manifest.name.split("/").pop();

    // 1) Fabricated module next to the package (module resolution).
    const dest = join(nm, ohosModule);
    const files = [];
    if (!existsSync(dest)) {
      mkdirSync(dest, { recursive: true });
      copyFileSync(nodeSrc, join(dest, nodeBase));
      files.push(join(dest, nodeBase));
      writeFileSync(join(dest, "package.json"), JSON.stringify({
        name: ohosModule, version, main: nodeBase,
      }));
      if (scope) {
        copyFileSync(nodeSrc, join(dest, `${pkgLeaf}.node`));
        files.push(join(dest, `${pkgLeaf}.node`));
      }
    }

    // 2) Files inside the package itself (__dirname-relative fallbacks).
    copyFileSync(nodeSrc, join(pkgDir, nodeOhosName));
    files.push(join(pkgDir, nodeOhosName));
    copyFileSync(nodeSrc, join(pkgDir, `${pkgLeaf}.node`));
    files.push(join(pkgDir, `${pkgLeaf}.node`));
    if (scope) {
      const inner = join(pkgDir, scope, ohosBase);
      if (!existsSync(inner)) {
        mkdirSync(inner, { recursive: true });
        copyFileSync(nodeSrc, join(inner, `${pkgLeaf}.node`));
        files.push(join(inner, `${pkgLeaf}.node`));
      }
    }

    for (const f of files) {
      execFileSync(signTool, [...signArgs, "-inFile", f, "-outFile", f], { stdio: "inherit" });
    }
    execFileSync("rm", ["-rf", stage]);
    console.log(`injected ${muslDep} -> ${ohosModule} (${manifest.name})`);
  }
}
' "$SIGN_TOOL"

pnpm build

cargo build -p vite-plus-cli --release

NODE_FILE=$(find target/release -maxdepth 1 -name '*.so' -o -name '*.dylib' | head -1)
if [ -z "$NODE_FILE" ]; then
  echo "ERROR: no .so found in target/release/" >&2
  ls -la target/release/ >&2
  exit 1
fi

cp "$NODE_FILE" ../binding.openharmony-arm64.node
chmod +x ../binding.openharmony-arm64.node

readelf -h ../binding.openharmony-arm64.node | grep -q 'AArch64'

cd ..

# ── 2. Official tgz: repack with the binding embedded ────────────────

npm pack "${PKG}@${VERSION}" --pack-destination .
tar -zxf "${PKG}-${VERSION}.tgz"
rm "${PKG}-${VERSION}.tgz"
mv package "${PKG}-${VERSION}"

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch

binary-sign-tool sign -selfSign 1 \
  -inFile ../binding.openharmony-arm64.node \
  -outFile binding/vite-plus.openharmony-arm64.node
chmod +x binding/vite-plus.openharmony-arm64.node

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/vite-plus" ]

grep -q "process.platform === 'openharmony'" binding/index.cjs
test -f binding/vite-plus.openharmony-arm64.node

readelf -h binding/vite-plus.openharmony-arm64.node | grep -q 'AArch64'
readelf -S binding/vite-plus.openharmony-arm64.node | grep -q '\.codesign'
echo "OK: @ohos-ports/vite-plus repacked with openharmony-arm64 binding"
