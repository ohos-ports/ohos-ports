#!/bin/sh
set -e

# No native compile step: this port patches the official playwright-core
# tarball with frozen static patches (patchs/), same layout as every other
# port here. The patches are the consolidated output of the playwright-ohos
# patch engine at pzf0000/playwright-ohos@545e23e176fe94ec7aa7ae28a9a78cab29edbe3a
# run against upstream 1.60.0 (adaptation logic ISC-licensed; author and full
# license text are carried in files/ohos-launcher.cjs's header). To refresh
# for a newer upstream version or a newer playwright-ohos commit, re-run that
# engine on the extracted upstream package and regenerate the diffs against
# the pristine tarball — build.sh itself never fetches it at build time.

VERSION=1.63.0-alpha-2026-08-05
PKG=playwright-core

curl -fsSL "https://registry.npmjs.org/${PKG}/-/playwright-core-${VERSION}.tgz" -o core.tgz
tar -zxf core.tgz
rm core.tgz
mv package "${PKG}-${VERSION}"

cd "${PKG}-${VERSION}"

# The launcher ships as plain readable source maintained in this port (only
# node builtins, no bundler needed); the patched lib/coreBundle.js reaches it
# through require("./ohos-launcher.cjs"), injected by patch 0002.
cp ../files/ohos-launcher.cjs lib/ohos-launcher.cjs

patch -p1 < ../patchs/0001-update-package-json.patch
patch -p1 < ../patchs/0002-openharmony-core-bundle.patch

# --- verify package contents ---

NAME=$(node -e "console.log(require('./package.json').name)")
[ "$NAME" = "@ohos-ports/playwright-core" ]

for f in lib/coreBundle.js lib/ohos-launcher.cjs; do
  node --check "$f"
done

# The patched bundle must route OHOS work through the baked-in launcher.
grep -q 'require("./ohos-launcher.cjs")' lib/coreBundle.js
grep -q 'process.platform === "openharmony"' lib/coreBundle.js
grep -c '@playwright-ohos-patched' lib/coreBundle.js >/dev/null

# Alias-install safety guard: a bare require("playwright-core") inside the
# launcher would break under npm alias overrides
# (playwright-core -> npm:@ohos-ports/playwright-core); the launcher only
# uses node builtins by design — keep it that way.
if grep -qE 'require\((["'\''])playwright-core\1\)' lib/ohos-launcher.cjs; then
  echo "bare playwright-core require found in launcher" >&2
  exit 1
fi

# Real load test of the patched module graph through a consumer-like
# node_modules layout (an npm alias
# `playwright-core@npm:@ohos-ports/playwright-core` creates exactly this
# shape), covering both entry points.
SMOKE_DIR="$PWD/../.smoke"
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR/node_modules"
ln -s "$PWD" "$SMOKE_DIR/node_modules/playwright-core"
(
  cd "$SMOKE_DIR"
  node -e '
    const core = require("playwright-core");
    const names = [core.chromium, core.firefox, core.webkit].map(type => type.name());
    console.log("playwright-core loads:", names.join(", "));
    // coreBundle destructures hdcScreenshot / launchViaHdc / ohosInitScript
    // from the launcher (ohosInitScript is the init-script source string);
    // the rest of the export set is asserted to catch launcher drift.
    const ohos = require(process.cwd() + "/node_modules/playwright-core/lib/ohos-launcher.cjs");
    const expected = {
      launchViaHdc: "function",
      ohosInitScript: "string",
      hdcScreenshot: "function",
      HdcBackend: "function",
      resolveLaunchConfig: "function",
    };
    for (const [name, type] of Object.entries(expected)) {
      if (typeof ohos[name] !== type) {
        throw new Error(`ohos launcher export ${name} is not a ${type}`);
      }
    }
    console.log("ohos launcher loads");
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

# Confirm npm will actually ship the launcher (it is an added file, not part
# of any patch).
(
  cd .
  node -e '
    const { execFileSync } = require("child_process");
    const out = JSON.parse(execFileSync("npm", ["pack", "--dry-run", "--json"], { encoding: "utf8" }))[0];
    if (!out.files.some((entry) => entry.path === "lib/ohos-launcher.cjs")) {
      throw new Error("lib/ohos-launcher.cjs would not be published");
    }
    console.log("launcher is in the published file list");
  '
)

echo "==> done: $PKG-$VERSION"
