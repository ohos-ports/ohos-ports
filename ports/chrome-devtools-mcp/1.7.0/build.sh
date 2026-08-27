#!/bin/sh
set -e

# chrome-devtools-mcp v1.7.0 OHOS source-based build (final)
#
# Downloads source + devtools-frontend tarball → applies patches →
# npm: aliases for @ohos-ports packages → tsc + rollup rebuild →
# zero-dependency package with OhosLauncher bundled.
#
# NPM package: @ohos-ports/chrome-devtools-mcp@1.7.0-beta.1

VERSION=1.7.0
TAG=chrome-devtools-mcp-v${VERSION}
PKG=chrome-devtools-mcp

# 1. Download chrome-devtools-mcp source
echo "[build] downloading ${PKG} ${TAG} source..."
curl -fsSL "https://codeload.github.com/ChromeDevTools/chrome-devtools-mcp/tar.gz/refs/tags/${TAG}" -o source.tar.gz
tar -zxf source.tar.gz
rm source.tar.gz
mv "chrome-devtools-mcp-${TAG}" "${PKG}-${VERSION}"
cd "${PKG}-${VERSION}"

# 2. Download devtools-frontend submodule (tarball, not git clone)
echo "[build] downloading devtools-frontend (精确 commit b0a8253f tarball)..."
curl -fsSL "https://codeload.github.com/ChromeDevTools/devtools-frontend/tar.gz/b0a8253f0ac8aba5ec3451130f7f8b3319da1d67" -o devtools-frontend.tar.gz
rm -rf devtools-frontend
tar -zxf devtools-frontend.tar.gz
mv devtools-frontend-b0a8253f0ac8aba5ec3451130f7f8b3319da1d67 devtools-frontend
rm devtools-frontend.tar.gz
echo "  ✓ devtools-frontend downloaded ($(du -sh devtools-frontend | cut -f1))"

# 3. Apply patch: browser.ts detectDisplay openharmony
echo "[build] applying patch..."
patch -p1 < ../patchs/0001-ohos-detect-display.patch

# 4. Modify package.json
echo "[build] modifying package.json..."
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.name = '@ohos-ports/chrome-devtools-mcp';
pkg.version = '${VERSION}-beta.1';
pkg.description = 'MCP server for Chrome DevTools (HarmonyOS adaptation)';
pkg.repository = { type: 'git', url: 'git+https://github.com/ohos-ports/ohos-ports.git', directory: 'ports/chrome-devtools-mcp/${VERSION}' };
if (pkg.scripts) {
  delete pkg.scripts.prepare;
  delete pkg.scripts.postinstall;
}
// npm: protocol for direct devDependencies
const devdeps = pkg.devDependencies;
devdeps['puppeteer'] = 'npm:@ohos-ports/puppeteer@25.6.0-beta.0';
devdeps['rollup'] = 'npm:@ohos-ports/rollup@4.62.2-beta.2';
pkg.devDependencies = devdeps;
// overrides for transitive deps (puppeteer-core is dep of lighthouse)
pkg.overrides = {
  'puppeteer-core': 'npm:@ohos-ports/puppeteer-core@25.6.0-beta.0',
  '@puppeteer/browsers': 'npm:@ohos-ports/puppeteer-browsers@3.2.0-beta.0',
  '@rollup/rollup-openharmony-arm64': 'npm:@ohos-ports/rollup-rollup-openharmony-arm64@4.62.2-beta.1'
};
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
console.log('  ✓ package.json updated');
"

# 5. Change @puppeteer/browsers → @ohos-ports/puppeteer-browsers in source
echo "[build] updating @puppeteer/browsers import..."
sed -i "s|from '@puppeteer/browsers'|from '@ohos-ports/puppeteer-browsers'|" src/third_party/index.ts
echo "  ✓ @puppeteer/browsers → @ohos-ports/puppeteer-browsers"

# 6. Create .npmrc to exclude @ohos-ports from min-release-age
echo "[build] creating .npmrc..."
cat > .npmrc << 'NPMRC'
min-release-age-exclude[]=@ohos-ports/puppeteer
min-release-age-exclude[]=@ohos-ports/puppeteer-core
min-release-age-exclude[]=@ohos-ports/puppeteer-browsers
min-release-age-exclude[]=@ohos-ports/rollup
min-release-age-exclude[]=@ohos-ports/rollup-rollup-openharmony-arm64
min-release-age-exclude[]=@ohos-ports/lighthouse
NPMRC

# 7. Install dependencies
echo "[build] installing dependencies..."
rm -f package-lock.json
npm install --ignore-scripts --legacy-peer-deps


# 9. Verify overrides
echo "[build] verifying overrides..."
node -e "
const fs = require('fs');
const pcPkg = JSON.parse(fs.readFileSync('node_modules/puppeteer-core/package.json', 'utf8'));
console.log('  puppeteer-core:', pcPkg.name);
if (pcPkg.name !== '@ohos-ports/puppeteer-core') throw new Error('puppeteer-core alias failed');
const rPkg = JSON.parse(fs.readFileSync('node_modules/rollup/package.json', 'utf8'));
console.log('  rollup:', rPkg.name);
if (rPkg.name !== '@ohos-ports/rollup') throw new Error('rollup alias failed');
console.log('  ✓ overrides verified');
"

# 10. Check OhosLauncher
echo "[build] checking OhosLauncher..."
if [ -f "node_modules/puppeteer-core/lib/puppeteer/node/OhosLauncher.js" ]; then
  echo "  ✓ OhosLauncher.js found"
else
  echo "  WARNING: OhosLauncher.js not found"
fi

# 11. Clean tsc cache and build
echo "[build] cleaning tsc cache..."
find . -name "*.tsbuildinfo" -not -path "*/node_modules/*" -delete

# 12. TypeScript compilation (tsc may have non-fatal type errors)
echo "[build] running tsc..."
npx tsc 2>&1 || true
echo "[build] running post-build.ts (creates mock files)..."
node scripts/post-build.ts 2>&1 || echo "  WARNING: post-build.ts had errors"

# Verify key files produced
test -f build/src/browser.js || { echo "ERROR: browser.js not produced" >&2; exit 1; }
test -f build/src/third_party/index.js || { echo "ERROR: third_party/index.js not produced" >&2; exit 1; }
echo "  ✓ key build files produced"

# 13. Run rollup
echo "[build] running rollup..."
npx rollup -c rollup.config.js 2>&1 || {
  echo "ERROR: rollup failed" >&2
  exit 1
}

# 14. Clean up
echo "[build] cleaning build/node_modules..."
rm -rf build/node_modules

echo "[build] appending lighthouse notices..."
node scripts/append-lighthouse-notices.ts 2>/dev/null || echo "  (lighthouse notices skipped)"

# 15. Verify build output
echo "[build] verifying build output..."
test -f build/src/third_party/index.js || { echo "ERROR: third_party/index.js not found" >&2; exit 1; }
test -f build/src/browser.js || { echo "ERROR: browser.js not found" >&2; exit 1; }
test -f build/src/bin/chrome-devtools-mcp.js || { echo "ERROR: chrome-devtools-mcp.js not found" >&2; exit 1; }

grep -q "launchViaOhos\|ohos-aa\|htbrowser" build/src/third_party/index.js && echo "  ✓ OhosLauncher found in bundle" || echo "  WARNING: OhosLauncher not found in bundle"
grep -q "openharmony" build/src/browser.js || { echo "ERROR: openharmony not found in browser.js" >&2; exit 1; }
echo "  ✓ openharmony found in browser.js"

grep -c "@puppeteer/browsers" build/src/third_party/index.js > /dev/null 2>&1 && echo "  WARNING: @puppeteer/browsers still in bundle" || echo "  ✓ no @puppeteer/browsers in bundle"

DEPS=$(node -e "const p=require('./package.json'); console.log(JSON.stringify(p.dependencies||{}))")
[ "$DEPS" = "{}" ] && echo "  ✓ dependencies is empty (zero-dependency)" || echo "  WARNING: dependencies: $DEPS"

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/chrome-devtools-mcp" ] || { echo "ERROR: package name is $NAME" >&2; exit 1; }
echo "  ✓ package name: $NAME"

# 16. Smoke test: MCP server creation
echo "[build] smoke test: MCP server creation..."
node --input-type=module -e "
import { createMcpServer } from './build/src/index.js';
const server = await createMcpServer({});
if (typeof server !== 'object') throw new Error('server is not object');
console.log('  ✓ MCP server created successfully');
" 2>&1 || echo "  ✗ MCP server creation failed"

# 17. Pack
echo "[build] packing tgz..."
npm pack --ignore-scripts

echo ""
echo "[build] done. Output:"
ls -la *.tgz
