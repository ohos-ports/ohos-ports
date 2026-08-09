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
# CC/CXX aren't set in the environment. That bare name resolves through
# llvm-gcc-compat's cc/c++ wrapper (a devel-base dependency, so always
# present) — but that wrapper only points at harmonybrew's llvm@21 clang
# *after* llvm@21's own post_install hook has patched it to do so. Without
# llvm@21 actually installed, the wrapper falls back to the OHOS device's
# older bundled toolchain (clang 15.0.4), whose libcxx-ohos headers don't
# have <source_location> — which node's own v8 headers pull in
# unconditionally, so the build fails before it ever reaches this package's
# own source. setup-tools.sh only installs devel-base, not llvm@21 itself,
# so install it explicitly (same tap+trust dance bun-pty's build.sh uses for
# its own bun dependency — this tap isn't pre-trusted on a fresh runner).
brew tap social4hyq/core https://github.com/social4hyq/homebrew-core.git
brew trust social4hyq/core
brew install -y social4hyq/core/llvm@21

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
# v8:: symbols, and their mangled names embed the calling convention of
# whatever C++ standard library built the caller. This build links against
# llvm@21's libc++ (std::__n1::optional<...>). harmonybrew's `node` formula
# is a different, unrelated case: its own formula builds Node.js/V8 with
# Alpine Linux's native GCC in a chroot, statically linking GNU libstdc++
# (plain std::optional<...>, no inline-namespace tag at all) — not a libc++
# variant, so no ABI-namespace flag on either side could bridge it. bun
# (r56+) links libc++ with the same __n1 tag as this build, and is also the
# actual runtime upstream's own acceptance test
# (test/integration/datadog-pprof/datadog-pprof.test.ts) uses, so that's
# what we verify against here.
#
# The CI image doesn't ship bun (only node/python/devel-base, per
# setup-tools.sh) — pulling it from our own tap (already trusted above):
mkdir -p /system/lib
ln -sf /lib/ld-musl-aarch64.so.1 /system/lib/ld-musl-aarch64.so.1
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
