#!/bin/sh
set -e

# Builds the @ohos-ports/playwright-core 1.62.1 artifact: downloads the
# upstream playwright source from GitHub, applies the HarmonyOS patches in
# ./patchs/ to the playwright-core sources, rebuilds playwright-core and
# repackages it under the @ohos-ports scope. The version is kept identical
# to the upstream playwright-core release so that npm alias overrides and
# version ranges resolve correctly.

VERSION=1.62.1

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

SOURCE="playwright-$VERSION"
ARTIFACT="playwright-core-$VERSION"

# --- stage 1: fetch and patch the upstream source ---

echo "==> downloading playwright $VERSION source"
curl -fsSL --retry 5 --retry-delay 2 \
  "https://github.com/microsoft/playwright/archive/refs/tags/v${VERSION}.zip" \
  -o "$SOURCE.zip"

# GitHub source archives extract to playwright-<version>/.
rm -rf "$SOURCE"
if ! command -v unzip >/dev/null; then
  # The dockerharmony image does not always ship unzip; get it from
  # harmonybrew (setup-tools.sh already configured the tap).
  brew install -y unzip
fi
unzip -q "$SOURCE.zip"
rm "$SOURCE.zip"
cd "$SOURCE"

echo "==> applying patches"
for patch in ../patchs/*.patch; do
  echo "patch -p1 < $(basename "$patch")"
  patch -p1 < "$patch"
done

# --- stage 2: install dependencies and build playwright-core ---

# The browser downloader and electron binary download are irrelevant for the
# playwright-core build and do not work on openharmony; skip them.
echo "==> installing build dependencies"
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 PLAYWRIGHT_SKIP_BROWSER_GC=1 \
  ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm ci --no-audit --no-fund

# PW_OHOS_CORE_ONLY skips the vite builds of the web packages
# (html-reporter, trace-viewer, dashboard, ...), which ship with the
# `playwright` package, not with playwright-core, and would require the
# vite/rolldown native toolchain on openharmony.
echo "==> building playwright-core"
PW_OHOS_CORE_ONLY=1 node utils/build/build.js

test -f packages/playwright-core/lib/coreBundle.js
test -f packages/playwright-core/lib/ohos/index.js
# The patched protocol spec must reach the bundle: the harmony launch options
# are validated against the generated scheme at runtime.
grep -q "harmonyBundleName" packages/playwright-core/lib/coreBundle.js

# The ohos entry re-exports playwright-core through the bare specifier (it is
# the only form the source-level import can take); rewrite it to a relative
# path so the entry resolves to this package itself under any install layout
# (npm alias override or direct @ohos-ports install).
echo "==> rewriting the ohos entry to a self-contained require"
OHOS_ENTRY="packages/playwright-core/lib/ohos/index.js"
sed -i 's|require("playwright-core")|require("../../index.js")|g' "$OHOS_ENTRY"
grep -q 'require("../../index.js")' "$OHOS_ENTRY"

# --- stage 3: package the renamed playwright-core ---

echo "==> packaging $ARTIFACT"
cd packages/playwright-core
npm pack --ignore-scripts > /dev/null
cd ../..
rm -rf "$ARTIFACT"
mkdir -p "$ARTIFACT"
tar -zxf "packages/playwright-core/playwright-core-$VERSION.tgz" -C "$ARTIFACT" --strip-components=1
rm "packages/playwright-core/playwright-core-$VERSION.tgz"

# The source keeps the upstream package name so that `npm ci` stays in sync
# with the workspace lockfile; the artifact is renamed here.
sed -i 's|"name": "playwright-core"|"name": "@ohos-ports/playwright-core"|' "$ARTIFACT/package.json"

# --- stage 4: verify the artifact loads like an installed playwright-core ---

NAME=$(node -e "console.log(require('./$ARTIFACT/package.json').name)")
[ "$NAME" = "@ohos-ports/playwright-core" ]
[ "$(node -e "console.log(require('./$ARTIFACT/package.json').version)")" = "$VERSION" ]
[ -f "$ARTIFACT/LICENSE" ]
[ -f "$ARTIFACT/lib/ohos/playwright-ohos.LICENSE" ]

# Load the artifact through a consumer-like node_modules layout (an npm
# alias `playwright-core@npm:@ohos-ports/playwright-core` creates exactly
# this shape). This is a real load test of the patched module graph, not a
# static check.
SMOKE_DIR="$PWD/.smoke"
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR/node_modules"
ln -s "$PWD/$ARTIFACT" "$SMOKE_DIR/node_modules/playwright-core"
(
  cd "$SMOKE_DIR"
  node -e '
    const core = require("playwright-core");
    const names = [core.chromium, core.firefox, core.webkit].map(type => type.name());
    console.log("playwright-core loads:", names.join(", "));
    const ohos = require("playwright-core/lib/ohos");
    for (const name of ["launchViaHdc", "HdcBackend", "takeScreenshot"]) {
      if (typeof ohos[name] !== "function") {
        throw new Error("ohos runtime entry misses " + name);
      }
    }
    if (typeof ohos.chromium !== "object") {
      throw new Error("ohos runtime entry does not re-export playwright-core");
    }
    console.log("ohos runtime entry loads");
  '
  node --input-type=module -e '
    import pw, { chromium } from "playwright-core";
    if (pw.chromium.name() !== "chromium" || chromium.name() !== "chromium") {
      throw new Error("esm entry does not export the browser types");
    }
    console.log("playwright-core esm loads");
  '
)
rm -rf "$SMOKE_DIR"

echo "==> done: $ARTIFACT"
