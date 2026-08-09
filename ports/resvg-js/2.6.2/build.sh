#!/bin/sh
set -e

# Native cargo build: this container's rustc host triple is already
# aarch64-unknown-linux-ohos, so no cross-compile target/toolchain wrapper is
# needed. We build the cdylib directly with `cargo build --release` instead
# of going through `napi build` — upstream's devDependencies pin
# `@napi-rs/cli@^2.18.0`, which does not recognize `openharmony` as a host
# platform, and unlike lightningcss we don't need its `--js`/`--dts`
# generation step (js-binding.js is already committed upstream and patched
# in 0002). Skipping the JS toolchain entirely also means we never need
# `npm install` for this package.

VERSION=2.6.2
PKG=resvg-js

curl -fsSL "https://github.com/yisibl/resvg-js/archive/refs/tags/v${VERSION}.tar.gz" -o resvg-js.tar.gz
tar -zxf resvg-js.tar.gz
rm resvg-js.tar.gz
# GitHub source archives extract to <repo>-<version>/, which equals
# ${PKG}-${VERSION} here, so no rename is needed.

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch
patch -p1 < ../patchs/0002-openharmony-loader.patch

# The committed rust-toolchain file pins nightly-2023-12-11 via rustup, which
# isn't installed in this container (we use harmonybrew's rust directly) and
# predates OHOS target support anyway. Removing it avoids a spurious rustup
# lookup if any tool in the chain checks for it.
rm -f rust-toolchain

brew install -y rust

cargo build --release

test -f target/release/libresvg_js.so
cp target/release/libresvg_js.so resvgjs.linux-arm64-ohos.node

llvm-strip --strip-all resvgjs.linux-arm64-ohos.node
binary-sign-tool sign -selfSign 1 -inFile resvgjs.linux-arm64-ohos.node -outFile resvgjs.linux-arm64-ohos.node.signed
mv resvgjs.linux-arm64-ohos.node.signed resvgjs.linux-arm64-ohos.node
chmod +x resvgjs.linux-arm64-ohos.node

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/resvg-js" ]

node --check js-binding.js
grep -q "case 'openharmony':" js-binding.js

readelf -h resvgjs.linux-arm64-ohos.node | grep -q 'AArch64'
readelf -S resvgjs.linux-arm64-ohos.node | grep -q '\.codesign'

# optionalDependencies must track the upstream base version — this package's
# own version is a direct alias of the upstream release (no -N revision
# suffix on first publish), so every @resvg/resvg-js-* entry should equal it.
node -e '
  const pkg = require("./package.json");
  for (const [name, range] of Object.entries(pkg.optionalDependencies ?? {})) {
    if (name.startsWith("@resvg/resvg-js-") && range !== pkg.version) {
      console.error(`optionalDependencies["${name}"] = ${range}, expected ${pkg.version}`);
      process.exit(1);
    }
  }
'

# Real functional smoke test: this container IS the target platform, so
# actually load the addon and render/measure an SVG instead of only parsing
# the ELF header. Avoids text rendering (font availability in the CI
# container is unverified) and sticks to pure geometry.
node -e '
  const { Resvg } = require("./js-binding.js");
  const svg = `<svg width="100" height="50" xmlns="http://www.w3.org/2000/svg">
    <rect x="10" y="10" width="30" height="20" fill="red"/>
  </svg>`;

  const resvg = new Resvg(svg);
  const bbox = resvg.innerBBox();
  console.log("innerBBox():", JSON.stringify(bbox));
  if (!bbox || bbox.width <= 0 || bbox.height <= 0) {
    throw new Error("unexpected bbox result");
  }

  const rendered = resvg.render();
  const png = rendered.asPng();
  console.log("render() -> PNG bytes:", png.length, "size:", rendered.width, "x", rendered.height);
  // PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
  const magic = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (let i = 0; i < magic.length; i++) {
    if (png[i] !== magic[i]) {
      throw new Error("output is not a valid PNG");
    }
  }
'
