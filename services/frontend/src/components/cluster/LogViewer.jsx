// LogViewer.jsx
// Purpose: Stream one pod's logs into a modal pane.
// depends_on: [dashboard-api GET /api/cluster/logs/:ns/:pod]
//
// Uses fetch + ReadableStream for the same reason useClusterStream.js does:
// EventSource cannot send an Authorization header, and the alternative puts
// the access token in Kong's logs (issues.txt SEC-2).

import { useState, useEffect, useRef } from 'react';

const MAX_LINES = 2000;   // a chatty pod would otherwise grow the DOM without bound

function LogViewer({ pod, onClose }) {
  const [lines, setLines] = useState([]);
  const [state, setState] = useState('connecting');
  const [err, setErr] = useState(null);
  const [container, setContainer] = useState(
    pod.containers && pod.containers.length === 1 ? pod.containers[0] : ''
  );
  const [follow, setFollow] = useState(true);
  const paneRef = useRef(null);

  // A multi-container pod needs an explicit choice - the API refuses to guess,
  // because showing the wrong container's logs convincingly is worse than
  // asking.
  const needsChoice = (pod.containers || []).length > 1 && !container;

  useEffect(() => {
    if (needsChoice) return undefined;

    const controller = new AbortController();
    let cancelled = false;

    (async () => {
      setLines([]);
      setState('connecting');
      setErr(null);

      try {
        const token = localStorage.getItem('accessToken');
        const qs = new URLSearchParams({ tail: '200' });
        if (container) qs.set('container', container);

        const res = await fetch(
          `/api/cluster/logs/${pod.namespace}/${pod.name}?${qs}`,
          { headers: { Authorization: `Bearer ${token}` }, signal: controller.signal }
        );

        if (!res.ok) {
          const body = await res.json().catch(() => ({}));
          throw new Error(body.error || `HTTP ${res.status}`);
        }
        if (!res.body) throw new Error('No response body');

        setState('streaming');

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        for (;;) {
          const { done, value } = await reader.read();
          if (done || cancelled) break;

          buffer += decoder.decode(value, { stream: true });
          const frames = buffer.split('\n\n');
          buffer = frames.pop();

          const batch = [];
          for (const frame of frames) {
            if (!frame.trim() || frame.startsWith(':')) continue;   // heartbeat

            let event = 'message';
            let data = '';
            for (const l of frame.split('\n')) {
              if (l.startsWith('event: ')) event = l.slice(7).trim();
              else if (l.startsWith('data: ')) data += l.slice(6);
            }
            if (!data) continue;

            try {
              const parsed = JSON.parse(data);
              if (event === 'log') batch.push(parsed.line);
              else if (event === 'error') setErr(parsed.error);
              else if (event === 'end') setState('ended');
            } catch { /* skip malformed frame */ }
          }

          // Batched per chunk rather than per line: a pod replaying 200 lines
          // would otherwise trigger 200 renders.
          if (batch.length) {
            setLines((prev) => [...prev, ...batch].slice(-MAX_LINES));
          }
        }

        if (!cancelled) setState((s) => (s === 'streaming' ? 'ended' : s));
      } catch (e) {
        if (!cancelled && e.name !== 'AbortError') {
          setErr(e.message);
          setState('error');
        }
      }
    })();

    // Aborting matters on the server too: it is what ends the upstream
    // follow request against the API server, which would otherwise leak for
    // the life of the dashboard pod.
    return () => { cancelled = true; controller.abort(); };
  }, [pod.namespace, pod.name, container, needsChoice]);

  // Auto-scroll, unless the user has scrolled up to read something.
  useEffect(() => {
    if (follow && paneRef.current) {
      paneRef.current.scrollTop = paneRef.current.scrollHeight;
    }
  }, [lines, follow]);

  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.5)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1000,
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: '#fff', borderRadius: 6, width: 'min(1000px, 92vw)',
          height: 'min(640px, 85vh)', display: 'flex', flexDirection: 'column',
        }}
      >
        <div style={{
          padding: '0.6rem 0.9rem', borderBottom: '1px solid #e1e4e8',
          display: 'flex', alignItems: 'center', gap: '0.75rem', flexWrap: 'wrap',
        }}>
          <strong style={{ fontSize: '0.9rem', fontFamily: 'ui-monospace, Menlo, monospace' }}>
            {pod.namespace}/{pod.name}
          </strong>

          {(pod.containers || []).length > 1 && (
            <select
              value={container}
              onChange={(e) => setContainer(e.target.value)}
              style={{ fontSize: '0.8rem' }}
            >
              <option value="">select container…</option>
              {pod.containers.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          )}

          <span style={{ fontSize: '0.78rem', color: '#6a737d' }}>
            {state}{lines.length ? ` · ${lines.length} lines` : ''}
          </span>

          <label style={{ fontSize: '0.78rem', color: '#6a737d' }}>
            <input
              type="checkbox"
              checked={follow}
              onChange={(e) => setFollow(e.target.checked)}
            /> follow
          </label>

          <button onClick={onClose} style={{ marginLeft: 'auto', cursor: 'pointer', fontSize: '0.8rem' }}>
            Close
          </button>
        </div>

        {err && (
          <div style={{ padding: '0.5rem 0.9rem', color: '#cb2431', fontSize: '0.82rem' }}>{err}</div>
        )}

        <div
          ref={paneRef}
          onScroll={(e) => {
            // Turn off follow the moment the user scrolls away from the
            // bottom, so reading back through a log is not fought by the
            // auto-scroll.
            const el = e.currentTarget;
            const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
            if (!atBottom && follow) setFollow(false);
          }}
          style={{
            flex: 1, overflow: 'auto', background: '#0d1117', color: '#c9d1d9',
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
            fontSize: '0.78rem', lineHeight: 1.45, padding: '0.6rem 0.9rem',
            whiteSpace: 'pre-wrap', wordBreak: 'break-word',
          }}
        >
          {needsChoice
            ? 'This pod has multiple containers - choose one above.'
            : lines.length === 0
              ? (state === 'connecting' ? 'Connecting…' : 'No output.')
              : lines.map((l, i) => <div key={i}>{l}</div>)}
        </div>
      </div>
    </div>
  );
}

export default LogViewer;
