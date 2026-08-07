#!/bin/sh
set -e

# Native cargo build: this container's rustc host triple is already
# aarch64-unknown-linux-ohos, so `cargo build --release` produces an OHOS
# binding directly with no cross-compile target/toolchain wrapper, and the
# output is already codesigned by the container's LLVM at link time.

VERSION=0.4.10
PORTABLE_PTY_VERSION=0.9.0
PKG=bun-pty

curl -fsSL "https://github.com/sursaone/bun-pty/archive/refs/tags/v${VERSION}.tar.gz" -o bun-pty.tar.gz
tar -zxf bun-pty.tar.gz
rm bun-pty.tar.gz
# GitHub source archives already extract to <repo>-<version>/, which happens
# to equal ${PKG}-${VERSION} here, so no rename is needed.

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-package-json.patch
patch -p1 < ../patchs/0002-openharmony-loader.patch

brew install -y rust

# portable-pty 0.9.0 on crates.io pins nix "0.28", which predates OHOS
# support (nix 0.30+ added *-unknown-linux-ohos handling). We can't bump a
# transitive dep's *version* via [patch.crates-io] (same-registry patches
# aren't allowed), so vendor a local copy with just its nix requirement
# bumped and point rust-pty/Cargo.toml at that path (already done by
# 0002-openharmony-loader.patch).
mkdir -p rust-pty/vendor
FETCH_SCRATCH="$(pwd)/.fetch-portable-pty"
mkdir -p "${FETCH_SCRATCH}/src"
cat > "${FETCH_SCRATCH}/Cargo.toml" << 'CARGOEOF'
[package]
name = "fetch-scratch"
version = "0.1.0"
edition = "2021"

[dependencies]
portable-pty = "=0.9.0"
CARGOEOF
echo 'fn main() {}' > "${FETCH_SCRATCH}/src/main.rs"
(cd "${FETCH_SCRATCH}" && cargo fetch)
VENDOR_SRC=$(ls -d "$HOME"/.cargo/registry/src/*/portable-pty-${PORTABLE_PTY_VERSION} | head -1)
cp -r "$VENDOR_SRC" "rust-pty/vendor/portable-pty-${PORTABLE_PTY_VERSION}"
chmod -R u+w "rust-pty/vendor/portable-pty-${PORTABLE_PTY_VERSION}"
rm -rf "${FETCH_SCRATCH}"
cd "rust-pty/vendor/portable-pty-${PORTABLE_PTY_VERSION}"
patch -p1 < ../../../../patchs/0003-vendor-portable-pty-nix-bump.patch
cd ../../..

cd rust-pty
cargo build --release
cd ..

test -f rust-pty/target/release/librust_pty.so
llvm-strip --strip-all rust-pty/target/release/librust_pty.so
binary-sign-tool sign -selfSign 1 -inFile rust-pty/target/release/librust_pty.so -outFile rust-pty/target/release/librust_pty_arm64_ohos.so
rm rust-pty/target/release/librust_pty.so
chmod +x rust-pty/target/release/librust_pty_arm64_ohos.so

# Merge in the other 6 platforms' already-published prebuilt binaries so this
# package keeps working everywhere else, not just on OHOS (published `files`
# bundles every platform's .so/.dylib/.dll directly in the one npm package).
curl -fsSL "https://registry.npmjs.org/bun-pty/-/bun-pty-${VERSION}.tgz" -o official.tgz
tar -zxf official.tgz
cp package/rust-pty/target/release/*.so package/rust-pty/target/release/*.dylib package/rust-pty/target/release/*.dll rust-pty/target/release/ 2>/dev/null || true
rm -rf package official.tgz

npm install --ignore-scripts
export PATH="$(pwd)/node_modules/.bin:$PATH"
tsc --emitDeclarationOnly --declaration --outDir dist

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/bun-pty" ]

grep -q 'process.platform === "openharmony"' src/terminal.ts

readelf -h rust-pty/target/release/librust_pty_arm64_ohos.so | grep -q 'AArch64'
readelf -S rust-pty/target/release/librust_pty_arm64_ohos.so | grep -q '\.codesign'

# The CI image doesn't ship bun (only node/python/devel-base, per
# setup-tools.sh), but the functional test below needs it — bun-pty is a
# bun-only package (bun:ffi), so this can't be swapped for a node check.
# Pulling it from our own tap:
#  - `brew tap`/`install` need an explicit HTTPS URL: this repo's git remotes
#    are SSH-only, which an anonymous CI runner can't auth against, but the
#    same repo is also a public, anonymously-clonable HTTPS remote.
#  - harmonybrew refuses to load formulas from a tap it hasn't been told to
#    trust yet (a third-party-tap safety gate, not standard Homebrew) — bun
#    pulls in bun-bootstrap as a dependency, which trips this on first use.
#  - some containers are missing the device-side OHOS ELF loader path
#    (`/system/lib/ld-musl-aarch64.so.1`, only `/lib/...` exists), which
#    breaks execution of any OHOS-native binary, bun's own post-install
#    self-check included. The symlink is idempotent and harmless if the
#    container already has it.
mkdir -p /system/lib
ln -sf /lib/ld-musl-aarch64.so.1 /system/lib/ld-musl-aarch64.so.1
brew tap social4hyq/core https://github.com/social4hyq/homebrew-core.git
brew trust social4hyq/core
brew install -y social4hyq/core/bun
bun --version

# Real functional smoke test: this container IS the target platform, so
# actually spawn a PTY through the compiled binding instead of only parsing
# the ELF header.
bun -e '
  import("./src/index.ts").then(async ({ spawn }) => {
    const term = spawn("/bin/sh", ["-c", "echo ohos-pty-smoke-test"], { name: "xterm", cols: 80, rows: 24 });
    let output = "";
    term.onData((data) => { output += data; });
    await new Promise((resolve) => term.onExit(resolve));
    if (!output.includes("ohos-pty-smoke-test")) {
      throw new Error("unexpected PTY output: " + JSON.stringify(output));
    }
    console.log("PTY spawn/read: OK");
  });
'
