#!/bin/sh
set -e

# Native napi-rs build: this container's rustc host triple is already
# aarch64-unknown-linux-ohos, so no cross-compile target/toolchain wrapper is
# needed — `napi build --platform` recognizes openharmony as the host and
# produces the correctly-named binding directly.

VERSION=1.33.0
PKG=lightningcss

curl -fsSL "https://github.com/parcel-bundler/lightningcss/archive/refs/tags/v${VERSION}.tar.gz" -o lightningcss.tar.gz
tar -zxf lightningcss.tar.gz
rm lightningcss.tar.gz
# GitHub source archives already extract to <repo>-<version>/, which happens
# to equal ${PKG}-${VERSION} here, so no rename is needed.

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch
patch -p1 < ../patchs/0002-openharmony-loader.patch

brew install -y rust

# --ignore-scripts: upstream's devDependencies include puppeteer (used only
# by the website/docs tooling, unrelated to the napi build path below), and
# its postinstall script hard-fails with "Unsupported platform: openharmony"
# trying to download a Chromium binary. We only need the napi build itself.
npm install --ignore-scripts

# scripts/build.js shells out to the bare `napi` command; node_modules/.bin
# is not on PATH by default in this environment.
export PATH="$(pwd)/node_modules/.bin:$PATH"
node scripts/build.js --release

test -f lightningcss.linux-arm64-ohos.node

llvm-strip --strip-all lightningcss.linux-arm64-ohos.node
binary-sign-tool sign -selfSign 1 -inFile lightningcss.linux-arm64-ohos.node -outFile lightningcss.linux-arm64-ohos.node.signed
mv lightningcss.linux-arm64-ohos.node.signed lightningcss.linux-arm64-ohos.node
chmod +x lightningcss.linux-arm64-ohos.node

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/lightningcss" ]

node --check node/index.js
grep -q "process.platform === 'openharmony'" node/index.js

readelf -h lightningcss.linux-arm64-ohos.node | grep -q 'AArch64'
readelf -S lightningcss.linux-arm64-ohos.node | grep -q '\.codesign'

# optionalDependencies must track the upstream base version (this package's
# own version carries a -N revision suffix that doesn't correspond to a new
# upstream release).
node -e '
  const pkg = require("./package.json");
  const base = pkg.version.replace(/-.*$/, "");
  for (const [name, range] of Object.entries(pkg.optionalDependencies ?? {})) {
    if (name.startsWith("lightningcss-") && range !== base) {
      console.error(`optionalDependencies["${name}"] = ${range}, expected ${base}`);
      process.exit(1);
    }
  }
'

# Real functional smoke test: this container IS the target platform, so
# actually load the addon and run a transform instead of only parsing the
# ELF header.
node -e '
  const { transform } = require("./node/index.js");
  const { code } = transform({
    filename: "test.css",
    code: Buffer.from(".a { color: red }"),
    minify: true,
  });
  const out = code.toString();
  console.log("transform() output:", out);
  if (!out.includes(".a") || !out.includes("red")) {
    throw new Error("unexpected transform output");
  }
'
