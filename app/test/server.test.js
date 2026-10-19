const { test } = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const path = require('node:path');

// Boot the real server on an ephemeral port so the test exercises the
// actual HTTP surface, not a mock. This is what makes the CI step meaningful:
// if the image would fail to start, we find out here and not in the cluster.
const PORT = 18080;
let child;

function get(pathname) {
  return fetch(`http://127.0.0.1:${PORT}${pathname}`).then(async (res) => ({
    status: res.status,
    body: await res.json(),
  }));
}

function waitForReady(proc, retries = 50) {
  return new Promise((resolve, reject) => {
    let done = false;
    proc.stdout.on('data', (buf) => {
      if (!done && buf.toString().includes('listening')) {
        done = true;
        resolve();
      }
    });
    proc.on('exit', (code) => {
      if (!done) reject(new Error(`server exited early with code ${code}`));
    });
    setTimeout(() => {
      if (!done) reject(new Error('server did not become ready in time'));
    }, retries * 100);
  });
}

test.before(async () => {
  child = spawn(process.execPath, [path.join(__dirname, '..', 'server.js')], {
    env: { ...process.env, PORT: String(PORT), APP_VERSION: 'test', ENV_NAME: 'ci' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await waitForReady(child);
});

test.after(() => {
  child?.kill('SIGTERM');
});

test('/healthz returns ok', async () => {
  const { status, body } = await get('/healthz');
  assert.strictEqual(status, 200);
  assert.strictEqual(body.status, 'ok');
});

test('/version echoes the injected version', async () => {
  const { status, body } = await get('/version');
  assert.strictEqual(status, 200);
  assert.strictEqual(body.version, 'test');
  assert.strictEqual(body.env, 'ci');
});

test('/ returns app metadata', async () => {
  const { status, body } = await get('/');
  assert.strictEqual(status, 200);
  assert.strictEqual(body.message, 'Hello from argoDemo');
  assert.ok(body.pod, 'pod identity should be present');
});

test('unknown path returns 404', async () => {
  const { status, body } = await get('/nope');
  assert.strictEqual(status, 404);
  assert.strictEqual(body.error, 'not found');
});
