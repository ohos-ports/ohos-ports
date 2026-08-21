#!/bin/sh
set -e

# nx OpenHarmony port. Both halves are built from source: the native binding
# with `cargo build --release` (this container's rustc host triple is already
# aarch64-unknown-linux-ohos), and the CLI JavaScript with plain `tsc` against
# the package's own tsconfig.lib.json.
#
# Upstream's own `nx build nx` is not reproducible here: it pulls the whole
# pnpm monorepo toolchain (~294 root devDependencies, a webpack build of the
# graph-client web app, a rustup-nightly WASI build, and tsgo, which has no
# openharmony build). Two file groups are therefore carried over from the
# upstream npm tarball; the parity check below proves everything else in
# dist/ is our own tsc output or copied from the git checkout.

VERSION=23.1.1
PKG=nx
VT100_REV=b15dc3b0f7db94167a9c584f1d403899c0cc871d
WEZTERM_REV=b538ee29e1e89eeb4832fb35ae095564dce34c29

# setup-tools.sh only installs node/python/devel-base; rust and git are
# needed below but not preinstalled.
brew install -y rust
command -v git >/dev/null 2>&1 || brew install -y git

# Sparse, blob-filtered clone: the full monorepo checkout is huge. Cone mode
# always includes root files, so Cargo.toml/Cargo.lock/tsconfig.base.json
# come along with packages/nx.
git clone --depth 1 --filter=blob:none --sparse --branch "${VERSION}" https://github.com/nrwl/nx src
cd src
git sparse-checkout set packages/nx
cd ..

# Vendor the two cargo git dependencies as tarballs so cargo never has to
# speak the git protocol; 0001 re-points them via [patch] sections.
mkdir -p gitdeps/wezterm

curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://codeload.github.com/JamesHenry/vt100-rust/tar.gz/${VT100_REV}" -o vt100.tar.gz
tar -zxf vt100.tar.gz
mv "vt100-rust-${VT100_REV}" gitdeps/vt100-rust
rm vt100.tar.gz

# Only the pty/ and filedescriptor/ crates of the wezterm monorepo are used.
curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://codeload.github.com/cammisuli/wezterm/tar.gz/${WEZTERM_REV}" -o wezterm.tar.gz
tar -zxf wezterm.tar.gz "wezterm-${WEZTERM_REV}/pty" "wezterm-${WEZTERM_REV}/filedescriptor"
mv "wezterm-${WEZTERM_REV}/pty" "wezterm-${WEZTERM_REV}/filedescriptor" gitdeps/wezterm/
rm -rf "wezterm-${WEZTERM_REV}" wezterm.tar.gz

# 0002: bump portable-pty's nix 0.25 -> 0.30 (nix >= 0.30 has target_env =
# "ohos" gates; 0.25 predates them and its default features don't compile
# there) + one tcgetattr call-site fix for the nix 0.26+ AsFd API.
cd gitdeps/wezterm
patch -p1 < ../../patchs/0002-portable-pty-nix-bump.patch
cd ../..

# --- apply source patches ---

cd src
# 0001: exclude jemalloc on target_env = "ohos" (tikv-jemalloc-sys fails to
# build there) + the [patch] sections for ../gitdeps, with Cargo.lock updates.
patch -p1 < ../patchs/0001-nx-source-ohos.patch
# 0003: whitelist openharmony; the `as string` cast is needed because
# @types/node's Platform union has no 'openharmony' member (TS2367).
patch -p1 < ../patchs/0003-assert-supported-platform.patch
# 0004: @ts-expect-error -> @ts-ignore — upstream compiles with tsgo, under
# which the directive is used; plain tsc rejects it as unused (TS2578).
# @ts-ignore is unused-safe under both and doesn't change the emitted JS.
patch -p1 < ../patchs/0004-tsc-expect-error-compat.patch
cd ..

# --- build the native binding ---

cd src
cargo build --release

test -f target/release/libnx.so
cp target/release/libnx.so nx.openharmony-arm64.node
llvm-strip --strip-all nx.openharmony-arm64.node
binary-sign-tool sign -selfSign 1 -inFile nx.openharmony-arm64.node -outFile nx.openharmony-arm64.node.signed
mv nx.openharmony-arm64.node.signed nx.openharmony-arm64.node
chmod +x nx.openharmony-arm64.node
cd ..

# --- fetch the upstream npm tarball (metadata + carry-over assets + deps) ---

curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "https://registry.npmjs.org/${PKG}/-/${PKG}-${VERSION}.tgz" -o nx.tgz
tar -zxf nx.tgz
mv package "${PKG}-${VERSION}"
# Pristine file list of the published dist, for the parity check below.
cd "${PKG}-${VERSION}"
find dist -type f | sort > ../published-dist.list
cd ..

# --- compile the CLI JavaScript from source ---

mkdir _jsbuild
cp src/tsconfig.base.json _jsbuild/
mkdir -p _jsbuild/packages
cp -r src/packages/nx _jsbuild/packages/
rm -rf _jsbuild/packages/nx/dist

cd _jsbuild
# nx's runtime deps (installed via the upstream tarball) provide most of the
# types tsc needs; the middle block adds the optional peer/type-only imports
# (@angular-devkit/*, rxjs, prettier, ts-node, @pnpm/lockfile-types, @nx/key,
# @nx/powerpack-license, @swc-node/register) and the compiler, pinned to the
# versions upstream's pnpm-lock.yaml uses.
#
# The last block is ALSO nx runtime deps, pinned explicitly because
# @angular-devkit/schematics depends on newer majors of them — without a
# top-level pin npm may hoist the newer major and tsc resolves the wrong
# types (e.g. ora 9's types are not callable, breaking the compile).
npm install --ignore-scripts \
  ../nx.tgz \
  typescript@6.0.3 \
  @types/node@24.13.3 \
  @angular-devkit/core@22.1.4 \
  @angular-devkit/architect@0.2201.4 \
  @angular-devkit/schematics@22.1.4 \
  rxjs@7.8.2 \
  prettier@3.6.2 \
  ts-node@10.9.1 \
  @pnpm/lockfile-types@6.0.0 \
  @nx/key@5.0.4 \
  @nx/powerpack-license@5.0.4 \
  @swc-node/register@1.11.1 \
  @swc/core@1.15.10 \
  ora@5.4.1 \
  chalk@4.1.2 \
  cli-cursor@3.1.0 \
  cli-spinners@2.6.1 \
  log-symbols@4.1.0 \
  string-width@4.2.3 \
  strip-ansi@6.0.1 \
  ansi-regex@5.0.1 \
  is-interactive@1.0.0 \
  is-unicode-supported@0.1.0 \
  onetime@5.1.2 \
  restore-cursor@3.1.0 \
  signal-exit@3.0.7

./node_modules/.bin/tsc -p packages/nx/tsconfig.lib.json
cd ..

# --- assemble the distribution package ---

cd "${PKG}-${VERSION}"

# Save the two carry-over groups, then replace the whole dist with our own.
mkdir -p ../carry
cp -r dist/src/core/graph ../carry/graph
cp dist/src/native/*.wasm ../carry/
rm -rf dist
cp -r ../_jsbuild/packages/nx/dist dist
rm -f dist/tsconfig.tsbuildinfo

# tsc doesn't set exec bits; upstream ships the bin entry points executable
# (its build runs scripts/chmod.js for this).
chmod 755 dist/bin/nx.js dist/bin/nx-cloud.js

# Asset copies, mirroring packages/nx/assets.json (all committed in the repo).
JSRC=../_jsbuild/packages/nx
PKGDIR=$PWD
mkdir -p dist/presets
cp "$JSRC"/presets/*.json dist/presets/
cd "$JSRC"
# shellcheck disable=SC2046
tar -cf - $(find src/migrations -name '*.md') | (cd "$PKGDIR/dist" && tar -xf -)
cd "$PKGDIR"
cp "$JSRC"/src/command-line/migrate/run-migration-process.js dist/src/command-line/migrate/
cp "$JSRC"/src/ai/set-up-ai-agents/schema.d.ts dist/src/ai/set-up-ai-agents/
cp "$JSRC"/src/utils/perf-hooks.d.ts dist/src/utils/
cp "$JSRC"/src/utils/yarn-syml/syml-grammar.js dist/src/utils/yarn-syml/
mkdir -p dist/src/command-line/completion
cp -r "$JSRC"/src/command-line/completion/scripts dist/src/command-line/completion/
cp "$JSRC"/src/native/browser.js "$JSRC"/src/native/index.js "$JSRC"/src/native/index.d.ts \
   "$JSRC"/src/native/native-bindings.js "$JSRC"/src/native/nx.wasi-browser.js \
   "$JSRC"/src/native/nx.wasi.cjs "$JSRC"/src/native/wasi-worker-browser.mjs \
   "$JSRC"/src/native/wasi-worker.mjs dist/src/native/

# Restore the carry-overs and add the signed binding (native-bindings.js'
# openharmony branch loads ./nx.openharmony-arm64.node next to itself first).
mkdir -p dist/src/core
cp -r ../carry/graph dist/src/core/graph
cp ../carry/*.wasm dist/src/native/
cp ../src/nx.openharmony-arm64.node dist/src/native/

# 0005: rename to @ohos-ports/nx, version 23.1.1-1, repository pointer.
patch -p1 < ../patchs/0005-update-package-json.patch
cd ..

# --- verify package contents ---

NAME=$(node -e "console.log(require('./${PKG}-${VERSION}/package.json').name)")
[ "$NAME" = "@ohos-ports/nx" ]

node --check "${PKG}-${VERSION}/dist/src/native/assert-supported-platform.js"
grep -q openharmony "${PKG}-${VERSION}/dist/src/native/assert-supported-platform.js"

# CLI entry points must be executable in the tarball (upstream ships them so).
[ -x "${PKG}-${VERSION}/dist/bin/nx.js" ]
[ -x "${PKG}-${VERSION}/dist/bin/nx-cloud.js" ]

readelf -h "${PKG}-${VERSION}/dist/src/native/nx.openharmony-arm64.node" | grep -q 'AArch64'
readelf -S "${PKG}-${VERSION}/dist/src/native/nx.openharmony-arm64.node" | grep -q '\.codesign'

# Parity check: our dist must equal the published file set plus our one added
# .node — nothing missing, nothing extra.
cd "${PKG}-${VERSION}"
find dist -type f | sort > ../our-dist.list
cd ..
grep -v '^dist/src/native/nx.openharmony-arm64.node$' our-dist.list > our-dist-minus-node.list
if ! diff -u published-dist.list our-dist-minus-node.list; then
  echo "dist parity check FAILED: compiled dist does not match published file set" >&2
  exit 1
fi

# The .node must survive npm packing (package.json "files" whitelist).
PKG_TGZ=$(npm pack --ignore-scripts "./${PKG}-${VERSION}" | tail -1)
tar -tzf "$PKG_TGZ" | grep -q 'dist/src/native/nx.openharmony-arm64.node'

# The loader must resolve the bundled binding (real dlopen, not just ELF
# checks): this container IS the target platform.
node -e '
  const b = require("./'"${PKG}-${VERSION}"'/dist/src/native/native-bindings.js");
  if (b.IS_WASM !== false) throw new Error("expected native binding, got WASI fallback");
  const n = Object.keys(b).length;
  console.log(`native binding loaded, IS_WASM=false, ${n} exports`);
  if (n < 50) throw new Error(`suspiciously few exports: ${n}`);
'

# --- functional smoke test: real `nx run` in a scratch workspace ---

SMOKE=$PWD/smoke
mkdir -p "$SMOKE/packages/pkg-a"
cd "$SMOKE"

# Install under the literal name "nx", mirroring how consumers use the fork
# ("overrides": {"nx": "npm:@ohos-ports/nx@..."}). Load-bearing: upstream
# code self-requires 'nx/package.json', so it only works at node_modules/nx.
cat > package.json <<EOF
{
  "name": "nx-ohos-smoke",
  "private": true,
  "workspaces": [
    "packages/*"
  ],
  "dependencies": {
    "nx": "file:../$PKG_TGZ"
  }
}
EOF
cat > nx.json <<'EOF'
{}
EOF
cat > packages/pkg-a/package.json <<'EOF'
{
  "name": "pkg-a",
  "version": "1.0.0",
  "scripts": {
    "build": "echo PKG_A_BUILT"
  }
}
EOF

npm install --ignore-scripts

# Own repo boundary: nx's ignore walker consults the nearest enclosing git
# repo, whose rules can hide the workspace from the project graph.
git init -q .

# OHOS devices have a read-only /tmp and a short sun_path limit; the daemon
# socket dir must be a writable short path. Harmless elsewhere.
export NX_SOCKET_DIR="$SMOKE/.nx-sock"
mkdir -p "$NX_SOCKET_DIR"

RUN_OUT=$(./node_modules/.bin/nx run pkg-a:build 2>&1)
echo "$RUN_OUT"
echo "$RUN_OUT" | grep -q PKG_A_BUILT

SHOW_OUT=$(./node_modules/.bin/nx show projects 2>&1)
echo "$SHOW_OUT"
echo "$SHOW_OUT" | grep -q pkg-a

# Exercise the carried-over graph assets path too (JSON export mode).
./node_modules/.bin/nx graph --file="$SMOKE/graph.json"
test -s "$SMOKE/graph.json"

./node_modules/.bin/nx reset

echo "nx ${VERSION} OpenHarmony port: build + smoke test OK"
