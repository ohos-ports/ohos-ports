#!/bin/sh
set -e

# Source build of tsgolint for OpenHarmony: the Go binary compiles natively on
# an OHOS host (host == target, no cgo, static output). The official npm
# tarball is repacked with the signed binary embedded under
# @oxlint-tsgolint/openharmony-arm64/ and a loader patch wiring it in.

VERSION=7.0.2001
PKG=oxlint-tsgolint

# setup-tools.sh only installs node/python/devel-base.
brew install -y go git

# ── 1. Build from source (mirrors upstream justfile init+build) ───────

git clone --depth 1 --branch "v${VERSION}" https://github.com/oxc-project/tsgolint.git tsgolint-src
cd tsgolint-src
# git am creates commits; the CI container has no git identity configured.
git config user.email port@example.com
git config user.name port
git submodule update --init --depth 1
# git am runs inside the submodule, which has its own git config.
git -C typescript-go config user.email port@example.com
git -C typescript-go config user.name port
cd typescript-go
git am --3way --no-gpg-sign ../patches/0*.patch
cd ..
mkdir -p internal/collections
find ./typescript-go/internal/collections -type f ! -name '*_test.go' \
  -exec cp {} internal/collections/ \;

# harmonybrew's go binary has a device-only default baked in for its temp
# dir ("creating work dir" fails in CI containers). GOTMPDIR (not TMPDIR)
# is what go actually consults; GOCACHE/GOMODCACHE likewise redirected.
export GOTMPDIR="$PWD/.gotmpdir"
export GOCACHE="$PWD/.gocache"
export GOMODCACHE="$(brew --prefix)/var/go-mod-cache"
mkdir -p "$GOTMPDIR" "$GOCACHE" "$GOMODCACHE"
go build -ldflags="-s -w" -trimpath -o tsgolint ./cmd/tsgolint

binary-sign-tool sign -selfSign 1 -inFile tsgolint -outFile tsgolint.signed
chmod +x tsgolint.signed
readelf -h tsgolint.signed | grep -q 'AArch64'
readelf -l tsgolint.signed | grep -q INTERP && { echo "ERROR: not static" >&2; exit 1; } || true

cd ..

# ── 2. Repack the official npm tarball ────────────────────────────────

npm pack "${PKG}@${VERSION}" --pack-destination .
tar -zxf "${PKG}-${VERSION}.tgz"
rm "${PKG}-${VERSION}.tgz"
mv package "${PKG}-${VERSION}"

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch
patch -p1 < ../patchs/0002-openharmony-loader.patch

mkdir -p @oxlint-tsgolint/openharmony-arm64
cp ../tsgolint-src/tsgolint.signed @oxlint-tsgolint/openharmony-arm64/tsgolint
chmod +x @oxlint-tsgolint/openharmony-arm64/tsgolint
cat > @oxlint-tsgolint/openharmony-arm64/package.json <<'EOF'
{
  "name": "@oxlint-tsgolint/openharmony-arm64",
  "version": "7.0.2001",
  "description": "High-performance type-aware TypeScript linter powered by typescript-go, for use with oxlint. — OpenHarmony (OHOS) build",
  "license": "MIT",
  "preferUnplugged": true,
  "files": [
    "tsgolint"
  ],
  "os": [
    "openharmony"
  ],
  "cpu": [
    "arm64"
  ]
}
EOF

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/oxlint-tsgolint" ]

grep -q "openharmony" bin/tsgolint.js
test -x @oxlint-tsgolint/openharmony-arm64/tsgolint

readelf -h @oxlint-tsgolint/openharmony-arm64/tsgolint | grep -q 'AArch64'
readelf -S @oxlint-tsgolint/openharmony-arm64/tsgolint | grep -q '\.codesign'

# Functional smoke test through the real entrypoint (the same path oxlint
# uses): lint a file with a deliberate type error, expect the diagnostic.
PKG_DIR="$PWD"
SMOKE="$(mktemp -d)"
cd "${SMOKE}"
printf '{"compilerOptions":{"strict":true}}' > tsconfig.json
printf 'const n = 1 as unknown as string | undefined;\n' > bad.ts
"${PKG_DIR}/bin/tsgolint.js" -tsconfig tsconfig.json bad.ts > out.txt 2>&1 || true
grep -q 'no-unsafe-type-assertion' out.txt || { cat out.txt >&2; exit 1; }
cd - >/dev/null
rm -rf "${SMOKE}"

echo "OK: @ohos-ports/oxlint-tsgolint repacked with openharmony-arm64 binary"
