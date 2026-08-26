#!/bin/sh
set -e

# Publish @ohos-ports/mermaid-cli
#
# Beta release: --tag beta
# Stable release: change to --tag latest

cd mermaid-cli-11.16.0

echo "[publish] @ohos-ports/mermaid-cli..."
npm publish --provenance --tag beta --access public

echo "[publish] done."
echo ""
echo "Install beta:  npm install @ohos-ports/mermaid-cli@beta"
echo "Install exact: npm install @ohos-ports/mermaid-cli@11.16.0-beta.0"
