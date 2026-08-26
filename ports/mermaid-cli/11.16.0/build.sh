#!/bin/sh
set -e

# mermaid-cli 11.16.0 OHOS source-based build (beta: 11.16.0-beta.0)
# Downloads mermaid-cli npm tarball, applies OHOS patches, modifies package.json, repacks.
#
# NPM package version: 11.16.0-beta.0 (beta release)
# Source version: 11.16.0 (mermaid-cli official npm version)

VERSION=11.16.0
BETA_VERSION=11.16.0-beta.0
PKG=@mermaid-js/mermaid-cli

# 1. Download source tarball from npmjs.com
echo "[build] downloading ${PKG}@${VERSION}..."
npm pack "${PKG}@${VERSION}" --registry https://registry.npmjs.org/ --pack-destination .
TARBALL=$(ls *.tgz | head -1)
tar -xzf "$TARBALL"
rm "$TARBALL"
mv package "mermaid-cli-${VERSION}"

cd "mermaid-cli-${VERSION}"

# 2. Apply patches (single-hunk, compatible with OpenHarmony patch)
echo "[build] applying patches..."
patch -p1 < ../patchs/0001-update-puppeteer-import.patch
patch -p1 < ../patchs/0002-update-intercept-import.patch

# 3. sed: JSDoc type references (import("puppeteer") → import("@ohos-ports/puppeteer"))
echo "[build] fixing JSDoc type references..."
sed -i 's|import("puppeteer")|import("@ohos-ports/puppeteer")|g' src/index.js src/puppeteerIntercept.js
sed -i "s|import('puppeteer')|import('@ohos-ports/puppeteer')|g" src/index.js src/puppeteerIntercept.js

# 4. Modify package.json via node
echo "[build] modifying package.json..."
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.name = '@ohos-ports/mermaid-js-mermaid-cli';
pkg.version = '${BETA_VERSION}';
pkg.peerDependencies = { '@ohos-ports/puppeteer': '^25.6.0-beta.0' };
delete pkg.scripts.prepare;
delete pkg.scripts.prepack;
pkg.repository = { type: 'git', url: 'git+https://github.com/ohos-ports/ohos-ports.git', directory: 'ports/mermaid-cli/11.16.0' };
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
console.log('  ✓ package.json (${BETA_VERSION})');
"

# 5. Verify patches
echo "[build] verifying..."
grep -q "@ohos-ports/puppeteer" src/index.js || { echo "ERROR: index.js not patched" >&2; exit 1; }
grep -q "@ohos-ports/puppeteer" src/puppeteerIntercept.js || { echo "ERROR: puppeteerIntercept.js not patched" >&2; exit 1; }
grep -q "@ohos-ports/mermaid-js-mermaid-cli" package.json || { echo "ERROR: package.json not renamed" >&2; exit 1; }
echo "  ✓ all patches verified"

# 6. Pack tgz
echo "[build] packing tgz..."
npm pack --quiet

echo ""
echo "[build] done. Output:"
ls -la *.tgz
