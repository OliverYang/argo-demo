const http = require('node:http');

const PORT = process.env.PORT || 8080;
const VERSION = process.env.APP_VERSION || 'dev';
const ENV_NAME = process.env.ENV_NAME || 'local';
const STARTED_AT = new Date().toISOString();

const routes = {
  '/': () => ({
    statusCode: 200,
    body: {
      message: 'Hello from argoDemo',
      version: VERSION,
      env: ENV_NAME,
      pod: process.env.HOSTNAME || 'unknown',
    },
  }),
  // Kubernetes liveness/readiness probe target.
  '/healthz': () => ({ statusCode: 200, body: { status: 'ok' } }),
  // Used by CI smoke test and by Argo Rollouts analysis.
  '/version': () => ({
    statusCode: 200,
    body: { version: VERSION, env: ENV_NAME, startedAt: STARTED_AT },
  }),
};

const server = http.createServer((req, res) => {
  const path = req.url.split('?')[0];
  const handler = routes[path];

  if (!handler) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found', path }));
    return;
  }

  const { statusCode, body } = handler();
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
});

server.listen(PORT, () => {
  console.log(`listening on :${PORT} version=${VERSION} env=${ENV_NAME}`);
});

// Let the kubelet's SIGTERM trigger a clean shutdown.
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down');
  server.close(() => process.exit(0));
});
