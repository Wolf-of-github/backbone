// index.js
// Purpose: dashboard-api service entrypoint (Phase 7).
// depends_on: [src/auth.js, src/k8s.js, src/routes/*, services/common/metrics.js]
//
// BOOT ORDER IS A SECURITY PROPERTY
// require('./auth') reads and validates the JWT public key at module load and
// THROWS if it is missing or malformed. That happens before any listener is
// bound, so the failure mode is a pod that never serves (CrashLoopBackOff)
// rather than an admin API answering without verification. See issues.txt
// SEC-1 for why that distinction matters here specifically.

const express = require('express');

const { instrumentHttp } = require('./common/metrics');
// Deliberately NOT wrapped in try/catch - an unhandled throw here is the
// intended behaviour. Catching it would reintroduce exactly the fail-open
// behaviour this service exists to avoid.
const { requireAdmin, PUBLIC_KEY_PATH } = require('./auth');
const { WatchManager } = require('./k8s');
const { router: readRouter, streamRoute } = require('./routes/read');
const { logsRoute } = require('./routes/logs');
const actionsRouter = require('./routes/actions');

const app = express();
const PORT = process.env.PORT || 3000;

instrumentHttp(app, { serviceName: 'dashboard-api' });
app.use(express.json());

// One WatchManager shared across all clients. N browsers watching the same
// pods should cost the API server one watch, not N.
const watchManager = new WatchManager();
watchManager.start();

// Liveness/readiness. Unauthenticated by necessity - the kubelet presents no
// token - so it exposes only whether watches are established, never cluster
// content.
app.get('/healthz', (req, res) => {
  const status = watchManager.status();
  const anyActive = Object.values(status).some((s) => s.active);

  // Not ready until at least one watch is up: a dashboard that cannot see the
  // cluster has nothing to serve, and failing readiness keeps it out of the
  // Service until it does.
  res.status(anyActive ? 200 : 503).json({
    status: anyActive ? 'ok' : 'starting',
    watches: status,
  });
});

// --- everything below is admin-only ----------------------------------------
// requireAdmin is applied to the whole mount rather than per route, so a route
// added later cannot be published unprotected by forgetting the middleware.
app.use('/api/cluster', requireAdmin);

app.use('/api/cluster', readRouter);
app.get('/api/cluster/stream', streamRoute(watchManager));
app.get('/api/cluster/logs/:namespace/:pod', logsRoute);
app.use('/api/cluster', actionsRouter);

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error(JSON.stringify({
    level: 'error', msg: 'unhandled error', error: err.message, path: req.originalUrl,
  }));
  res.status(500).json({ error: 'Internal server error' });
});

const server = app.listen(PORT, () => {
  console.log(JSON.stringify({
    level: 'info',
    msg: 'dashboard-api listening',
    port: PORT,
    jwtKey: PUBLIC_KEY_PATH,
  }));
});

// SSE connections are long-lived by design, so the default shutdown - wait for
// all responses to finish - would hang until the grace period expires and the
// pod was SIGKILLed. Stopping the watches first ends the streams, which lets
// those responses complete.
function shutdown(signal) {
  console.log(JSON.stringify({ level: 'info', msg: 'shutting down', signal }));
  watchManager.stop();
  server.close(() => process.exit(0));
  // Backstop: if a connection still will not close, exit before the kubelet
  // escalates to SIGKILL so the shutdown stays in the logs as deliberate.
  setTimeout(() => process.exit(0), 10000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
