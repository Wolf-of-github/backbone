// k8s.js
// Purpose: Kubernetes API access - trimmed snapshots and a resilient watch layer.
// depends_on: [@kubernetes/client-node, k8s/app/dashboard-api/rbac.yaml]
//
// WHY A CLIENT LIBRARY HERE, WHEN maintenance.js HAND-ROLLS ITS https CALLS
// That route needs exactly two requests and was right to avoid a dependency.
// This service needs lists, long-lived watches, log following and patches
// across five resource types; reimplementing watch reconnection and chunked
// stream parsing is the dependency's entire value.
//
// THE WATCH CONTRACT (the part that actually matters)
// A watch is a long-lived HTTP stream of ADDED/MODIFIED/DELETED events. Three
// failure modes that polling would hide, and that must be handled or the
// dashboard silently goes stale while looking fine:
//
//   1. Watches end on their own. The API server closes them after a few
//      minutes regardless of health. A watch that ends is NORMAL and must be
//      re-established from the last resourceVersion seen - not treated as an
//      error, and not restarted from scratch (which would re-send every object
//      as ADDED and make the UI flicker).
//
//   2. HTTP 410 Gone means the resourceVersion has aged out of the API
//      server's history window (it keeps roughly 5 minutes). The ONLY correct
//      response is to re-LIST for a fresh snapshot and start a new watch from
//      that list's resourceVersion. Retrying the watch with the same version
//      loops forever - the server will never again accept it.
//
//   3. resourceVersion is an opaque token, not a number. Never compare, order,
//      or increment one. The only valid operations are "pass it back" and
//      "replace it with a newer one from the server".

const k8s = require('@kubernetes/client-node');
const { EventEmitter } = require('events');

const kc = new k8s.KubeConfig();
// Reads the pod's mounted ServiceAccount token + CA. The same credentials
// maintenance.js opens by hand from /var/run/secrets/kubernetes.io/serviceaccount.
kc.loadFromCluster();

const coreApi = kc.makeApiClient(k8s.CoreV1Api);
const appsApi = kc.makeApiClient(k8s.AppsV1Api);
const metricsApi = new k8s.Metrics(kc);

// --- trimming ---------------------------------------------------------------
// A full pod object is ~15KB of managedFields, annotations and status history.
// The UI needs a few hundred bytes. With ~40 pods that is the difference
// between a 600KB snapshot and a 20KB one, and it matters more on the watch
// stream, where every MODIFIED event would otherwise carry the whole object.

function trimPod(p) {
  const statuses = (p.status && p.status.containerStatuses) || [];
  return {
    kind: 'Pod',
    uid: p.metadata.uid,
    name: p.metadata.name,
    namespace: p.metadata.namespace,
    node: p.spec.nodeName || null,
    phase: p.status && p.status.phase,
    // A pod can report phase Running while a container is not ready, which is
    // exactly the state an operator needs to see, so ready is counted
    // separately rather than inferred from the phase.
    ready: `${statuses.filter((c) => c.ready).length}/${statuses.length || (p.spec.containers || []).length}`,
    restarts: statuses.reduce((n, c) => n + (c.restartCount || 0), 0),
    containers: (p.spec.containers || []).map((c) => c.name),
    images: (p.spec.containers || []).map((c) => c.image),
    createdAt: p.metadata.creationTimestamp,
    // Set while a pod is being deleted. This is what the dashboard needs to
    // render the Terminating state - and the stuck-forever Terminating pods a
    // dead node leaves behind (see issues.txt AVAIL-3) show up precisely here.
    deletedAt: p.metadata.deletionTimestamp || null,
  };
}

function trimNode(n) {
  const conds = (n.status && n.status.conditions) || [];
  const ready = conds.find((c) => c.type === 'Ready');
  return {
    kind: 'Node',
    uid: n.metadata.uid,
    name: n.metadata.name,
    // "Ready" is a condition, not a phase: status 'True' means ready,
    // 'False' means actively broken, and 'Unknown' means the kubelet stopped
    // reporting - which is what a vanished machine looks like.
    ready: ready ? ready.status : 'Unknown',
    roles: Object.keys(n.metadata.labels || {})
      .filter((l) => l.startsWith('node-role.kubernetes.io/'))
      .map((l) => l.replace('node-role.kubernetes.io/', ''))
      .concat(n.metadata.labels['backbone.dev/role'] || []),
    // Schedulability is separate from readiness - a cordoned node is Ready but
    // takes no new pods, which otherwise looks like a mysterious Pending.
    unschedulable: !!(n.spec && n.spec.unschedulable),
    capacity: {
      cpu: n.status.capacity && n.status.capacity.cpu,
      memory: n.status.capacity && n.status.capacity.memory,
      pods: n.status.capacity && n.status.capacity.pods,
    },
    kubelet: n.status.nodeInfo && n.status.nodeInfo.kubeletVersion,
    createdAt: n.metadata.creationTimestamp,
  };
}

function trimDeployment(d) {
  return {
    kind: 'Deployment',
    uid: d.metadata.uid,
    name: d.metadata.name,
    namespace: d.metadata.namespace,
    // desired is spec; the rest are observed status. Keeping them distinct is
    // what makes a mid-rollout or an unschedulable replica legible.
    desired: (d.spec && d.spec.replicas) || 0,
    ready: (d.status && d.status.readyReplicas) || 0,
    available: (d.status && d.status.availableReplicas) || 0,
    updated: (d.status && d.status.updatedReplicas) || 0,
    images: ((d.spec.template.spec.containers) || []).map((c) => c.image),
    createdAt: d.metadata.creationTimestamp,
  };
}

function trimEvent(e) {
  return {
    kind: 'Event',
    uid: e.metadata.uid,
    name: e.metadata.name,
    namespace: e.metadata.namespace,
    type: e.type,
    reason: e.reason,
    message: e.message,
    object: e.involvedObject
      ? `${e.involvedObject.kind}/${e.involvedObject.name}`
      : null,
    count: e.count || 1,
    // lastTimestamp is null on events from the newer events.k8s.io path;
    // eventTime carries it there.
    at: e.lastTimestamp || e.eventTime || e.metadata.creationTimestamp,
  };
}

// Each watched resource in one place: how to list it, how to watch it, and how
// to trim it. The WatchManager is generic over this table, so adding a
// resource type is one entry rather than another near-copy of the watch loop.
const RESOURCES = {
  pods: {
    path: '/api/v1/pods',
    list: () => coreApi.listPodForAllNamespaces(),
    trim: trimPod,
  },
  nodes: {
    path: '/api/v1/nodes',
    list: () => coreApi.listNode(),
    trim: trimNode,
  },
  deployments: {
    path: '/apis/apps/v1/deployments',
    list: () => appsApi.listDeploymentForAllNamespaces(),
    trim: trimDeployment,
  },
  events: {
    path: '/api/v1/events',
    list: () => coreApi.listEventForAllNamespaces(),
    trim: trimEvent,
  },
};

/**
 * Full current state, plus the resourceVersion each watch must resume from.
 *
 * The per-resource resourceVersion from a LIST is the authoritative starting
 * point for the watch that follows it: it guarantees no event between the list
 * and the watch is missed or double-counted. Starting a watch from "now"
 * instead leaves a gap.
 */
async function snapshot() {
  const names = Object.keys(RESOURCES);
  const results = await Promise.all(names.map((n) => RESOURCES[n].list()));

  const out = { items: {}, resourceVersions: {}, takenAt: new Date().toISOString() };

  names.forEach((name, i) => {
    const body = results[i].body || results[i];
    out.items[name] = (body.items || []).map(RESOURCES[name].trim);
    out.resourceVersions[name] = body.metadata.resourceVersion;
  });

  // Events are unbounded and mostly stale; the dashboard only wants recent
  // ones. Sorted newest-first and capped so a cluster with thousands of events
  // does not produce a multi-megabyte snapshot.
  out.items.events = out.items.events
    .sort((a, b) => new Date(b.at) - new Date(a.at))
    .slice(0, 100);

  return out;
}

/**
 * Live CPU/memory from metrics-server.
 *
 * Degrades to nulls rather than throwing: metrics-server is a separate
 * Deployment that can be absent or still starting, and a dashboard that 500s
 * because a secondary metric is unavailable is worse than one showing a dash.
 */
async function usage() {
  const out = { pods: {}, nodes: {}, available: true };

  try {
    const [pm, nm] = await Promise.all([
      metricsApi.getPodMetrics(),
      metricsApi.getNodeMetrics(),
    ]);

    for (const p of pm.items || []) {
      const totals = (p.containers || []).reduce(
        (acc, c) => ({
          cpu: acc.cpu + parseCpu(c.usage.cpu),
          memory: acc.memory + parseMemory(c.usage.memory),
        }),
        { cpu: 0, memory: 0 }
      );
      out.pods[`${p.metadata.namespace}/${p.metadata.name}`] = totals;
    }

    for (const n of nm.items || []) {
      out.nodes[n.metadata.name] = {
        cpu: parseCpu(n.usage.cpu),
        memory: parseMemory(n.usage.memory),
      };
    }
  } catch (err) {
    console.warn(JSON.stringify({
      level: 'warn',
      msg: 'metrics unavailable',
      error: err.message,
    }));
    out.available = false;
  }

  return out;
}

// Kubernetes quantities are strings in units the UI should not have to parse.
// CPU -> millicores, memory -> bytes.
function parseCpu(v) {
  if (!v) return 0;
  if (v.endsWith('n')) return parseInt(v, 10) / 1e6;   // nanocores
  if (v.endsWith('u')) return parseInt(v, 10) / 1e3;   // microcores
  if (v.endsWith('m')) return parseInt(v, 10);          // millicores
  return parseFloat(v) * 1000;                          // whole cores
}

function parseMemory(v) {
  if (!v) return 0;
  const units = { Ki: 1024, Mi: 1024 ** 2, Gi: 1024 ** 3, Ti: 1024 ** 4 };
  for (const [suffix, mult] of Object.entries(units)) {
    if (v.endsWith(suffix)) return parseInt(v, 10) * mult;
  }
  return parseInt(v, 10);
}

/**
 * Keeps one watch per resource type alive and emits normalized events.
 *
 * Emits: 'event' -> { resource, type, object }   (type: ADDED|MODIFIED|DELETED)
 *        'resync' -> { resource }                 (a 410 forced a re-list;
 *                                                  consumers must re-snapshot)
 *
 * One manager is shared by every connected browser rather than one watch per
 * client: watches cost API-server resources, and N clients watching the same
 * pods is N times the load for identical data.
 */
class WatchManager extends EventEmitter {
  constructor() {
    super();
    // Node's default of 10 listeners is low for an SSE fan-out; each connected
    // browser attaches one.
    this.setMaxListeners(100);
    this.watch = new k8s.Watch(kc);
    this.active = new Map();   // resource -> { req, version }
    this.stopped = false;
    this.backoff = new Map();  // resource -> consecutive failure count
  }

  start(resourceVersions = {}) {
    this.stopped = false;
    for (const name of Object.keys(RESOURCES)) {
      this._watch(name, resourceVersions[name]);
    }
  }

  stop() {
    this.stopped = true;
    for (const [, state] of this.active) {
      if (state.req && state.req.abort) state.req.abort();
    }
    this.active.clear();
  }

  async _watch(name, resourceVersion) {
    if (this.stopped) return;

    const { path, trim } = RESOURCES[name];

    // No version means we have nothing to resume from - list first to get one.
    // This is also the 410 recovery path.
    if (!resourceVersion) {
      try {
        const res = await RESOURCES[name].list();
        const body = res.body || res;
        resourceVersion = body.metadata.resourceVersion;
        // Tell consumers their cached state is now suspect. They must
        // re-snapshot; applying subsequent deltas to stale state would leave
        // the UI quietly wrong, which is worse than a visible reload.
        this.emit('resync', { resource: name });
      } catch (err) {
        return this._retry(name, undefined, err);
      }
    }

    try {
      const req = await this.watch.watch(
        path,
        { resourceVersion, allowWatchBookmarks: true },

        // --- per-event callback ---
        (type, apiObj) => {
          // A 410 does NOT arrive as an HTTP error on the done callback - the
          // watch stream is already established (HTTP 200) and the expiry comes
          // through as an in-band event: type 'ERROR' carrying a V1Status with
          // code 410 / reason 'Expired'. Handling it only in the done callback
          // means falling through to the normal resume path and retrying the
          // same dead resourceVersion forever, which is the exact infinite loop
          // the watch contract above warns about. Verified against
          // @kubernetes/client-node 0.22.3, whose watch() routes every parsed
          // line to this callback.
          if (type === 'ERROR') {
            const code = apiObj && apiObj.code;
            const expired = code === 410 || (apiObj && apiObj.reason === 'Expired');
            console.log(JSON.stringify({
              level: 'info',
              msg: expired
                ? 'watch resourceVersion expired (in-band), re-listing'
                : 'watch error event',
              resource: name,
              code,
              reason: apiObj && apiObj.reason,
            }));
            // Clearing the version sends the next attempt down the re-list
            // path; a non-410 error event still needs a fresh start, since the
            // stream is no longer trustworthy.
            const state = this.active.get(name);
            if (state) state.version = undefined;
            return;   // the stream will close; done() resumes from undefined
          }

          // Bookmarks carry no object change - only a newer resourceVersion to
          // resume from. Tracking them is what keeps a quiet resource (nodes,
          // typically) from aging out its version and hitting a 410 on the
          // next reconnect.
          if (type === 'BOOKMARK') {
            const state = this.active.get(name);
            if (state) state.version = apiObj.metadata.resourceVersion;
            return;
          }

          const state = this.active.get(name);
          if (state && apiObj.metadata) {
            state.version = apiObj.metadata.resourceVersion;
          }

          this.backoff.set(name, 0);
          this.emit('event', { resource: name, type, object: trim(apiObj) });
        },

        // --- stream-ended callback ---
        (err) => {
          if (this.stopped) return;

          const state = this.active.get(name);
          // Read the version from shared state, NOT from the `resourceVersion`
          // closure variable: the ERROR branch above deliberately clears it to
          // force a re-list, and using the stale closure value here would
          // undo that.
          const lastVersion = state ? state.version : resourceVersion;

          // A 410 means lastVersion is permanently unusable. Clearing it sends
          // the next attempt down the re-list path above. Retrying with it
          // would loop forever - the single most important branch here.
          if (err && (err.statusCode === 410 || /too old resource version/i.test(err.message || ''))) {
            console.log(JSON.stringify({
              level: 'info',
              msg: 'watch resourceVersion expired, re-listing',
              resource: name,
            }));
            return this._watch(name, undefined);
          }

          // err null/undefined is the normal case: the API server closed an
          // idle watch. Not an error, and not logged as one - just resume.
          if (!err) return this._watch(name, lastVersion);

          return this._retry(name, lastVersion, err);
        }
      );

      this.active.set(name, { req, version: resourceVersion });
    } catch (err) {
      this._retry(name, resourceVersion, err);
    }
  }

  /**
   * Exponential backoff on real errors, so an API server that is down or
   * rate-limiting is not hammered. Capped at 30s - long enough to be polite,
   * short enough that recovery is not left waiting.
   */
  _retry(name, resourceVersion, err) {
    if (this.stopped) return;

    const n = (this.backoff.get(name) || 0) + 1;
    this.backoff.set(name, n);
    const delay = Math.min(1000 * 2 ** (n - 1), 30000);

    console.warn(JSON.stringify({
      level: 'warn',
      msg: 'watch failed, retrying',
      resource: name,
      attempt: n,
      delayMs: delay,
      error: err && err.message,
    }));

    setTimeout(() => this._watch(name, resourceVersion), delay);
  }

  /** Which watches are currently established - surfaced on /healthz. */
  status() {
    return Object.keys(RESOURCES).reduce((acc, name) => {
      acc[name] = {
        active: this.active.has(name),
        failures: this.backoff.get(name) || 0,
      };
      return acc;
    }, {});
  }
}

module.exports = {
  snapshot,
  usage,
  WatchManager,
  RESOURCES,
  coreApi,
  appsApi,
  kc,
  // exported for tests
  parseCpu,
  parseMemory,
};
