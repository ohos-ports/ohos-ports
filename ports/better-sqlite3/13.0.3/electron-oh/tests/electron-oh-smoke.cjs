'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const smoke = require('./database-smoke.cjs');

// Call from the Electron main process after app.whenReady(), not from Node.
module.exports = async function electronSmoke(packageDir, nativeBinding) {
  assert.equal(process.platform, 'openharmony');
  assert.equal(process.arch, 'arm64');
  assert.equal(process.versions.electron, '37.2.0');
  assert.equal(process.versions.node, '22.17.0');
  assert.ok(Number(process.versions.napi) >= 10);
  const manifest = JSON.parse(fs.readFileSync(path.join(packageDir,
    'prebuilds/electron-oh/37.2.0/openharmony-arm64/manifest.json'), 'utf8'));
  const digest = crypto.createHash('sha256').update(fs.readFileSync(nativeBinding)).digest('hex');
  assert.equal(digest, manifest.binary.sha256, 'test the packaged binary, without post-manifest modifications');
  const result = await smoke(require(path.resolve(packageDir)), { nativeBinding });
  console.log(JSON.stringify({ ...result, host: 'electron-oh', versions: process.versions, binarySha256: digest }));
  return result;
};
