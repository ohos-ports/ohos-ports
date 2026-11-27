#!/bin/sh
set -e

# Shared build logic for @ohos-ports/playwright-core.
#
# Usage: build-common.sh <version>
#
# The playwright-ohos source commit is pinned in playwright-ohos-commit.txt
# next to this script and is shared by every version. Invoked from
# ports/playwright-core/<version>/ (the CI runs each version's build.sh with
# that directory as cwd) and produces the patched
# `playwright-core-<version>/` artifact there. It performs three stages:
#   1. Fetch the playwright-ohos source at the pinned commit (once per
#      commit; a marker file makes repeated runs a no-op) and adapt its
#      package.json for building instead of installing.
#   2. Pin the target playwright-core version in playwright-ohos and build
#      its dist bundles (dist/index.cjs and dist/patch.cjs).
#   3. Download the official playwright-core tarball, apply the
#      playwright-ohos patches with the freshly built patch engine, and bake
#      the runtime entry (dist/index.cjs) into the artifact.

VERSION=$1

if [ -z "$VERSION" ]; then
  echo "usage: build-common.sh <version>" >&2
  exit 1
fi

case "$VERSION" in
  *.*.*) ;;
  *)
    echo "build-common.sh: invalid version: $VERSION" >&2
    exit 1
    ;;
esac

if [ "$(basename "$PWD")" != "$VERSION" ]; then
  echo "build-common.sh: must run from ports/playwright-core/$VERSION" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OHOS_SRC="$SCRIPT_DIR/playwright-ohos"
OHOS_COMMIT_FILE="$OHOS_SRC/.ohos-ports-commit"
ARTIFACT="playwright-core-$VERSION"

# The playwright-ohos commit shared by all versions. Bump the id in the
# commit file to pick up new patches and compatibility fixes.
OHOS_COMMIT=$(tr -d '[:space:]' < "$SCRIPT_DIR/playwright-ohos-commit.txt")
case "$OHOS_COMMIT" in
  ''|*[!0-9a-fA-F]*)
    echo "build-common.sh: invalid playwright-ohos commit in playwright-ohos-commit.txt" >&2
    exit 1
    ;;
esac

# --- stage 1: playwright-ohos source (fetched once per commit) ---

if [ ! -f "$OHOS_COMMIT_FILE" ] || [ "$(cat "$OHOS_COMMIT_FILE")" != "$OHOS_COMMIT" ]; then
  echo "==> fetching playwright-ohos @ $OHOS_COMMIT"
  rm -rf "$OHOS_SRC"
  node "$SCRIPT_DIR/fetch.cjs" \
    "https://github.com/pzf0000/playwright-ohos/archive/$OHOS_COMMIT.tar.gz" \
    "$SCRIPT_DIR/playwright-ohos.tar.gz"
  tar -zxf "$SCRIPT_DIR/playwright-ohos.tar.gz" -C "$SCRIPT_DIR"
  rm "$SCRIPT_DIR/playwright-ohos.tar.gz"
  mv "$SCRIPT_DIR/playwright-ohos-$OHOS_COMMIT" "$OHOS_SRC"

  # Adapt the repository for building instead of installing: the postinstall
  # patch step and the prepare signpost would run against this checkout's own
  # node_modules during `npm install`, but patching here is done explicitly
  # on the playwright-core artifact in stage 3.
  node - "$OHOS_SRC/package.json" <<'NODE'
const fs = require('fs');
const pkgPath = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
pkg.scripts.prepare = '';
pkg.scripts.postinstall = '';
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
NODE

  # The external module regex in vite.config.ts is unanchored, so it also
  # matches the absolute path of this checkout itself (which lives under
  # ports/playwright-core/), making rollup reject the entry module as
  # external. Anchor it to node_modules so only the resolved playwright-core
  # dependency is treated as external.
  node - "$OHOS_SRC/vite.config.ts" <<'NODE'
const fs = require('fs');
const configPath = process.argv[2];
const config = fs.readFileSync(configPath, 'utf8');
const before = '/playwright-core\\/.*/';
const after = '/node_modules\\/playwright-core(?:\\/|$)/';
if (!config.includes(before)) {
  console.error(`build-common.sh: expected external pattern ${before} not found in vite.config.ts`);
  process.exit(1);
}
fs.writeFileSync(configPath, config.replace(before, after));
NODE

  printf '%s\n' "$OHOS_COMMIT" > "$OHOS_COMMIT_FILE"
else
  echo "==> playwright-ohos @ $OHOS_COMMIT already fetched"
fi

# --- stage 2: pin the target version and build playwright-ohos dist ---

echo "==> pinning playwright-core $VERSION in playwright-ohos"
node - "$OHOS_SRC/package.json" "$VERSION" <<'NODE'
const fs = require('fs');
const pkgPath = process.argv[2];
const version = process.argv[3];
const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
// The patch engine supports a range of playwright-core versions; the exact
// one to build against is selected here.
pkg.devDependencies['playwright-core'] = version;
for (const name of ['playwright', '@playwright/test']) {
  if (pkg.devDependencies[name] !== undefined) {
    pkg.devDependencies[name] = version;
  }
}
fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
NODE

(
  cd "$OHOS_SRC"
  echo "==> installing playwright-ohos build dependencies"
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 PLAYWRIGHT_SKIP_BROWSER_GC=1 \
    npm install --no-audit --no-fund

  # OpenHarmony refuses to load unsigned shared objects, and some upstream
  # builds of native addons ship without a code signature (or have their
  # postinstall gated by npm's allowScripts feature). Self-sign every addon
  # that fails to load; idempotent for already-signable ones.
  echo "==> ensuring native build-tool addons are loadable"
  node - "$OHOS_SRC/node_modules" <<'NODE'
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const nodeModules = process.argv[2];

const walk = (root) => {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || entry.name === 'node_modules') {
      continue;
    }
    const entryPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...walk(entryPath));
    } else if (entry.isFile() && entry.name.endsWith('.node')) {
      files.push(entryPath);
    }
  }
  return files;
};

for (const file of walk(nodeModules)) {
  try {
    require(file);
    continue;
  } catch (error) {
    if (!String(error.message).includes('Error loading shared library')) {
      continue;
    }
  }
  console.log(`signing ${path.relative(nodeModules, file)}`);
  const signed = `${file}.signed`;
  const result = spawnSync('binary-sign-tool', ['sign', '-selfSign', '1', '-inFile', file, '-outFile', signed], { encoding: 'utf8' });
  if (result.status !== 0) {
    console.error(`binary-sign-tool failed: ${result.stderr}`);
    process.exit(1);
  }
  fs.renameSync(signed, file);
  try {
    require(file);
  } catch (error) {
    console.error(`signing did not fix ${path.relative(nodeModules, file)}: ${error.message}`);
    process.exit(1);
  }
}
NODE

  echo "==> building playwright-ohos dist"
  npm run build
  test -f dist/index.cjs
  test -f dist/patch.cjs
)

# --- stage 3: fetch playwright-core and produce the patched artifact ---

echo "==> downloading playwright-core $VERSION"
node "$SCRIPT_DIR/fetch.cjs" \
  "https://registry.npmjs.org/playwright-core/-/playwright-core-$VERSION.tgz" \
  "$ARTIFACT.tgz"
rm -rf "$ARTIFACT"
mkdir -p "$ARTIFACT"
tar -zxf "$ARTIFACT.tgz" -C "$ARTIFACT" --strip-components=1
rm "$ARTIFACT.tgz"

echo "==> applying playwright-ohos patches to playwright-core $VERSION"
node "$SCRIPT_DIR/patch-playwright-core.cjs" "$ARTIFACT" "$OHOS_SRC/dist" "$VERSION"

# --- stage 4: verify the artifact loads like an installed playwright-core ---

NAME=$(node -e "console.log(require('./$ARTIFACT/package.json').name)")
[ "$NAME" = "@ohos-ports/playwright-core" ]

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
    const ohos = require(process.cwd() + "/node_modules/playwright-core/lib/ohos/index.cjs");
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
