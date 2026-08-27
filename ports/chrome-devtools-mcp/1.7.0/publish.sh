#!/bin/sh
set -e

cd chrome-devtools-mcp-1.7.0

# Publish @ohos-ports/chrome-devtools-mcp
# Single package (all dependencies are bundled, no external deps to publish)
#
# Beta release: --tag beta
# Stable release: change to --tag latest

echo "[publish] @ohos-ports/chrome-devtools-mcp..."
npm publish --provenance --tag beta --access public

echo "[publish] done."
echo ""
echo "Install beta:  npm install @ohos-ports/chrome-devtools-mcp@beta"
echo "Install exact: npm install @ohos-ports/chrome-devtools-mcp@1.7.0-beta.0"
