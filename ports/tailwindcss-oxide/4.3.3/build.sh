#!/bin/sh
set -e

# Native napi-rs build: this container's rustc host triple is already
# aarch64-unknown-linux-ohos, so `napi build --platform` recognizes
# openharmony as the host and produces a correctly-named binding directly —
# no cross-compile target/toolchain wrapper needed.
#
# Two npm packages come out of this port (mirrors upstream's own per-platform
# split for @tailwindcss/oxide, not a single bundled binary like lightningcss
# or opentui-core):
#   - @ohos-ports/tailwindcss-oxide                       (the JS loader)
#   - @ohos-ports/tailwindcss-oxide-openharmony-arm64      (the .node binary)
# The JS loader's optionalDependencies point at the real upstream
# @tailwindcss/oxide-* packages for every other platform, and at our own
# openharmony-arm64 package (pinned to a real version, not `workspace:*` —
# `npm stage publish` ships that literal string as-is, unlike `pnpm publish`
# which rewrites it).

VERSION=4.3.3
PKG=tailwindcss

curl -fsSL "https://github.com/tailwindlabs/tailwindcss/archive/refs/tags/v${VERSION}.tar.gz" -o tailwindcss.tar.gz
tar -zxf tailwindcss.tar.gz
rm tailwindcss.tar.gz
mv "${PKG}-${VERSION}" src
cd src

patch -p1 < ../patchs/0001-package-json.patch
patch -p1 < ../patchs/0002-add-openharmony-subpackage.patch

brew install -y rust

cd crates/node
npm install --ignore-scripts

# @napi-rs/cli hardcodes a cross-toolchain linker path for this target based
# on $OHOS_SDK_PATH/$OHOS_SDK_NATIVE (assuming cross-compilation from a
# non-OHOS host). We're building natively, so cargo's own env-var override —
# which takes precedence over any config file napi-rs writes — just needs to
# point at this container's native cc.
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$(command -v cc)"
npm run build:platform

NODE_FILE=npm/openharmony-arm64/tailwindcss-oxide.openharmony-arm64.node
test -f "$NODE_FILE"

llvm-strip --strip-all "$NODE_FILE"
binary-sign-tool sign -selfSign 1 -inFile "$NODE_FILE" -outFile "${NODE_FILE}.signed"
mv "${NODE_FILE}.signed" "$NODE_FILE"
chmod +x "$NODE_FILE"

# --- verify package contents ---

MAIN_NAME=$(node -e "console.log(require('./package.json').name)")
[ "$MAIN_NAME" = "@ohos-ports/tailwindcss-oxide" ]

SUBPKG_NAME=$(node -e "console.log(require('./npm/openharmony-arm64/package.json').name)")
[ "$SUBPKG_NAME" = "@ohos-ports/tailwindcss-oxide-openharmony-arm64" ]

readelf -h "$NODE_FILE" | grep -q 'AArch64'
readelf -S "$NODE_FILE" | grep -q '\.codesign'

# The main package's optionalDependency on our own subpackage must match the
# subpackage's actual version (everything else pins the real upstream
# version, which doesn't change here).
node -e '
  const main = require("./package.json");
  const sub = require("./npm/openharmony-arm64/package.json");
  const declared = main.optionalDependencies["@ohos-ports/tailwindcss-oxide-openharmony-arm64"];
  if (declared !== sub.version) {
    console.error(`optionalDependencies pin ${declared} != subpackage version ${sub.version}`);
    process.exit(1);
  }
'

# Real functional smoke test: this container IS the target platform, so
# actually run a real class scan through the addon instead of only parsing
# the ELF header.
node -e '
  const { Scanner } = require("./npm/openharmony-arm64/tailwindcss-oxide.openharmony-arm64.node");
  const scanner = new Scanner({ sources: [] });
  const candidates = scanner.scanFiles([
    { content: "<div class=\"text-red-500 flex\"></div>", extension: "html" },
  ]);
  console.log("scanFiles() candidates:", candidates);
  if (!candidates.includes("text-red-500") || !candidates.includes("flex")) {
    throw new Error("unexpected scan output: " + JSON.stringify(candidates));
  }
'
