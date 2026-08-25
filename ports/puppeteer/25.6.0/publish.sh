#!/bin/sh
set -e

cd puppeteer-25.6.0

# Publish all 3 packages in dependency order:
#   1. @ohos-ports/puppeteer-browsers (no deps on other ohos-ports packages)
#   2. @ohos-ports/puppeteer-core (depends on puppeteer-browsers)
#   3. @ohos-ports/puppeteer (depends on puppeteer-core + puppeteer-browsers)
#
# Beta release: --tag beta (npm install @ohos-ports/puppeteer@beta)
# Stable release: change to --tag latest

echo "[publish] @ohos-ports/puppeteer-browsers..."
cd packages/browsers
npm publish --provenance --tag beta --access public
cd ../..

echo "[publish] @ohos-ports/puppeteer-core..."
cd packages/puppeteer-core
npm publish --provenance --tag beta --access public
cd ../..

echo "[publish] @ohos-ports/puppeteer..."
cd packages/puppeteer
npm publish --provenance --tag beta --access public
cd ../..

echo "[publish] done."
echo ""
echo "Install beta:  npm install @ohos-ports/puppeteer@beta"
echo "Install exact: npm install @ohos-ports/puppeteer@25.6.0-beta.0"
