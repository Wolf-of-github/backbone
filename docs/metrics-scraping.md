# Metrics scraping convention

How a backbone service gets onto the Prometheus dashboard. Phase 5B.

Prometheus discovers targets by **pod annotation**, not by a hand-maintained
list of scrape targets. A service that follows the three steps below is scraped
within one interval of rolling out, on any node, with no change to the
Prometheus config.

## 1. Instrument the service

Express services (`ping`, `auth`, `jobs-api`):

```javascript
const { instrumentHttp } = require('./common/metrics');

const app = express();
instrumentHttp(app, { serviceName: 'jobs-api' });  // BEFORE mounting routes
```

Non-HTTP services (`worker`):

```javascript
const { startMetricsServer, trackQueueDepth } = require('./common/metrics');

startMetricsServer({ port: 3000, healthCheck: () => worker.isRunning() });
const stopTracking = trackQueueDepth(queue, { queueName: 'jobs' });
```

`instrumentHttp` must be registered before your routes, or the middleware never
sees the requests it is meant to time.

## 2. Add the dependency

```json
"dependencies": { "prom-client": "^15.1.3" }
```

## 3. Annotate the pod template

In the Deployment's `spec.template.metadata`:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "3000"
  prometheus.io/path: "/metrics"
```

These go on the **pod template**, not on the Deployment or the Service —
Prometheus discovers pods here, and an annotation one level up is silently
ignored. This is the most common reason a new service never appears.

## Verifying

```bash
kubectl -n observability port-forward svc/prometheus 9090:9090
# then open http://localhost:9090/targets - the pod should be listed UP
```

If it is missing: check the annotations are on the pod template
(`kubectl -n app get pod <pod> -o jsonpath='{.metadata.annotations}'`), and that
`/metrics` answers from inside the cluster.

## Metric naming

Everything is prefixed `backbone_`. Shared metrics live in
`services/common/metrics.js` so a panel written against one service works for
all of them — add new shared metrics there rather than defining service-local
names.

**Never put an unbounded value in a label.** Job ids, user ids, and raw request
paths each create one time series per distinct value and will eventually take
Prometheus down. `instrumentHttp` already collapses routes to their template
(`/api/jobs/:id`) for this reason.
