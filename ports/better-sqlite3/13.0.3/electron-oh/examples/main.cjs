'use strict';
const { app } = require('electron');
const path = require('node:path');
const Database = require('@ohos-ports/better-sqlite3');

app.whenReady().then(() => {
  if (process.platform !== 'openharmony' || process.arch !== 'arm64' ||
      process.versions.electron !== '37.2.0' || process.versions.node !== '22.17.0') {
    throw new Error('Use the pinned Electron-OH 37.2.0 runtime');
  }
  const db = new Database(path.join(app.getPath('userData'), 'example.db'), {
    nativeBinding: '/data/storage/el1/bundle/libs/arm64/better_sqlite3.node',
  });
  db.exec('CREATE TABLE IF NOT EXISTS items(id INTEGER PRIMARY KEY, name TEXT)');
  db.prepare('INSERT INTO items(name) VALUES(?)').run('HarmonyOS');
  console.log(db.prepare('SELECT * FROM items').all());
  app.on('before-quit', () => db.close());
});
