#!/bin/sh
set -e

# Puppeteer 25.6.0 OHOS source-based build (beta: 25.6.0-beta.0)
# Downloads puppeteer monorepo source, applies OHOS patches, builds, packs 3 tgz.
#
# NPM package version: 25.6.0-beta.0 (beta release)
# Source version: 25.6.0 (Puppeteer official tag, directory name)
#
# Patches (applied to .ts source files via patch command):
#   0001 — detectPlatform.ts: openharmony → skip browser download
#   0002 — BrowserLauncher.ts: launch() → launchViaOhos() on openharmony
#   0003 — ElementHandle.ts: boundingBox/clickablePoint Math.round()
#
# Package.json modifications (via node, not patch):
#   0004 — puppeteer/package.json: rename, remove postinstall, update deps
#   0005 — puppeteer-core/package.json: rename, update deps
#   0004 — browsers/package.json: rename (single-hunk patch, works fine)
#
# OhosLauncher.ts is copied as a new source file (too large for patch format).
#
# Post-patch sed fixes:
#   - BrowserLauncher.ts: process.platform as string (TS2367)
#   - OhosLauncher.ts: no sed fixes needed (TS-safe code, bracket notation already used)
#   - puppeteer/src/*.ts: import 'puppeteer-core' → '@ohos-ports/puppeteer-core'
#   - All source: import '@puppeteer/browsers' → '@ohos-ports/puppeteer-browsers'
#   - Also fix dynamic import('@puppeteer/browsers') in BrowserConnector.ts
#   - Also fix string literal '@puppeteer/browsers' in CLI.ts
#
# Wireit config fixes (OpenHarmony native binding issues):
#   - Remove eslint from build:types (unrs-resolver has no openharmony binding)
#   - Remove build:es5 from build deps (rollup has no openharmony binding)
#
# Build strategy: `npm run build --workspace packages/puppeteer` avoids
# test:build which fails because test files import 'puppeteer' (renamed).

VERSION=25.6.0
PKG=puppeteer

# 1. Download source
echo "[build] downloading puppeteer v${VERSION} source..."
curl -fsSL "https://github.com/puppeteer/puppeteer/archive/refs/tags/puppeteer-v${VERSION}.tar.gz" -o puppeteer.tar.gz
tar -zxf puppeteer.tar.gz
rm puppeteer.tar.gz
mv "puppeteer-puppeteer-v${VERSION}" "${PKG}-${VERSION}"

cd "${PKG}-${VERSION}"

# 2. Apply .ts source patches (single-file, compatible with OpenHarmony patch)
echo "[build] applying source patches..."
patch -p1 < ../patchs/0001-ohos-platform-detection.patch
patch -p1 < ../patchs/0002-ohos-launch-intercept.patch
patch -p1 < ../patchs/0003-ohos-coord-rounding.patch

# 3. Apply browsers/package.json rename (single-hunk patch, works fine)
patch -p1 < ../patchs/0004-rename-browsers.patch

# 4. Modify package.json files via node (version, name, deps)
#    (OpenHarmony patch command cannot handle multi-hunk patches with line offsets)
echo "[build] modifying package.json files via node..."
node -e "
const fs = require('fs');

// puppeteer/package.json
const pup = JSON.parse(fs.readFileSync('packages/puppeteer/package.json', 'utf8'));
pup.name = '@ohos-ports/puppeteer';
pup.version = '25.6.0-beta.0';
pup.description = 'Puppeteer HarmonyOS adaptation';
pup.repository = { type: 'git', url: 'git+https://github.com/ohos-ports/ohos-ports.git', directory: 'ports/puppeteer/25.6.0' };
delete pup.scripts.postinstall;
pup.dependencies['@ohos-ports/puppeteer-browsers'] = '3.2.0-beta.0';
delete pup.dependencies['@puppeteer/browsers'];
pup.dependencies['@ohos-ports/puppeteer-core'] = '25.6.0-beta.0';
delete pup.dependencies['puppeteer-core'];
fs.writeFileSync('packages/puppeteer/package.json', JSON.stringify(pup, null, 2) + '\n');
console.log('  ✓ puppeteer/package.json (25.6.0-beta.0)');

// puppeteer-core/package.json
const core = JSON.parse(fs.readFileSync('packages/puppeteer-core/package.json', 'utf8'));
core.name = '@ohos-ports/puppeteer-core';
core.version = '25.6.0-beta.0';
core.repository = { type: 'git', url: 'git+https://github.com/ohos-ports/ohos-ports.git', directory: 'ports/puppeteer/25.6.0' };
if (core.dependencies && core.dependencies['@puppeteer/browsers']) {
  core.dependencies['@ohos-ports/puppeteer-browsers'] = '3.2.0-beta.0';
  delete core.dependencies['@puppeteer/browsers'];
}
fs.writeFileSync('packages/puppeteer-core/package.json', JSON.stringify(core, null, 2) + '\n');
console.log('  ✓ puppeteer-core/package.json (25.6.0-beta.0)');

// browsers/package.json
const browsers = JSON.parse(fs.readFileSync('packages/browsers/package.json', 'utf8'));
browsers.version = '3.2.0-beta.0';
browsers.repository = { type: 'git', url: 'git+https://github.com/ohos-ports/ohos-ports.git', directory: 'ports/puppeteer/25.6.0' };
fs.writeFileSync('packages/browsers/package.json', JSON.stringify(browsers, null, 2) + '\n');
console.log('  ✓ browsers/package.json (3.2.0-beta.0)');
"

# 5. Add OhosLauncher.ts (new source file)
echo "[build] adding OhosLauncher.ts..."
cp ../files/OhosLauncher.ts packages/puppeteer-core/src/node/OhosLauncher.ts

# 6. Post-patch sed fixes for TypeScript compilation
echo "[build] applying TypeScript compilation fixes..."

# 6a. BrowserLauncher.ts: process.platform === 'openharmony' → (process.platform as string) === 'openharmony'
sed -i "s/process\.platform === 'openharmony'/(process.platform as string) === 'openharmony'/" \
  packages/puppeteer-core/src/node/BrowserLauncher.ts

# 6b. OhosLauncher.ts: no sed fixes needed (new version is TS-safe)

# 6c. Update import references in puppeteer/src/*.ts: 'puppeteer-core' → '@ohos-ports/puppeteer-core'
find packages/puppeteer/src -name "*.ts" -exec sed -i "s/from 'puppeteer-core/from '@ohos-ports\/puppeteer-core/g" {} +
find packages/puppeteer/src -name "*.ts" -exec sed -i 's/from "puppeteer-core/from "@ohos-ports\/puppeteer-core/g' {} +

# 6d. Update import references: '@puppeteer/browsers' → '@ohos-ports/puppeteer-browsers'
#     Covers both static imports (from '...') and dynamic imports (import('...'))
find packages -name "*.ts" -exec sed -i "s/from '@puppeteer\/browsers/from '@ohos-ports\/puppeteer-browsers/g" {} +
find packages -name "*.ts" -exec sed -i 's/from "@puppeteer\/browsers/from "@ohos-ports\/puppeteer-browsers/g' {} +
find packages -name "*.ts" -exec sed -i "s/import('@puppeteer\/browsers')/import('@ohos-ports\/puppeteer-browsers')/g" {} +
find packages -name "*.ts" -exec sed -i 's/import("@puppeteer\/browsers")/import("@ohos-ports\/puppeteer-browsers")/g' {} +

# 6e. Fix string literal references to '@puppeteer/browsers' in non-import code
sed -i "s/'@puppeteer\/browsers'/'@ohos-ports\/puppeteer-browsers'/g" packages/browsers/src/CLI.ts

# 7. Wireit config fixes for OpenHarmony
echo "[build] fixing wireit configs for OpenHarmony..."

# 7a. Remove eslint from build:types (unrs-resolver has no openharmony native binding)
sed -i 's/api-extractor run --local && eslint --fix lib\/types.d.ts --no-ignore/api-extractor run --local/' \
  packages/puppeteer-core/package.json \
  packages/puppeteer/package.json

# 7b. Remove build:es5 from puppeteer-core build deps (rollup native binding unavailable)
node -e "
const fs = require('fs');
const f = 'packages/puppeteer-core/package.json';
const p = JSON.parse(fs.readFileSync(f, 'utf8'));
p.wireit.build.dependencies = p.wireit.build.dependencies.filter(d => d !== 'build:es5');
fs.writeFileSync(f, JSON.stringify(p, null, 2) + '\n');
"

# 8. Install dependencies
echo "[build] installing dependencies..."
npm install --ignore-scripts

# 9. Delete stale .tsbuildinfo (wireit incremental build cache)
echo "[build] cleaning .tsbuildinfo cache..."
find . -name "*.tsbuildinfo" -not -path "*/node_modules/*" -delete

# 10. Build — only puppeteer workspace (avoids test:build failure)
echo "[build] building..."
export PATH="$(pwd)/node_modules/.bin:$PATH"
npm run build --workspace packages/puppeteer

# 11. Verify build output
echo "[build] verifying..."
test -f packages/puppeteer/lib/puppeteer/puppeteer.js || { echo "ERROR: puppeteer.js not found" >&2; exit 1; }
test -f packages/puppeteer-core/lib/puppeteer/node/BrowserLauncher.js || { echo "ERROR: BrowserLauncher.js not found" >&2; exit 1; }
test -f packages/puppeteer-core/lib/puppeteer/node/OhosLauncher.js || { echo "ERROR: OhosLauncher.js not found" >&2; exit 1; }
test -f packages/browsers/lib/detectPlatform.js || { echo "ERROR: detectPlatform.js not found" >&2; exit 1; }

# Verify all 3 package names
NAME1=$(node -e "console.log(require('./packages/puppeteer/package.json').name)")
[ "$NAME1" = "@ohos-ports/puppeteer" ] || { echo "ERROR: puppeteer name is $NAME1" >&2; exit 1; }

NAME2=$(node -e "console.log(require('./packages/puppeteer-core/package.json').name)")
[ "$NAME2" = "@ohos-ports/puppeteer-core" ] || { echo "ERROR: puppeteer-core name is $NAME2" >&2; exit 1; }

NAME3=$(node -e "console.log(require('./packages/browsers/package.json').name)")
[ "$NAME3" = "@ohos-ports/puppeteer-browsers" ] || { echo "ERROR: browsers name is $NAME3" >&2; exit 1; }

# Verify patches applied (in compiled .js output)
grep -q "openharmony" packages/puppeteer-core/lib/puppeteer/node/BrowserLauncher.js || { echo "ERROR: openharmony check not found" >&2; exit 1; }
grep -q "launchViaOhos" packages/puppeteer-core/lib/puppeteer/node/BrowserLauncher.js || { echo "ERROR: launchViaOhos not found" >&2; exit 1; }
grep -q "Math.round" packages/puppeteer-core/lib/puppeteer/api/ElementHandle.js || { echo "ERROR: Math.round not found" >&2; exit 1; }
grep -q "openharmony" packages/browsers/lib/detectPlatform.js || { echo "ERROR: detectPlatform openharmony not found" >&2; exit 1; }

# Verify postinstall removed
POSTINSTALL=$(node -e "console.log(require('./packages/puppeteer/package.json').postinstall || '')")
[ -z "$POSTINSTALL" ] || { echo "ERROR: postinstall should be empty, got: $POSTINSTALL" >&2; exit 1; }

# Verify import references updated
grep -q "@ohos-ports/puppeteer-core" packages/puppeteer/lib/puppeteer/puppeteer.js || { echo "ERROR: puppeteer.js still imports puppeteer-core" >&2; exit 1; }

# 12. Smoke test: import check
node --input-type=module -e "
import puppeteer from './packages/puppeteer/lib/puppeteer/puppeteer.js';
if (typeof puppeteer.launch !== 'function') throw new Error('launch is not a function');
console.log('import OK, launch type:', typeof puppeteer.launch);
" || { echo "ERROR: import test failed" >&2; exit 1; }

# 13. Pack 3 tgz files
echo "[build] packing tgz files..."
cd packages/puppeteer && npm pack && cd ../..
cd packages/puppeteer-core && npm pack && cd ../..
cd packages/browsers && npm pack && cd ../..

echo ""
echo "[build] done. Output:"
ls -la packages/puppeteer/*.tgz packages/puppeteer-core/*.tgz packages/browsers/*.tgz
