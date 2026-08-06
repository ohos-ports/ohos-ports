#!/bin/sh
set -e

# No native compile step: this port reuses the upstream @opentui/core-linux-arm64-musl
# libopentui.so as-is (OHOS is musl-ABI-compatible, verified by dlopen via ctypes on
# a real OHOS ARM64 container) with a patched resolveNativeLibraryPath() that adds an
# openharmony branch pointing at the bundled .so, plus an `openharmony` entry in
# NATIVE_FILE_NAMES so getNativeAssetDescriptor() doesn't throw before reaching that
# branch. Because there is no compile step here, the .so does not get the automatic
# LLD codesign that a container-native `cargo build`/`napi build` would give it — it
# has to be stripped + signed explicitly below.

VERSION=0.4.5
PKG=opentui-core

curl -fsSL "https://registry.npmjs.org/@opentui/core/-/core-${VERSION}.tgz" -o core.tgz
tar -zxf core.tgz
rm core.tgz
mv package "${PKG}-${VERSION}"

curl -fsSL "https://registry.npmjs.org/@opentui/core-linux-arm64-musl/-/core-linux-arm64-musl-${VERSION}.tgz" -o core-musl.tgz
tar -zxf core-musl.tgz
rm core-musl.tgz
cp package/libopentui.so "${PKG}-${VERSION}/libopentui.so"
rm -rf package

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch
patch -p1 < ../patchs/0002-openharmony-loader.patch

llvm-strip --strip-all libopentui.so
binary-sign-tool sign -selfSign 1 -inFile libopentui.so -outFile libopentui.so.signed
mv libopentui.so.signed libopentui.so
chmod +x libopentui.so

# --- verify package contents (mirrors what a build-only ubuntu-x86 CI cannot
#     check functionally: this runs on real OHOS ARM64, so the dlopen check
#     below is a real functional test, not a static approximation) ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/opentui-core" ]

for f in *.js; do
  node --check "$f"
done

for f in chunk-bun-t2myhmwd.js chunk-node-q0cwyvm9.js; do
  grep -q 'openharmony: "libopentui.so"' "$f"
  grep -q 'process.platform === "openharmony"' "$f"
done

readelf -h libopentui.so | grep -q 'AArch64'
readelf -S libopentui.so | grep -q '\.codesign'

# Self-reference guard: this package is consumed via npm alias override
# (@opentui/core -> npm:@ohos-ports/opentui-core), so bare "@opentui/core"
# imports inside its own .js files are unresolvable under bun/pnpm's isolated
# store. They must use relative paths instead.
if grep -rnE '(from|import\(|require\()"@opentui/core["/]' *.js; then
  echo "Bare @opentui/core self-import found (breaks npm alias override resolution)" >&2
  exit 1
fi

# optionalDependencies must track the upstream base version (the package's own
# version may carry a -patch.N suffix that doesn't correspond to a new upstream
# release).
node -e '
  const pkg = require("./package.json");
  const base = pkg.version.replace(/-.*$/, "");
  for (const [name, range] of Object.entries(pkg.optionalDependencies ?? {})) {
    if (name.startsWith("@opentui/core-") && range !== base) {
      console.error(`optionalDependencies["${name}"] = ${range}, expected ${base}`);
      process.exit(1);
    }
  }
'

# Real functional smoke test: this container IS the target platform, so
# actually dlopen the signed .so instead of only parsing its ELF header.
python3 -c "
import ctypes
ctypes.CDLL('./libopentui.so')
print('libopentui.so dlopen: OK')
"
