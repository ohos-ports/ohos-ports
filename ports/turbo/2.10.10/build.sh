#!/bin/sh
set -e

# Source build of turbo for OpenHarmony (no prebuilt binaries): the Rust CLI
# (crates/turborepo), the TUI's libghostty-vt via zig, and the JS launcher
# (packages/turbo) all build natively on an OHOS host.

VERSION=2.10.10
PKG=turbo
# Must match the pinned commit in crates/libghostty-vt-sys/build.rs.
GHOSTTY_COMMIT=a887df42c56f6de86c0fe6da9c4eeca37931e083
# Matches rust-toolchain.toml; the tree uses #![feature(...)] and -Z rustflags,
# so stable rustc cannot build it.
RUST_NIGHTLY=2026-05-22

# Large downloads intermittently stall or die mid-transfer on some networks.
CURL="curl -fsSL --retry 8 --retry-all-errors --connect-timeout 30 --speed-limit 10240 --speed-time 30"

# --- toolchain dependencies ---
# protoc for turborepo-daemon's tonic-prost-build, capnp for the embedded
# sccache, openssl@3/libxml2/zlib for rust-nightly's cargo and rust-lld.
# binary-sign-tool (from ohos-sdk, present via devel-base) covers every
# signing need below: the zig binary, zig's intermediate build executables,
# and the final turbo binary.
brew install -y protobuf capnp openssl@3 libxml2 zlib

# zig for the TUI's libghostty-vt (ghostty's pinned commit requires
# >= 0.15.2). Official static tarball; zig finds its lib/ via its own
# realpath, so keep the extracted tree intact.
ZIG_VERSION=0.15.2
$CURL "https://ziglang.org/download/${ZIG_VERSION}/zig-aarch64-linux-${ZIG_VERSION}.tar.xz" -o zig.tar.xz
echo "958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f  zig.tar.xz" | sha256sum -c -
tar -xJf zig.tar.xz
rm zig.tar.xz
binary-sign-tool sign -selfSign 1 -inFile "zig-aarch64-linux-${ZIG_VERSION}/zig" -outFile zig-signed
mv zig-signed "zig-aarch64-linux-${ZIG_VERSION}/zig"
chmod +x "zig-aarch64-linux-${ZIG_VERSION}/zig"
export PATH="$(pwd)/zig-aarch64-linux-${ZIG_VERSION}:$PATH"
mkdir -p /data/storage/el2/base/cache/zig
export ZIG_GLOBAL_CACHE_DIR=/data/storage/el2/base/cache/zig

# --- rust nightly toolchain (upstream-pinned channel) ---
# The official ohos host binaries are unsigned, and OHOS refuses to exec
# unsigned ELF — sign everything before first use (same dance bun.rb does).
$CURL "https://static.rust-lang.org/dist/${RUST_NIGHTLY}/rust-nightly-aarch64-unknown-linux-ohos.tar.gz" -o rust-nightly.tar.gz
mkdir -p rust-nightly-extract
tar -zxf rust-nightly.tar.gz -C rust-nightly-extract --strip-components=1
rm rust-nightly.tar.gz
RUST_HOME="$(pwd)/rust-nightly"
sh rust-nightly-extract/install.sh --prefix="${RUST_HOME}" --disable-ldconfig \
  --components=rustc,cargo,rust-std-aarch64-unknown-linux-ohos
rm -rf rust-nightly-extract

# binary-sign-tool comes from ohos-sdk (present via devel-base).
find "${RUST_HOME}" -type f | while read -r f; do
  if [ "$(dd if="$f" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
    mv "$f" "$f.unsigned"
    binary-sign-tool sign -selfSign 1 -inFile "$f.unsigned" -outFile "$f"
    chmod +x "$f"
    rm "$f.unsigned"
  fi
done

export PATH="${RUST_HOME}/bin:$PATH"
export LD_LIBRARY_PATH="$(brew --prefix openssl@3)/lib:$(brew --prefix libxml2)/lib:$(brew --prefix zlib)/lib"
# rust-nightly's cargo verifies TLS against the system OpenSSL trust store,
# which is empty on OHOS; point it at harmonybrew's CA bundle.
export CARGO_HTTP_CAINFO="$(brew --prefix)/etc/openssl@3/cert.pem"
cargo --version

# --- sources ---
# Tarballs instead of git clone: the CI image has no git binary (cargo's own
# git deps go through libgit2, so they don't need it either).
$CURL "https://codeload.github.com/vercel/turborepo/tar.gz/refs/tags/v${VERSION}" -o turborepo.tar.gz
mkdir -p "turborepo-${VERSION}"
tar -zxf turborepo.tar.gz -C "turborepo-${VERSION}" --strip-components=1
rm turborepo.tar.gz

# libghostty-vt-sys's build.rs git-clones ghostty at this pinned commit;
# pre-seed via GHOSTTY_SOURCE_DIR (no git binary here).
$CURL "https://codeload.github.com/ghostty-org/ghostty/tar.gz/${GHOSTTY_COMMIT}" -o ghostty.tar.gz
mkdir -p ghostty-src
tar -zxf ghostty.tar.gz -C ghostty-src --strip-components=1
rm ghostty.tar.gz
export GHOSTTY_SOURCE_DIR="$(pwd)/ghostty-src"

cd "turborepo-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch
patch -p1 < ../patchs/0002-openharmony-wrapper.patch
patch -p1 < ../patchs/0005-libghostty-vt-sys-ohos-zig-target.patch

# Vendor the three crates that need OHOS fixes (same pattern bun-pty uses for
# portable-pty), then wire up [patch.crates-io] + Cargo.lock via 0003/0004.
cargo fetch
mkdir -p vendor
rm -rf vendor/nix vendor/zstd-sys vendor/aws-lc-sys
# Machines with a configured cargo mirror have multiple registry src dirs.
cp -r "$(ls -d "$HOME"/.cargo/registry/src/*/nix-0.26.2 | head -1)" vendor/nix
cp -r "$(ls -d "$HOME"/.cargo/registry/src/*/zstd-sys-2.0.16+zstd.1.5.7 | head -1)" vendor/zstd-sys
cp -r "$(ls -d "$HOME"/.cargo/registry/src/*/aws-lc-sys-0.41.0 | head -1)" vendor/aws-lc-sys
chmod -R u+w vendor/nix vendor/zstd-sys vendor/aws-lc-sys
(cd vendor/nix && patch -p1 < ../../../patchs/0006-nix-0.26.2-ohos.patch)
(cd vendor/zstd-sys && patch -p1 < ../../../patchs/0007-zstd-sys-ohos-qsort.patch)
(cd vendor/aws-lc-sys && patch -p1 < ../../../patchs/0008-aws-lc-sys-ohos-cc-builder.patch)

patch -p1 < ../patchs/0003-workspace-cargo-manifest.patch
patch -p1 < ../patchs/0004-cargo-lock.patch

# --- build ---
# zig compiles intermediate executables during `zig build` (the build runner,
# codegen tools) and execs them immediately; zig's own linker doesn't add the
# codesign section OHOS requires. Sign each as AccessDenied surfaces and
# retry — zig's cache is keyed by source hash and tolerates this (same trick
# as the herdr formula).
attempts=0
while :; do
  attempts=$((attempts + 1))
  echo "=== cargo build attempt ${attempts} ==="
  if cargo build --release --locked -p turbo > cargo-build.log 2>&1; then
    tail -3 cargo-build.log
    break
  fi
  if [ "${attempts}" -ge 20 ]; then
    echo "cargo build did not converge after ${attempts} attempts" >&2
    tail -30 cargo-build.log >&2
    exit 1
  fi
  names=$(grep -o '[A-Za-z0-9_.-]*: AccessDenied' cargo-build.log | sed 's/: AccessDenied//' | sort -u)
  if [ -z "${names}" ]; then
    echo "cargo build failed for a non-signature reason:" >&2
    tail -30 cargo-build.log >&2
    exit 1
  fi
  signed=0
  for n in ${names}; do
    for f in target/release/build/libghostty-vt-sys-*/out/zig-cache/o/*/"${n}"; do
      # Same basename can appear in several cache dirs, some already signed.
      if [ -f "${f}" ] && binary-sign-tool sign -selfSign 1 -inFile "${f}" -outFile "${f}.signed" > /dev/null 2>&1; then
        mv "${f}.signed" "${f}"
        chmod +x "${f}"
        echo "signed ${f}"
        signed=1
      fi
    done
  done
  if [ "${signed}" -eq 0 ]; then
    echo "AccessDenied reported but nothing left to sign: ${names}" >&2
    tail -10 cargo-build.log >&2
    exit 1
  fi
done
rm -f cargo-build.log

test -f target/release/turbo

# --- assemble the npm package ---
# Mirror the published `turbo` package layout. schema.json is gitignored in
# the repo (generated at release time); the turbo-types copy is
# byte-identical to the published one.
cd ..
PKG_DIR="${PKG}-${VERSION}"
mkdir -p "${PKG_DIR}/bin"
cp "turborepo-${VERSION}/packages/turbo/package.json" \
   "turborepo-${VERSION}/packages/turbo/README.md" \
   "turborepo-${VERSION}/LICENSE" \
   "${PKG_DIR}/"
cp "turborepo-${VERSION}/packages/turbo/bin/turbo" "${PKG_DIR}/bin/turbo"
chmod +x "${PKG_DIR}/bin/turbo"
cp "turborepo-${VERSION}/packages/turbo-types/schemas/schema.json" "${PKG_DIR}/schema.json"

llvm-strip --strip-all "turborepo-${VERSION}/target/release/turbo" -o "${PKG_DIR}/bin/turbo-linux-arm64"
chmod +x "${PKG_DIR}/bin/turbo-linux-arm64"

# llvm-strip drops the .codesign section the patched LLD added at link time,
# so sign after stripping. The signature section is part of the file content,
# so it survives npm/bun installs into node_modules.
binary-sign-tool sign -selfSign 1 -inFile "${PKG_DIR}/bin/turbo-linux-arm64" -outFile "${PKG_DIR}/bin/turbo-linux-arm64.signed"
mv "${PKG_DIR}/bin/turbo-linux-arm64.signed" "${PKG_DIR}/bin/turbo-linux-arm64"
chmod +x "${PKG_DIR}/bin/turbo-linux-arm64"

cd "${PKG_DIR}"

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/turbo" ]

# toybox patch can silently no-op on a malformed header, so confirm the
# patches actually landed rather than trusting patch's exit code.
grep -q '"@ohos-ports/turbo"' package.json
grep -q 'turbo-linux-arm64' bin/turbo
grep -q 'platform === "openharmony"' bin/turbo

readelf -h bin/turbo-linux-arm64 | grep -q 'AArch64'
readelf -S bin/turbo-linux-arm64 | grep -q '\.codesign'

# --- functional smoke test ---
# Real launcher -> embedded binary path: version check, then a minimal
# monorepo build — real execution on run 1, full cache hit on run 2.

VERSION_OUT=$(node bin/turbo --version)
[ "$VERSION_OUT" = "${VERSION}" ] || { echo "unexpected version: $VERSION_OUT" >&2; exit 1; }

# The smoke workspace deliberately lives outside this checkout: the CI image
# has no git binary, and turbo's input hashing + cache persistence behave
# differently depending on whether it finds a .git dir above the workspace.
SMOKE=$(mktemp -d)
LOGDIR="$(pwd)"
mkdir -p "${SMOKE}/packages/pkg-a" "${SMOKE}/packages/pkg-b"

cat > "${SMOKE}/package.json" <<'EOF'
{
  "name": "turbo-smoke",
  "private": true,
  "packageManager": "npm@10.0.0",
  "workspaces": [
    "packages/*"
  ]
}
EOF

cat > "${SMOKE}/turbo.json" <<'EOF'
{
  "$schema": "https://turborepo.dev/schema.json",
  "tasks": {
    "build": {
      "outputs": ["dist/**"]
    }
  }
}
EOF

# Pre-create the outputs with the exact content the build scripts produce:
# without git, turbo hashes every workspace file as a task input, so the
# first run's own dist/ output would change the second run's input hash.
for p in pkg-a pkg-b; do
  mkdir -p "${SMOKE}/packages/${p}/dist"
  echo "built-by-${p}" > "${SMOKE}/packages/${p}/dist/out.txt"
done

for p in pkg-a pkg-b; do
  cat > "${SMOKE}/packages/${p}/package.json" <<EOF
{
  "name": "${p}",
  "version": "0.0.0",
  "private": true,
  "scripts": {
    "build": "mkdir -p dist && echo built-by-${p} > dist/out.txt"
  }
}
EOF
done

export TURBO_TELEMETRY_DISABLED=1
WRAPPER="${LOGDIR}/bin/turbo"

cd "${SMOKE}"
# Logs live outside the smoke workspace for the same hashing reason.
# The warm-up run absorbs two one-time, first-run-only transitions seen in a
# fresh git-less workspace (real-world repos have git and never see either):
# the first run's input hash differs from every later run's, and the first
# run doesn't persist its cache artifacts.
node "${WRAPPER}" run build > "${LOGDIR}/smoke-run0.log" 2>&1 || { cat "${LOGDIR}/smoke-run0.log" >&2; exit 1; }

node "${WRAPPER}" run build > "${LOGDIR}/smoke-run1.log" 2>&1 || { cat "${LOGDIR}/smoke-run1.log" >&2; exit 1; }
grep -q 'cache miss, executing' "${LOGDIR}/smoke-run1.log" || { cat "${LOGDIR}/smoke-run1.log" >&2; exit 1; }
[ "$(cat packages/pkg-a/dist/out.txt)" = "built-by-pkg-a" ]
[ "$(cat packages/pkg-b/dist/out.txt)" = "built-by-pkg-b" ]

node "${WRAPPER}" run build > "${LOGDIR}/smoke-run2.log" 2>&1 || { cat "${LOGDIR}/smoke-run2.log" >&2; exit 1; }
grep -q 'FULL TURBO' "${LOGDIR}/smoke-run2.log" || { cat "${LOGDIR}/smoke-run2.log" >&2; exit 1; }
cd "${LOGDIR}"

rm -rf "${SMOKE}" smoke-run0.log smoke-run1.log smoke-run2.log

echo "smoke test passed: real build executed, second run was a full cache hit"
