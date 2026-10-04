// read.js
// Purpose: Snapshot, live SSE stream, and resource usage. Read-only.
// depends_on: [services/dashboard-api/src/k8s.js, src/auth.js]
//
// THE CLIENT CONTRACT
// A browser does exactly two things, in this order:
//   1. GET /snapshot  - full trimmed state + the resourceVersions it reflects
//   2. GET /stream    - deltas, applied to that state
// Doing it the other way round leaves a gap where changes are missed. The
// snapshot's resourceVersions are what the watches resume from, which is what
// closes that gap (see the watch contract in k8s.js).
//
// On a `resync` event the browser must re-fetch /snapshot: a 410 means the
// server could not guarantee continuity, and applying later deltas to stale
// state would leave the UI quietly wrong. A visible reload beats silent drift.

const express = require('express');
const { snapshot, usage } = require('../k8s');

const router = express.Router();

/**
 * GET /api/cluster/snapshot
 */
router.get('/snapshot', async (req, res) => {
  try {
    res.json(await snapshot());
  } catch (err) {
    console.error(JSON.stringify({
      level: 'error', msg: 'snapshot failed', error: err.message,
    }));
    res.status(502).json({ error: 'Could not read cluster state' });
  }
});

/**
 * GET /api/cluster/metrics
 *
 * Separate from /snapshot because it is polled on its own cadence: usage
 * changes continuously, while object state changes in discrete events. Folding
 * it into the snapshot would force a full re-fetch just to refresh a CPU
 * number.
 */
router.get('/metrics', async (req, res) => {
  try {
    res.json(await usage());
  } catch (err) {
    res.status(502).json({ error: 'Could not read metrics' });
  }
});

/**
 * GET /api/cluster/stream  - Server-Sent Events
 *
 * Mounted by index.js with the shared WatchManager injected, so every client
 * fans out from the same set of watches rather than opening its own.
 */
function streamRoute(watchManager) {
  return function stream(req, res) {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      // Kong and nginx both buffer proxied responses by default, which would
      // hold events until the buffer fills - the stream appears to work and
      // then delivers nothing. This header is the documented opt-out and is
      // honoured by both.
      'X-Accel-Buffering': 'no',
    });

    // Flush the headers immediately. Without this the browser's EventSource /
    // fetch reader does not resolve until the first event arrives, which on an
    // idle cluster could be minutes.
    res.flushHeaders();

    const send = (event, data) => {
      // Write failures mean the client is gone; the close handler will clean
      // up, so there is nothing useful to do with the error here.
      try {
        res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
      } catch (err) { /* client gone */ }
    };

    send('hello', { watches: watchManager.status() });

    const onEvent = (e) => send('change', e);
    const onResync = (e) => send('resync', e);

    watchManager.on('event', onEvent);
    watchManager.on('resync', onResync);

    // Comment-only lines are valid SSE and are ignored by clients. They exist
    // to keep intermediaries from reaping a connection that has been idle -
    // Kong's default read timeout would otherwise close a quiet stream and the
    // UI would stop updating with no visible error.
    const heartbeat = setInterval(() => {
      try {
        res.write(': ping\n\n');
      } catch (err) { /* client gone */ }
    }, 15000);

    // THE LEAK THIS PREVENTS: without removing these listeners, every
    // reconnect (a refresh, a laptop waking) adds two more to a long-lived
    // EventEmitter. Memory and per-event work climb until the pod is
    // OOMKilled, and because each individual connection looks fine, it
    // presents as a mysterious slow leak.
    const cleanup = () => {
      clearInterval(heartbeat);
      watchManager.removeListener('event', onEvent);
      watchManager.removeListener('resync', onResync);
    };

    req.on('close', cleanup);
    req.on('error', cleanup);
  };
}

module.exports = { router, streamRoute };
