#!/bin/sh
set -e

# Zero-code-patch port: @playwright/mcp's runtime (cli.js/index.js, 7 files
# total) only ever does `require('playwright-core/lib/coreBundle')` — no
# process.platform checks, no postinstall. Whether it works on openharmony
# depends entirely on which playwright-core it resolves, so the only patch
# needed is pointing dependencies.playwright-core at the ohos-ports playwright-core
# port. dependencies.playwright (non -core) is left untouched: nothing in this
# package's own code ever requires it, so it's harmless dead weight either way.

VERSION=0.0.79
PKG=playwright-mcp

rm -rf "${PKG}-${VERSION}"
npm pack "@playwright/mcp@${VERSION}"
tar -zxf "${PKG}-${VERSION}.tgz"
rm "${PKG}-${VERSION}.tgz"
mv package "${PKG}-${VERSION}"

cd "${PKG}-${VERSION}"
patch -p1 < ../patchs/0001-update-package-json.patch

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/playwright-mcp" ]

DEP=$(node -e "console.log(require('./package.json').dependencies['playwright-core'])")
case "$DEP" in
  npm:@ohos-ports/playwright-core@*) ;;
  *) echo "playwright-core dependency not aliased to ohos-ports: $DEP"; exit 1 ;;
esac

node --check cli.js
node --check index.js

echo "package OK: $NAME, playwright-core -> $DEP"
