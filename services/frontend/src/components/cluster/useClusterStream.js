// useClusterStream.js
// Purpose: Live cluster state - snapshot + SSE deltas, as a React hook.
// depends_on: [dashboard-api /api/cluster/snapshot and /stream]
//
// WHY fetch + ReadableStream RATHER THAN EventSource
// EventSource cannot set request headers, so an admin-gated stream would have
// to carry the token in the query string - where it lands in Kong's access
// logs, gets shipped to Loki by Promtail, and sits in searchable storage for
// its whole lifetime (issues.txt SEC-2). fetch() takes an Authorization header
// normally. The cost is reconnection, which EventSource does for free and is
// hand-rolled below.
//
// THE ORDER MATTERS
//   1. GET /snapshot - full state + the resourceVersions it reflects
//   2. GET /stream   - deltas applied to that state
// Reversed, changes between the two are lost. On a `resync` event the server
// is telling us it could not guarantee continuity (a watch resourceVersion
// expired), so the only correct response is to re-fetch the snapshot - applying
// later deltas to stale state would leave the UI quietly wrong, which is worse
// than a visible reload.

import { useState, useEffect, useRef, useCallback } from 'react';

const RECONNECT_BASE_MS = 1000;
const RECONNECT_MAX_MS = 30000;

export function useClusterStream(authFetch) {
  const [state, setState] = useState({
    pods: [], nodes: [], deployments: [], events: [],
  });
  const [metrics, setMetrics] = useState({ pods: {}, nodes: {}, available: true });
  const [status, setStatus] = useState('connecting');  // connecting|live|reconnecting|error
  const [error, setError] = useState(null);

  // Refs rather than state: these are mutated by the stream loop and must not
  // retrigger the effect that owns the connection.
  const abortRef = useRef(null);
  const attemptRef = useRef(0);
  const mountedRef = useRef(true);

  /**
   * Apply one watch event. Keyed by uid, not name: a deleted-and-recreated pod
   * reuses its name but gets a new uid, and keying by name would merge the two
   * into one row that flickers between states.
   */
  const applyEvent = useCallback((resource, type, object) => {
    setState((prev) => {
      const list = prev[resource] || [];

      if (type === 'DELETED') {
        return { ...prev, [resource]: list.filter((o) => o.uid !== object.uid) };
      }

      const idx = list.findIndex((o) => o.uid === object.uid);
      if (idx === -1) {
        // Events are append-and-cap: unbounded growth would eventually make
        // the table unusable, and only recent ones are interesting.
        const next = resource === 'events' ? [object, ...list].slice(0, 100) : [...list, object];
        return { ...prev, [resource]: next };
      }

      const next = [...list];
      next[idx] = object;
      return { ...prev, [resource]: next };
    });
  }, []);

  const loadSnapshot = useCallback(async () => {
    const res = await authFetch('/api/cluster/snapshot');
    if (!res.ok) {
      // 403 is terminal - a non-admin will never succeed by retrying, so say
      // so rather than looping. 401 is handled inside authFetch (token
      // refresh), and anything else is worth a retry.
      const terminal = res.status === 403;
      const err = new Error(terminal
        ? 'Admin role required to view cluster state'
        : `Snapshot failed (HTTP ${res.status})`);
      err.terminal = terminal;
      throw err;
    }
    const snap = await res.json();
    setState({
      pods: snap.items.pods || [],
      nodes: snap.items.nodes || [],
      deployments: snap.items.deployments || [],
      events: snap.items.events || [],
    });
    return snap;
  }, [authFetch]);

  // --- the stream loop ------------------------------------------------------
  useEffect(() => {
    mountedRef.current = true;

    async function connect() {
      if (!mountedRef.current) return;

      const controller = new AbortController();
      abortRef.current = controller;

      try {
        setStatus(attemptRef.current === 0 ? 'connecting' : 'reconnecting');
        await loadSnapshot();

        const token = localStorage.getItem('accessToken');
        const res = await fetch('/api/cluster/stream', {
          headers: { Authorization: `Bearer ${token}` },
          signal: controller.signal,
        });

        if (!res.ok || !res.body) {
          throw new Error(`Stream failed (HTTP ${res.status})`);
        }

        setStatus('live');
        setError(null);
        attemptRef.current = 0;

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        // SSE frames are separated by a blank line and can span chunk
        // boundaries, so the tail of a partial frame is held over.
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;

          buffer += decoder.decode(value, { stream: true });
          const frames = buffer.split('\n\n');
          buffer = frames.pop();

          for (const frame of frames) {
            // Comment-only frames are the server's heartbeat - they exist to
            // keep Kong from reaping an idle connection and carry no data.
            if (!frame.trim() || frame.startsWith(':')) continue;

            let event = 'message';
            let data = '';
            for (const line of frame.split('\n')) {
              if (line.startsWith('event: ')) event = line.slice(7).trim();
              else if (line.startsWith('data: ')) data += line.slice(6);
            }
            if (!data) continue;

            let parsed;
            try {
              parsed = JSON.parse(data);
            } catch {
              continue;
            }

            if (event === 'change') {
              applyEvent(parsed.resource, parsed.type, parsed.object);
            } else if (event === 'resync') {
              // The server lost continuity. Re-snapshot rather than trusting
              // what we have.
              await loadSnapshot();
            }
          }
        }

        // A clean end means the server or an intermediary closed the stream;
        // reconnect rather than going quietly stale.
        throw new Error('stream closed');
      } catch (err) {
        if (controller.signal.aborted || !mountedRef.current) return;

        if (err.terminal) {
          setError(err.message);
          setStatus('error');
          return;   // no retry - retrying a 403 forever accomplishes nothing
        }

        attemptRef.current += 1;
        const delay = Math.min(
          RECONNECT_BASE_MS * 2 ** (attemptRef.current - 1),
          RECONNECT_MAX_MS
        );
        setStatus('reconnecting');
        setError(`${err.message} - retrying in ${Math.round(delay / 1000)}s`);
        setTimeout(connect, delay);
      }
    }

    connect();

    return () => {
      mountedRef.current = false;
      if (abortRef.current) abortRef.current.abort();
    };
  }, [loadSnapshot, applyEvent]);

  // --- metrics --------------------------------------------------------------
  // Polled, not streamed: usage changes continuously rather than in discrete
  // events, and the metrics API does not support watch.
  useEffect(() => {
    let cancelled = false;

    async function poll() {
      try {
        const res = await authFetch('/api/cluster/metrics');
        if (!cancelled && res.ok) setMetrics(await res.json());
      } catch { /* a missed metrics poll is not worth surfacing */ }
    }

    poll();
    const id = setInterval(poll, 10000);
    return () => { cancelled = true; clearInterval(id); };
  }, [authFetch]);

  return { ...state, metrics, status, error, reload: loadSnapshot };
}
