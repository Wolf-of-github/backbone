// ClusterView.jsx
// Purpose: The dashboard - nodes, pods and deployments, live, with actions.
// depends_on: [useClusterStream.js, LogViewer.jsx]
//
// Styling is inline to match the rest of this app (Login.jsx, App.jsx) rather
// than introducing a CSS pipeline for one view.

import { useState, useMemo } from 'react';
import { useClusterStream } from './useClusterStream';
import LogViewer from './LogViewer';

const C = {
  border: '#e1e4e8',
  headerBg: '#f6f8fa',
  text: '#24292e',
  muted: '#6a737d',
  ok: '#22863a',
  warn: '#b08800',
  bad: '#cb2431',
  link: '#0366d6',
};

const td = { padding: '6px 10px', borderBottom: `1px solid ${C.border}`, fontSize: '0.85rem' };
const th = { ...td, background: C.headerBg, fontWeight: 600, textAlign: 'left', cursor: 'pointer', userSelect: 'none' };
const mono = { fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace' };

/** Relative age, the way kubectl renders it. */
function age(ts) {
  if (!ts) return '-';
  const s = Math.floor((Date.now() - new Date(ts)) / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

function fmtCpu(m) {
  if (m == null) return '-';
  return m < 1000 ? `${Math.round(m)}m` : `${(m / 1000).toFixed(2)}`;
}

function fmtMem(b) {
  if (b == null) return '-';
  const mi = b / (1024 * 1024);
  return mi < 1024 ? `${Math.round(mi)}Mi` : `${(mi / 1024).toFixed(2)}Gi`;
}

/**
 * A pod's effective status. The API reports phase Running even while the pod
 * is being deleted, so deletionTimestamp has to be checked first or a
 * Terminating pod reads as healthy - which is exactly what made the ghost pods
 * from the dead node confusing (issues.txt AVAIL-3).
 */
function podStatus(p) {
  if (p.deletedAt) return { label: 'Terminating', color: C.warn };
  if (p.phase === 'Running') {
    const [ready, total] = p.ready.split('/').map(Number);
    if (ready < total) return { label: `Running (${p.ready})`, color: C.warn };
    return { label: 'Running', color: C.ok };
  }
  if (p.phase === 'Succeeded') return { label: 'Completed', color: C.muted };
  if (p.phase === 'Pending') return { label: 'Pending', color: C.warn };
  return { label: p.phase || 'Unknown', color: C.bad };
}

function StatusBadge({ status, error }) {
  const map = {
    live: { text: 'live', color: C.ok },
    connecting: { text: 'connecting', color: C.muted },
    reconnecting: { text: 'reconnecting', color: C.warn },
    error: { text: 'error', color: C.bad },
  };
  const s = map[status] || map.connecting;
  return (
    <span style={{ fontSize: '0.8rem', color: s.color }} title={error || ''}>
      ● {s.text}
    </span>
  );
}

function ClusterView({ authFetch }) {
  const { pods, nodes, deployments, events, metrics, status, error, reload } =
    useClusterStream(authFetch);

  const [ns, setNs] = useState('all');
  const [sort, setSort] = useState({ key: 'namespace', dir: 'asc' });
  const [logTarget, setLogTarget] = useState(null);
  const [busy, setBusy] = useState(null);
  const [actionMsg, setActionMsg] = useState(null);

  const namespaces = useMemo(
    () => ['all', ...Array.from(new Set(pods.map((p) => p.namespace))).sort()],
    [pods]
  );

  const visiblePods = useMemo(() => {
    const filtered = ns === 'all' ? pods : pods.filter((p) => p.namespace === ns);
    const dir = sort.dir === 'asc' ? 1 : -1;
    return [...filtered].sort((a, b) => {
      let av;
      let bv;
      if (sort.key === 'restarts') { av = a.restarts; bv = b.restarts; }
      else if (sort.key === 'cpu') {
        av = (metrics.pods[`${a.namespace}/${a.name}`] || {}).cpu || 0;
        bv = (metrics.pods[`${b.namespace}/${b.name}`] || {}).cpu || 0;
      } else if (sort.key === 'createdAt') {
        av = new Date(a.createdAt); bv = new Date(b.createdAt);
      } else { av = a[sort.key] || ''; bv = b[sort.key] || ''; }
      if (av < bv) return -dir;
      if (av > bv) return dir;
      return a.name.localeCompare(b.name);
    });
  }, [pods, ns, sort, metrics]);

  const visibleDeployments = useMemo(
    () => (ns === 'all' ? deployments : deployments.filter((d) => d.namespace === ns))
      .slice()
      .sort((a, b) => (a.namespace + a.name).localeCompare(b.namespace + b.name)),
    [deployments, ns]
  );

  const header = (key, label) => (
    <th
      style={th}
      onClick={() => setSort((s) => ({
        key,
        dir: s.key === key && s.dir === 'asc' ? 'desc' : 'asc',
      }))}
    >
      {label}{sort.key === key ? (sort.dir === 'asc' ? ' ▲' : ' ▼') : ''}
    </th>
  );

  /** Run a write action, with a confirm step and the result surfaced. */
  async function act(key, confirmText, request) {
    // eslint-disable-next-line no-alert
    if (!window.confirm(confirmText)) return;

    setBusy(key);
    setActionMsg(null);
    try {
      const res = await request();
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
      setActionMsg({ ok: true, text: data.note || 'Done' });
      // No manual refresh: the watch stream delivers the resulting change.
      // Reloading here would race it and could show older state.
    } catch (err) {
      setActionMsg({ ok: false, text: err.message });
    } finally {
      setBusy(null);
    }
  }

  const deletePod = (p) => act(
    `del:${p.uid}`,
    `Delete pod ${p.namespace}/${p.name}?\n\nIf it is managed by a controller it will be replaced. If not, it is gone permanently.`,
    () => authFetch(`/api/cluster/pods/${p.namespace}/${p.name}`, { method: 'DELETE' })
  );

  const scale = (d) => {
    // eslint-disable-next-line no-alert
    const input = window.prompt(`Scale ${d.namespace}/${d.name} to how many replicas?`, String(d.desired));
    if (input === null) return;
    const replicas = parseInt(input, 10);
    if (Number.isNaN(replicas) || replicas < 0) {
      setActionMsg({ ok: false, text: 'Replicas must be a non-negative integer' });
      return;
    }
    // Scaling the gateway or auth to zero locks this very page out, and
    // recovery is CLI-only. Not blocked (operator decision - issues.txt
    // AVAIL-2), but the confirm says so plainly.
    const lockout = replicas === 0 && ['kong', 'auth', 'frontend'].includes(d.name);
    return act(
      `scale:${d.uid}`,
      lockout
        ? `WARNING: scaling ${d.name} to 0 will take down this dashboard.\n\nRecovery requires a terminal:\n  kubectl -n ${d.namespace} scale deploy/${d.name} --replicas=${d.desired}\n\nContinue?`
        : `Scale ${d.namespace}/${d.name} from ${d.desired} to ${replicas}?`,
      () => authFetch(`/api/cluster/deployments/${d.namespace}/${d.name}/scale`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ replicas }),
      })
    );
  };

  const restart = (d) => act(
    `restart:${d.uid}`,
    `Rolling restart of ${d.namespace}/${d.name}?${d.desired < 2 ? '\n\nOnly one replica - expect a brief outage.' : ''}`,
    () => authFetch(`/api/cluster/deployments/${d.namespace}/${d.name}/restart`, { method: 'POST' })
  );

  if (status === 'error') {
    return (
      <div style={{ padding: '1rem', border: `1px solid ${C.bad}`, borderRadius: 4, color: C.bad }}>
        <strong>Cluster view unavailable:</strong> {error}
      </div>
    );
  }

  const warnings = pods.filter((p) => {
    const s = podStatus(p);
    return s.color === C.warn || s.color === C.bad;
  }).length;

  return (
    <div style={{ color: C.text }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: '1rem', marginBottom: '0.75rem', flexWrap: 'wrap' }}>
        <h2 style={{ margin: 0, fontSize: '1.1rem' }}>Cluster</h2>
        <StatusBadge status={status} error={error} />
        <span style={{ fontSize: '0.8rem', color: C.muted }}>
          {nodes.length} node{nodes.length === 1 ? '' : 's'} · {pods.length} pods
          {warnings > 0 && <span style={{ color: C.warn }}> · {warnings} not healthy</span>}
          {!metrics.available && <span style={{ color: C.muted }}> · metrics unavailable</span>}
        </span>
        <select value={ns} onChange={(e) => setNs(e.target.value)} style={{ fontSize: '0.8rem', padding: '2px 4px' }}>
          {namespaces.map((n) => <option key={n} value={n}>{n === 'all' ? 'all namespaces' : n}</option>)}
        </select>
        <button onClick={reload} style={{ fontSize: '0.8rem', padding: '2px 8px', cursor: 'pointer' }}>
          Refresh
        </button>
      </div>

      {actionMsg && (
        <div style={{
          padding: '0.5rem 0.75rem', marginBottom: '0.75rem', borderRadius: 4, fontSize: '0.85rem',
          background: actionMsg.ok ? '#e6ffed' : '#ffeef0',
          color: actionMsg.ok ? C.ok : C.bad,
        }}>
          {actionMsg.text}
        </div>
      )}

      {/* --- nodes --- */}
      <h3 style={{ fontSize: '0.9rem', margin: '1rem 0 0.4rem' }}>Nodes</h3>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ borderCollapse: 'collapse', width: '100%', minWidth: 600 }}>
          <thead>
            <tr>
              <th style={th}>Name</th><th style={th}>Ready</th><th style={th}>Role</th>
              <th style={th}>CPU</th><th style={th}>Memory</th><th style={th}>Pods</th>
              <th style={th}>Kubelet</th><th style={th}>Age</th>
            </tr>
          </thead>
          <tbody>
            {nodes.map((n) => {
              const u = metrics.nodes[n.name] || {};
              return (
                <tr key={n.uid}>
                  <td style={{ ...td, ...mono }}>{n.name}</td>
                  <td style={{ ...td, color: n.ready === 'True' ? C.ok : C.bad }}>
                    {n.ready === 'True' ? 'Ready' : n.ready === 'Unknown' ? 'NotReady (no kubelet)' : 'NotReady'}
                    {n.unschedulable && <span style={{ color: C.warn }}> · cordoned</span>}
                  </td>
                  <td style={td}>{(n.roles || []).join(', ') || '-'}</td>
                  <td style={td}>{fmtCpu(u.cpu)} / {n.capacity.cpu}</td>
                  <td style={td}>{fmtMem(u.memory)}</td>
                  <td style={td}>{pods.filter((p) => p.node === n.name).length} / {n.capacity.pods}</td>
                  <td style={td}>{n.kubelet}</td>
                  <td style={td}>{age(n.createdAt)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {/* --- deployments --- */}
      <h3 style={{ fontSize: '0.9rem', margin: '1.5rem 0 0.4rem' }}>Deployments</h3>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ borderCollapse: 'collapse', width: '100%', minWidth: 700 }}>
          <thead>
            <tr>
              <th style={th}>Namespace</th><th style={th}>Name</th><th style={th}>Ready</th>
              <th style={th}>Desired</th><th style={th}>Age</th><th style={th}>Actions</th>
            </tr>
          </thead>
          <tbody>
            {visibleDeployments.map((d) => (
              <tr key={d.uid}>
                <td style={td}>{d.namespace}</td>
                <td style={{ ...td, ...mono }}>{d.name}</td>
                <td style={{ ...td, color: d.ready === d.desired ? C.ok : C.warn }}>
                  {d.ready}/{d.desired}
                </td>
                <td style={td}>{d.desired}</td>
                <td style={td}>{age(d.createdAt)}</td>
                <td style={td}>
                  <button
                    onClick={() => scale(d)}
                    disabled={busy === `scale:${d.uid}`}
                    style={{ fontSize: '0.75rem', marginRight: 4, cursor: 'pointer' }}
                  >
                    Scale
                  </button>
                  <button
                    onClick={() => restart(d)}
                    disabled={busy === `restart:${d.uid}`}
                    style={{ fontSize: '0.75rem', cursor: 'pointer' }}
                  >
                    Restart
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* --- pods --- */}
      <h3 style={{ fontSize: '0.9rem', margin: '1.5rem 0 0.4rem' }}>
        Pods {ns !== 'all' && <span style={{ color: C.muted, fontWeight: 400 }}>in {ns}</span>}
      </h3>
      <div style={{ overflowX: 'auto' }}>
        <table style={{ borderCollapse: 'collapse', width: '100%', minWidth: 900 }}>
          <thead>
            <tr>
              {header('namespace', 'Namespace')}
              {header('name', 'Name')}
              {header('phase', 'Status')}
              <th style={td}>Ready</th>
              {header('restarts', 'Restarts')}
              {header('cpu', 'CPU')}
              <th style={td}>Memory</th>
              {header('node', 'Node')}
              {header('createdAt', 'Age')}
              <th style={td}>Actions</th>
            </tr>
          </thead>
          <tbody>
            {visiblePods.map((p) => {
              const s = podStatus(p);
              const u = metrics.pods[`${p.namespace}/${p.name}`] || {};
              return (
                <tr key={p.uid} style={p.deletedAt ? { opacity: 0.6 } : undefined}>
                  <td style={td}>{p.namespace}</td>
                  <td style={{ ...td, ...mono }}>{p.name}</td>
                  <td style={{ ...td, color: s.color }}>{s.label}</td>
                  <td style={td}>{p.ready}</td>
                  <td style={{ ...td, color: p.restarts > 0 ? C.warn : undefined }}>{p.restarts}</td>
                  <td style={td}>{fmtCpu(u.cpu)}</td>
                  <td style={td}>{fmtMem(u.memory)}</td>
                  <td style={{ ...td, ...mono, fontSize: '0.78rem' }}>{p.node || '-'}</td>
                  <td style={td}>{age(p.createdAt)}</td>
                  <td style={td}>
                    <button
                      onClick={() => setLogTarget(p)}
                      style={{ fontSize: '0.75rem', marginRight: 4, cursor: 'pointer' }}
                    >
                      Logs
                    </button>
                    <button
                      onClick={() => deletePod(p)}
                      disabled={busy === `del:${p.uid}` || !!p.deletedAt}
                      style={{ fontSize: '0.75rem', cursor: 'pointer' }}
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {/* --- events --- */}
      <h3 style={{ fontSize: '0.9rem', margin: '1.5rem 0 0.4rem' }}>Recent events</h3>
      <div style={{ overflowX: 'auto', maxHeight: 260, overflowY: 'auto', border: `1px solid ${C.border}`, borderRadius: 4 }}>
        <table style={{ borderCollapse: 'collapse', width: '100%', minWidth: 700 }}>
          <tbody>
            {events
              .filter((e) => ns === 'all' || e.namespace === ns)
              .map((e) => (
                <tr key={e.uid}>
                  <td style={{ ...td, whiteSpace: 'nowrap', color: C.muted }}>{age(e.at)} ago</td>
                  <td style={{ ...td, color: e.type === 'Warning' ? C.warn : C.muted }}>{e.type}</td>
                  <td style={{ ...td, ...mono, fontSize: '0.78rem' }}>{e.object}</td>
                  <td style={td}><strong>{e.reason}</strong> {e.message}</td>
                </tr>
              ))}
          </tbody>
        </table>
      </div>

      {logTarget && (
        <LogViewer pod={logTarget} onClose={() => setLogTarget(null)} />
      )}
    </div>
  );
}

export default ClusterView;
