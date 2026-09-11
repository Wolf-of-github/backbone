// metrics.js
// Purpose: Shared Prometheus instrumentation for every backbone service
// Depends on: prom-client; optionally services/common/queue.js for queue depth
//
// Two entry points:
//   instrumentHttp(app, opts)  - Express services (ping, auth, jobs-api)
//   startMetricsServer(opts)   - the worker, which has no Express app
//
// Both expose GET /metrics. Prometheus finds them via the pod annotations
// documented in docs/metrics-scraping.md - the scrape config is annotation
// driven, so a service that adds these lines is discovered automatically.

const client = require('prom-client');

const register = new client.Registry();

// Process-level metrics (CPU, heap, event-loop lag, open handles).
client.collectDefaultMetrics({ register, prefix: 'backbone_' });

// --- HTTP -------------------------------------------------------------------

const httpDuration = new client.Histogram({
  name: 'backbone_http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status', 'service'],
  // Tuned for this platform: sub-100ms for local reads, a long tail for
  // anything that touches Mongo. Default buckets waste cardinality up at 10s.
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

const httpTotal = new client.Counter({
  name: 'backbone_http_requests_total',
  help: 'Total HTTP requests',
  labelNames: ['method', 'route', 'status', 'service'],
  registers: [register],
});

// --- Async jobs (worker + jobs-api) -----------------------------------------

const queueDepth = new client.Gauge({
  name: 'backbone_queue_depth',
  help: 'Jobs in the queue by state',
  labelNames: ['queue', 'state'],
  registers: [register],
});

const jobsProcessed = new client.Counter({
  name: 'backbone_jobs_processed_total',
  help: 'Jobs processed successfully',
  labelNames: ['type'],
  registers: [register],
});

const jobsFailed = new client.Counter({
  name: 'backbone_jobs_failed_total',
  help: 'Jobs that exhausted their retries and failed',
  labelNames: ['type'],
  registers: [register],
});

const jobDuration = new client.Histogram({
  name: 'backbone_job_duration_seconds',
  help: 'Job handler execution time in seconds',
  labelNames: ['type'],
  buckets: [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 300],
  registers: [register],
});

/**
 * Attach request timing and a /metrics endpoint to an Express app.
 * Call BEFORE mounting routes so the middleware sees every request.
 *
 * @param {object} app     Express application
 * @param {object} opts    { serviceName }
 */
function instrumentHttp(app, opts = {}) {
  const serviceName = opts.serviceName || process.env.SERVICE_NAME || 'unknown';

  app.use((req, res, next) => {
    const end = httpDuration.startTimer();
    res.on('finish', () => {
      // req.route?.path collapses /api/jobs/:id to the template rather than
      // emitting one time series per job id - unbounded label cardinality is
      // the classic way to take Prometheus down.
      const route = (req.route && req.route.path) || req.baseUrl || 'unmatched';
      const labels = {
        method: req.method,
        route,
        status: res.statusCode,
        service: serviceName,
      };
      end(labels);
      httpTotal.inc(labels);
    });
    next();
  });

  app.get('/metrics', async (_req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  });
}

/**
 * Stand up a bare /metrics HTTP server for services with no Express app
 * (the worker). Also serves /healthz so the liveness probe has a target.
 *
 * @param {object} opts  { port, healthCheck }
 * @returns {http.Server}
 */
function startMetricsServer(opts = {}) {
  const http = require('http');
  const port = opts.port || parseInt(process.env.METRICS_PORT || '3000', 10);
  const healthCheck = opts.healthCheck || (() => true);

  const server = http.createServer(async (req, res) => {
    if (req.url === '/metrics') {
      res.setHeader('Content-Type', register.contentType);
      res.end(await register.metrics());
      return;
    }
    if (req.url === '/healthz') {
      const healthy = healthCheck();
      res.statusCode = healthy ? 200 : 503;
      res.setHeader('Content-Type', 'application/json');
      res.end(JSON.stringify({ status: healthy ? 'healthy' : 'unhealthy' }));
      return;
    }
    res.statusCode = 404;
    res.end();
  });

  server.listen(port, '0.0.0.0');
  return server;
}

/**
 * Poll a BullMQ queue and keep the depth gauge current.
 *
 * Polled rather than event-driven on purpose: queue depth is a level, not a
 * stream of edges, and a worker that missed an event would report a wrong
 * level indefinitely. Returns a stop function for graceful shutdown.
 *
 * @param {object} queue         BullMQ Queue (from services/common/queue.js)
 * @param {object} opts          { intervalMs, queueName }
 * @returns {function} stop
 */
function trackQueueDepth(queue, opts = {}) {
  const intervalMs = opts.intervalMs || 15000;
  const queueName = opts.queueName || queue.name || 'jobs';

  const poll = async () => {
    try {
      const counts = await queue.getJobCounts('waiting', 'active', 'delayed', 'failed');
      for (const [state, count] of Object.entries(counts)) {
        queueDepth.set({ queue: queueName, state }, count);
      }
    } catch (err) {
      // Never let instrumentation take the service down - a Redis blip should
      // cost a stale gauge, not a crashed worker.
      console.error(JSON.stringify({
        level: 'warn',
        msg: 'queue depth poll failed',
        error: err.message,
      }));
    }
  };

  poll();
  const timer = setInterval(poll, intervalMs);
  timer.unref();
  return () => clearInterval(timer);
}

module.exports = {
  register,
  instrumentHttp,
  startMetricsServer,
  trackQueueDepth,
  jobsProcessed,
  jobsFailed,
  jobDuration,
  queueDepth,
};
