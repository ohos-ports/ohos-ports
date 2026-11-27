// Applies the playwright-ohos patches to an extracted playwright-core package
// and bakes the playwright-ohos runtime entry into it, producing the
// @ohos-ports/playwright-core artifact:
//   - runs the playwright-ohos patch engine over the package;
//   - copies dist/index.cjs (the runtime entry bundled from src/index.ts)
//     into lib/ohos/index.cjs;
//   - rewrites the build-time absolute path that the patches injected into
//     the patched files to a relative path, so the artifact works from any
//     install location;
//   - rewrites the runtime entry's bare playwright-core import to a relative
//     one, so it resolves to this package itself under npm alias overrides
//     (playwright-core -> npm:@ohos-ports/playwright-core);
//   - updates package.json (name, repository) and runs syntax checks.
//
// usage: node patch-playwright-core.cjs <package-root> <ohos-dist-dir> <version>

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const [packageRoot, ohosDistDir, version] = process.argv.slice(2);
if (!packageRoot || !ohosDistDir || !version) {
  console.error('usage: node patch-playwright-core.cjs <package-root> <ohos-dist-dir> <version>');
  process.exit(2);
}

const fail = (message) => {
  console.error(`patch-playwright-core: ${message}`);
  process.exit(1);
};

// Collects every .js file under the package root. The patched files all live
// under lib/ in both the bundle (1.60+) and the separate-file (1.51-1.59)
// layouts; walking the whole root also covers files added by future patches.
const walkJsFiles = (root) => {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const entryPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkJsFiles(entryPath));
    } else if (entry.isFile() && entry.name.endsWith('.js')) {
      files.push(entryPath);
    }
  }
  return files;
};

const packageJsonPath = path.join(packageRoot, 'package.json');
if (!fs.existsSync(packageJsonPath)) {
  fail(`not a package root: ${packageRoot}`);
}

// --- run the playwright-ohos patch engine over the extracted package ---

const patch = require(path.join(ohosDistDir, 'patch.cjs'));
const results = patch.applyPatches(packageRoot);
for (const result of results) {
  if (result.status !== 'skipped') {
    console.log(`patch ${result.id}: ${result.status}${result.count > 1 ? ` x${result.count}` : ''}`);
  }
}
const missing = results.filter(result => result.status === 'not-found');
if (missing.length > 0) {
  for (const result of missing) {
    console.error(`patch ${result.id} did not match any code, playwright-core ${version} may be unsupported`);
  }
  fail('patches did not apply cleanly');
}
if (!patch.checkSyntax(packageRoot)) {
  fail('syntax check failed after patching');
}

// --- bake the runtime entry (the src/index.ts bundle) into the package ---

const runtimeSource = path.join(ohosDistDir, 'index.cjs');
const runtimeTarget = path.join(packageRoot, 'lib', 'ohos', 'index.cjs');
if (!fs.existsSync(runtimeSource)) {
  fail(`runtime entry not found: ${runtimeSource}`);
}
fs.mkdirSync(path.dirname(runtimeTarget), { recursive: true });
let runtime = fs.readFileSync(runtimeSource, 'utf8');

// The runtime entry is playwright-ohos code; ship its license along with it.
const ohosLicense = path.join(path.dirname(ohosDistDir), 'LICENSE');
if (fs.existsSync(ohosLicense)) {
  fs.copyFileSync(ohosLicense, path.join(path.dirname(runtimeTarget), 'LICENSE'));
}

// The runtime entry must be a standalone bundle; a reference to a sibling
// chunk would break the copy above.
if (runtime.includes('require("./')) {
  fail('runtime entry requires a sibling chunk and cannot be baked in');
}

// Replace the bare playwright-core import with a relative one so it resolves
// to this package itself, even when consumers install it through an npm
// alias override or as a direct dependency under the @ohos-ports scope.
const coreRequirePattern = /require\((['"])playwright-core\1\)/;
if (!coreRequirePattern.test(runtime)) {
  fail('playwright-core require not found in the runtime entry');
}
runtime = runtime.replace(coreRequirePattern, 'require("../../index.js")');
fs.writeFileSync(runtimeTarget, runtime);

// --- rewrite the absolute runtime path injected by the patches ---

// OHOS_REQUIRE is the JSON-quoted absolute path of the runtime entry in the
// playwright-ohos checkout that built the patch engine; the patched files
// embed it literally. Point it at the baked-in copy instead, relative to
// each patched file.
const oldLiteral = patch.OHOS_REQUIRE;
let rewritten = 0;
for (const file of walkJsFiles(packageRoot)) {
  const source = fs.readFileSync(file, 'utf8');
  if (!source.includes(oldLiteral)) {
    continue;
  }
  const relative = path.relative(path.dirname(file), runtimeTarget);
  fs.writeFileSync(file, source.split(oldLiteral).join(JSON.stringify(relative)));
  rewritten += 1;
}
if (rewritten === 0) {
  fail('no patched file references the runtime entry');
}

// Verify the rewrite and the syntax of every touched file.
for (const file of walkJsFiles(packageRoot)) {
  const source = fs.readFileSync(file, 'utf8');
  if (source.includes(oldLiteral)) {
    fail(`runtime path rewrite incomplete in ${path.relative(packageRoot, file)}`);
  }
  if (source.includes('@playwright-ohos-patched') || file === runtimeTarget) {
    const result = spawnSync(process.execPath, ['--check', file], { encoding: 'utf8' });
    if (result.status !== 0) {
      fail(`syntax check failed for ${path.relative(packageRoot, file)}: ${result.stderr}`);
    }
  }
}

// --- update package.json: rename to @ohos-ports/playwright-core ---

const pkg = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'));
if (pkg.version !== version) {
  fail(`package version ${pkg.version} does not match the expected ${version}`);
}
pkg.name = '@ohos-ports/playwright-core';
// The version is intentionally kept identical to the upstream playwright-core
// release, so npm alias overrides and version ranges resolve correctly.
// Provenance publishing from the ohos-ports CI requires the repository field
// to point at this repository.
pkg.repository = {
  type: 'git',
  url: 'https://github.com/ohos-ports/ohos-ports',
};
pkg.bugs = {
  url: 'https://github.com/ohos-ports/ohos-ports/issues',
};
fs.writeFileSync(packageJsonPath, JSON.stringify(pkg, null, 2) + '\n');

console.log(`patch-playwright-core: patched playwright-core ${pkg.version} -> ${pkg.name}`);
