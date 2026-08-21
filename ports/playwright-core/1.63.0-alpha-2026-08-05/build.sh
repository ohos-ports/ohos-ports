#!/bin/sh
set -e

# Zero-compile port of the OFFICIAL playwright-core npm release: the
# authoritative tarball is fetched with `npm pack` (integrity-verified against
# registry.npmjs.org), the OHOS adaptation is applied as a static patch, and the
# launcher is copied in from files/. Nothing is patched at install time, so the
# published package works out of the box with npm/bun/pnpm alike.
#
# files/ohos-launcher.cjs is adapted from pzf0000/playwright-ohos@0b5de08 (ISC);
# lib/coreBundle.js reaches it via require("./ohos-launcher.cjs").

VERSION=1.63.0-alpha-2026-08-05
PKG=playwright-core

rm -rf "${PKG}-${VERSION}" package
npm pack "playwright-core@${VERSION}"
tar -zxf "${PKG}-${VERSION}.tgz"
rm "${PKG}-${VERSION}.tgz"
mv package "${PKG}-${VERSION}"

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch
patch -p1 < ../patchs/0002-corebundle-ohos-patches.patch
cp ../files/ohos-launcher.cjs lib/ohos-launcher.cjs

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/playwright-core" ]

node --check lib/coreBundle.js
node --check lib/ohos-launcher.cjs

MARKERS=$(grep -c '@playwright-ohos-patched' lib/coreBundle.js)
echo "patch markers in coreBundle.js: $MARKERS"
[ "$MARKERS" -eq 21 ]

# Unpatched playwright-core throws "Unsupported platform: openharmony" at
# module load — on the OHOS CI container a successful require is itself the
# functional test.
node -e "
const pw = require('./');
if (typeof pw.chromium?.launch !== 'function') { console.error('chromium.launch missing'); process.exit(1); }
console.log('patched playwright-core loads on ' + process.platform + ': OK');
"

node -e "
const l = require('./lib/ohos-launcher.cjs');
for (const k of ['launchViaHdc', 'ohosInitScript', 'HdcBackend', 'resolveLaunchConfig']) {
  if (!l[k]) { console.error('ohos-launcher missing export: ' + k); process.exit(1); }
}
console.log('ohos-launcher.cjs loads: OK');
"

# The launcher is a plain file rather than a patch, so confirm npm will ship it.
node -e "
const { execFileSync } = require('child_process');
const out = JSON.parse(execFileSync('npm', ['pack', '--dry-run', '--json'], { encoding: 'utf8' }))[0];
if (!out.files.some(f => f.path === 'lib/ohos-launcher.cjs')) {
  console.error('ohos-launcher.cjs would not be published'); process.exit(1);
}
console.log('ohos-launcher.cjs is in the published file list: OK');
"
