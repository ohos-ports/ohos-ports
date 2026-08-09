#!/bin/sh
set -e

# node-gyp (nan) build: this container's node-gyp already recognizes
# openharmony/arm64 and generates a working Makefile — no cross-compile
# target/toolchain wrapper needed, same as the napi-rs ports.

VERSION=5.17.0
PKG=pprof

curl -fsSL "https://github.com/DataDog/pprof-nodejs/archive/refs/tags/v${VERSION}.tar.gz" -o pprof.tar.gz
tar -zxf pprof.tar.gz
rm pprof.tar.gz
mv "pprof-nodejs-${VERSION}" "${PKG}-${VERSION}"

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch

# node-gyp isn't a devDependency of this package (upstream relies on it being
# available globally / bundled with npm), so install it explicitly to get it
# onto node_modules/.bin. --ignore-scripts also skips the "prepare" script
# (compile + rebuild) so we can run each step ourselves and check its output.
npm install --ignore-scripts
npm install --ignore-scripts --no-save node-gyp
export PATH="$(pwd)/node_modules/.bin:$PATH"

npm run compile

# node-gyp's generated Makefile falls back to a bare `clang++`/`clang` when
# CC/CXX aren't set in the environment. On this container that bare name
# resolves to the OHOS device's own bundled toolchain
# (/data/service/hnp/bin/clang++, clang 15.0.4), not harmonybrew's llvm@21 —
# and that older toolchain's libcxx-ohos headers don't have <source_location>,
# which node's own v8 headers pull in unconditionally, so the build fails
# before it ever reaches this package's own source. Point CC/CXX at
# harmonybrew's cc/c++ (llvm@21) explicitly to fix the header search path.
export CC=cc CXX=c++
node-gyp rebuild --jobs=max

ABI=$(node -p process.versions.modules)
# Bun and the harmonybrew `node` formula on this device both currently
# report ABI 147; node-gyp-build's resolver keys the prebuild filename off of
# this value, so if it drifts the file we produce below won't be found at
# runtime. Fail loudly instead of silently shipping a mis-named binary.
[ "$ABI" = "147" ] || { echo "unexpected ABI $ABI (expected 147)" >&2; exit 1; }

mkdir -p prebuilds/openharmony-arm64
cp "build/Release/dd_pprof.node" "prebuilds/openharmony-arm64/dd_pprof.node.abi${ABI}.node"

cd prebuilds/openharmony-arm64
llvm-strip --strip-all "dd_pprof.node.abi${ABI}.node"
binary-sign-tool sign -selfSign 1 -inFile "dd_pprof.node.abi${ABI}.node" -outFile "dd_pprof.node.abi${ABI}.node.signed"
mv "dd_pprof.node.abi${ABI}.node.signed" "dd_pprof.node.abi${ABI}.node"
chmod +x "dd_pprof.node.abi${ABI}.node"
cd ../..

# Merge in the other 5 platforms' already-published prebuilt binaries so this
# package keeps working everywhere else, not just on OHOS (node-gyp-build
# resolves from a single prebuilds/ tree bundled in the one npm package,
# same model as bufferutil).
curl -fsSL "https://registry.npmjs.org/@datadog/pprof/-/pprof-${VERSION}.tgz" -o official.tgz
tar -zxf official.tgz
cp -r package/prebuilds/darwin-arm64 package/prebuilds/darwin-x64 \
      package/prebuilds/linux-arm64 package/prebuilds/linux-x64 \
      package/prebuilds/win32-x64 prebuilds/
rm -rf package official.tgz

# node-gyp-build checks build/Release before prebuilds/ (its own local-build
# fast path), and it would happily resolve to the addon still sitting there
# from the node-gyp invocation above. That path isn't in this package's
# "files" list, so real consumers installing from npm never see it — but
# leaving it here would make the resolver check below pass for the wrong
# reason. Remove it so the check reflects what actually gets published.
rm -rf build

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/datadog-pprof" ]

[ -z "$(node -e "console.log(require('./package.json').postinstall || '')")" ]

readelf -h "prebuilds/openharmony-arm64/dd_pprof.node.abi${ABI}.node" | grep -q 'AArch64'
readelf -S "prebuilds/openharmony-arm64/dd_pprof.node.abi${ABI}.node" | grep -q '\.codesign'

# node-gyp-build's own resolver must pick our file (path resolution only,
# doesn't dlopen — safe to run under plain node).
RESOLVED=$(node -e "console.log(require('./node_modules/node-gyp-build').resolve('.'))")
case "$RESOLVED" in
  */prebuilds/openharmony-arm64/dd_pprof.node.abi"${ABI}".node) ;;
  *) echo "node-gyp-build resolved to unexpected path: $RESOLVED" >&2; exit 1 ;;
esac

# Real functional smoke test: dlopen'ing this addon and calling its actual
# V8 CPU-profiler API (not just parsing the ELF header). This can't be done
# with plain `node` on this device: the addon directly calls host-exported
# v8:: symbols whose mangled names embed a libc++ ABI namespace tag
# (std::__n1::optional<...> vs std::__h::optional<...>), and harmonybrew's
# `node` formula and bun currently carry different tags — see
# docs/harmony-ohos-porting-guide.md §2.8 in the Workspace repo for the full
# investigation. Bun (r56+) is `__n1`, matching this build, and is also the
# actual runtime bun's own upstream acceptance test
# (test/integration/datadog-pprof/datadog-pprof.test.ts) uses, so that's
# what we verify against here.
#
# The CI image doesn't ship bun (only node/python/devel-base, per
# setup-tools.sh) — pulling it from our own tap, same recipe as bun-pty:
mkdir -p /system/lib
ln -sf /lib/ld-musl-aarch64.so.1 /system/lib/ld-musl-aarch64.so.1
brew tap social4hyq/core https://github.com/social4hyq/homebrew-core.git
brew trust social4hyq/core
brew install -y social4hyq/core/bun
bun --version

bun -e '
  const { time } = require("./out/src/index.js");

  function hotLoop() {
    const start = Date.now();
    let acc = 0;
    while (Date.now() - start < 300) {
      for (let i = 0; i < 1000; i++) acc += Math.sqrt(i);
    }
    return acc;
  }

  time.start({ intervalMicros: 1000, durationMillis: 60000 });
  hotLoop();
  const profile = time.stop();

  const strings = profile.stringTable.strings;
  const summary = {
    sampleCount: profile.sample.length,
    locationCount: profile.location.length,
    functionCount: profile.function.length,
    hasHotLoop: strings.includes("hotLoop"),
  };
  console.log("TimeProfiler summary:", JSON.stringify(summary));
  if (summary.sampleCount === 0 || !summary.hasHotLoop) {
    throw new Error("smoke test failed: no samples or missing hotLoop frame");
  }
'
