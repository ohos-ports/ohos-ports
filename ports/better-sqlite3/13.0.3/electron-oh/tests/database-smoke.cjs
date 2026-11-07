'use strict';
const assert = require('node:assert/strict');

// Shared real database assertions for both hosts; no fs/async/IPC replacements.
module.exports = async function smoke(Database, options = {}) {
  const db = new Database(':memory:', options);
  try {
    db.exec('CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT UNIQUE)');
    const insert = db.prepare('INSERT INTO items (name) VALUES (?)');
    insert.run('first');
    assert.equal(db.prepare('SELECT name FROM items WHERE id = ?').get(1).name, 'first');
    assert.throws(() => insert.run('first'), { code: 'SQLITE_CONSTRAINT_UNIQUE' });
    assert.throws(db.transaction(() => { insert.run('rollback'); throw new Error('rollback'); }), /rollback/);
    assert.equal(db.prepare('SELECT count(*) AS n FROM items').get().n, 1);
    db.transaction(() => { insert.run('second'); insert.run('third'); })();
    assert.equal([...db.prepare('SELECT name FROM items ORDER BY id').iterate()].length, 3);
    db.function('double_value', n => n * 2);
    assert.equal(db.prepare('SELECT double_value(21) AS n').get().n, 42);
    db.aggregate('total_length', { start: 0, step: (n, text) => n + text.length });
    assert.equal(db.prepare('SELECT total_length(name) AS n FROM items').get().n, 16);
    assert.equal(db.prepare('SELECT 9007199254740993 AS n').safeIntegers().get().n, 9007199254740993n);
    const restored = new Database(db.serialize(), options);
    try { assert.equal(restored.prepare('SELECT count(*) AS n FROM items').get().n, 3); }
    finally { restored.close(); }
    assert.equal(db.pragma('integrity_check', { simple: true }), 'ok');
    return { status: 'passed', checks: 10, sqlite: db.prepare('SELECT sqlite_version() AS v').get().v };
  } finally {
    db.close();
    assert.equal(db.open, false);
  }
};
