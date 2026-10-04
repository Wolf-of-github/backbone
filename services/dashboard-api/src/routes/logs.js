// logs.js
// Purpose: Stream a pod's logs to the browser over SSE.
// depends_on: [services/dashboard-api/src/k8s.js]
//
// SENSITIVITY
// Pod logs routinely contain access tokens, Mongo connection strings and
// request bodies. They are the most sensitive thing this service exposes - more
// so than the object state - which is why every route here is admin-gated
// rather than merely authenticated. Nothing in this file lowers that bar.

const { PassThrough } = require('stream');
const k8s = require('@kubernetes/client-node');
const { kc, coreApi } = require('../k8s');

const logApi = new k8s.Log(kc);

/**
 * GET /api/cluster/logs/:namespace/:pod?container=<name>&tail=<n>
 *
 * SSE rather than a chunked plain-text response so the browser uses the same
 * event plumbing as /stream, and so errors mid-stream can be delivered as a
 * typed event instead of a truncated body.
 */
async function logsRoute(req, res) {
  const { namespace, pod } = req.params;
  const tail = Math.min(parseInt(req.query.tail, 10) || 200, 2000);
  let container = req.query.container;

  // Resolve the container first. A multi-container pod with no container
  // specified is an error in kubectl and should be one here too - silently
  // picking the first container shows the wrong logs convincingly, which is
  // worse than a 400.
  try {
    const { body } = await coreApi.readNamespacedPod(pod, namespace);
    const names = (body.spec.containers || []).map((c) => c.name);

    if (!container) {
      if (names.length > 1) {
        return res.status(400).json({
          error: 'This pod has multiple containers - specify ?container=',
          containers: names,
        });
      }
      container = names[0];
    } else if (!names.includes(container)) {
      return res.status(404).json({ error: `No container '${container}' in this pod`, containers: names });
    }
  } catch (err) {
    const code = err.statusCode === 404 ? 404 : 502;
    return res.status(code).json({
      error: code === 404 ? 'Pod not found' : 'Could not inspect pod',
    });
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders();

  const stream = new PassThrough();
  let aborted = false;

  // Lines arrive in arbitrary chunk boundaries, so a buffer is needed to avoid
  // emitting half a line as an event.
  let buffer = '';
  stream.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    const lines = buffer.split('\n');
    buffer = lines.pop();   // keep the incomplete tail for the next chunk
    for (const line of lines) {
      try {
        res.write(`event: log\ndata: ${JSON.stringify({ line })}\n\n`);
      } catch (err) { /* client gone */ }
    }
  });

  let request;
  try {
    request = await logApi.log(namespace, pod, container, stream, {
      follow: true,
      tailLines: tail,
      pretty: false,
      timestamps: false,
    });
  } catch (err) {
    res.write(`event: error\ndata: ${JSON.stringify({ error: err.message })}\n\n`);
    return res.end();
  }

  const heartbeat = setInterval(() => {
    try {
      res.write(': ping\n\n');
    } catch (e) { /* client gone */ }
  }, 15000);

  // ABORTING THE UPSTREAM IS THE POINT. A follow:true log request stays open
  // against the API server indefinitely. If the browser leaves and this is not
  // aborted, that request - and its kubelet connection - leaks for the life of
  // the pod. Open a few log views, close them, and the API server accumulates
  // streams nobody is reading.
  const cleanup = () => {
    if (aborted) return;
    aborted = true;
    clearInterval(heartbeat);
    stream.destroy();
    if (request && request.abort) request.abort();
  };

  req.on('close', cleanup);
  req.on('error', cleanup);

  // A pod that is deleted mid-stream ends the log request. Say so rather than
  // leaving the pane frozen with no explanation.
  stream.on('end', () => {
    try {
      res.write(`event: end\ndata: ${JSON.stringify({ reason: 'log stream ended' })}\n\n`);
      res.end();
    } catch (e) { /* client gone */ }
    cleanup();
  });
}

module.exports = { logsRoute };
