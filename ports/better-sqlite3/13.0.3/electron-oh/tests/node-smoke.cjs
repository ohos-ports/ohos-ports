'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const smoke = require('./database-smoke.cjs');

assert.equal(process.platform, 'openharmony', 'run with the target OHOS Node runtime');
assert.equal(process.versions.electron, undefined, 'this test must use standalone Node');
const packageDir = path.resolve(process.argv[2] || '.');
// No nativeBinding option: exercise the original default Node prebuild loader.
smoke(require(packageDir)).then(result => {
  console.log(JSON.stringify({ ...result, host: 'node', versions: process.versions, platform: process.platform }));
}).catch(error => { console.error(error); process.exitCode = 1; });
