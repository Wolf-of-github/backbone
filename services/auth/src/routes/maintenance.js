// maintenance.js
// Purpose: Admin-only endpoint to end maintenance mode from the browser
// Depends on: services/common/authContext.js (requireRole)
//
// WHY THIS EXISTS
// The CLI (`./scripts/maintenance off`) is the normal way out, but it needs
// kubectl and a kubeconfig. This endpoint is the fallback for when you are
// somewhere without them and the site is showing a 503 - the maintenance page
// has a login-gated control that calls it.
//
// WHY IT IS ONLY "off"
// There is deliberately no HTTP way to turn maintenance ON. Doing so would put
// a "take the whole platform down" button behind nothing but a password, which
// is a far worse trade than the convenience is worth. Turning it on is a
// deliberate act performed from a machine with cluster access.
//
// Talks to the Kubernetes API directly with the pod's ServiceAccount token
// rather than pulling in a client library: this needs exactly two calls, and
// the auth service should not grow a dependency tree for them.

const https = require('https');
const fs = require('fs');
const express = require('express');
const { requireRole } = require('../common/authContext');

const router = express.Router();

const SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount';
const NAMESPACE = 'platform';
const STATE_CONFIGMAP = 'maintenance-state';
const KONG_CONFIGMAP = 'kong-declarative-config';

function saToken() {
  return fs.readFileSync(`${SA_DIR}/token`, 'utf8').trim();
}

function saCA() {
  return fs.readFileSync(`${SA_DIR}/ca.crt`);
}

/**
 * Minimal Kubernetes API call using the pod's own credentials.
 */
function k8sRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const req = https.request(
      {
        host: process.env.KUBERNETES_SERVICE_HOST || 'kubernetes.default.svc',
        port: process.env.KUBERNETES_SERVICE_PORT || 443,
        path,
        method,
        ca: saCA(),
        headers: {
          Authorization: `Bearer ${saToken()}`,
          'Content-Type': body && method === 'PATCH'
            ? 'application/merge-patch+json'
            : 'application/json',
          ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}),
        },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(JSON.parse(data || '{}'));
          } else {
            reject(new Error(`k8s API ${res.statusCode}: ${data.slice(0, 200)}`));
          }
        });
      }
    );
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

/**
 * POST /internal/maintenance/off
 * Requires a valid access token whose user has the 'admin' role.
 */
router.post('/off', requireRole('admin'), async (req, res) => {
  const log = (msg, extra = {}) =>
    console.log(JSON.stringify({
      level: 'info', msg, actor: req.user.email, ...extra,
    }));

  try {
    const state = await k8sRequest(
      'GET',
      `/api/v1/namespaces/${NAMESPACE}/configmaps/${STATE_CONFIGMAP}`
    );

    if ((state.data || {}).enabled !== 'on') {
      return res.status(409).json({
        error: 'Maintenance mode is not currently enabled',
        state: (state.data || {}).enabled || 'unknown',
      });
    }

    // Restore the routing Kong had before maintenance. The CLI stashes it in
    // the state ConfigMap precisely so this endpoint can put it back without
    // needing to know how to rebuild the whole declarative config.
    const saved = (state.data || {}).saved_kong_config;
    if (!saved) {
      return res.status(500).json({
        error: 'No saved Kong configuration found - end maintenance from the CLI instead',
        hint: './scripts/maintenance off',
      });
    }

    await k8sRequest(
      'PATCH',
      `/api/v1/namespaces/${NAMESPACE}/configmaps/${KONG_CONFIGMAP}`,
      { data: { 'kong.yaml': saved } }
    );

    await k8sRequest(
      'PATCH',
      `/api/v1/namespaces/${NAMESPACE}/configmaps/${STATE_CONFIGMAP}`,
      {
        data: {
          enabled: 'off',
          since: '',
          reason: '',
          saved_kong_config: '',
          ended_by: req.user.email,
        },
      }
    );

    log('maintenance mode ended via HTTP endpoint');

    // Kong is DB-less and reloads its ConfigMap on restart, so the routing
    // change needs a rollout. Patching the pod template annotation is the same
    // thing `kubectl rollout restart` does.
    await k8sRequest(
      'PATCH',
      `/apis/apps/v1/namespaces/${NAMESPACE}/deployments/kong`,
      {
        spec: {
          template: {
            metadata: {
              annotations: {
                'kubectl.kubernetes.io/restartedAt': new Date().toISOString(),
              },
            },
          },
        },
      }
    );

    // NOTE: queues are NOT resumed here. If maintenance was started with
    // --pause-queues, resuming needs a Redis connection and a decision about
    // in-flight work; the CLI owns that. The response says so rather than
    // leaving it silently paused.
    const queuesPaused = (state.data || {}).queues_paused === 'true';

    res.json({
      status: 'ok',
      message: 'Maintenance mode ended. Kong is restarting - allow ~30 seconds.',
      ...(queuesPaused && {
        warning: 'Job queues are still paused. Resume them with: ./scripts/maintenance resume-queues',
      }),
    });
  } catch (err) {
    console.error(JSON.stringify({
      level: 'error',
      msg: 'failed to end maintenance mode',
      error: err.message,
      actor: req.user && req.user.email,
    }));
    res.status(500).json({
      error: 'Could not end maintenance mode',
      hint: 'Use the CLI instead: ./scripts/maintenance off',
    });
  }
});

/**
 * GET /internal/maintenance/status
 * Admin-only. Useful for confirming state without cluster access.
 */
router.get('/status', requireRole('admin'), async (req, res) => {
  try {
    const state = await k8sRequest(
      'GET',
      `/api/v1/namespaces/${NAMESPACE}/configmaps/${STATE_CONFIGMAP}`
    );
    const d = state.data || {};
    res.json({
      enabled: d.enabled === 'on',
      since: d.since || null,
      reason: d.reason || null,
      queuesPaused: d.queues_paused === 'true',
    });
  } catch (err) {
    res.status(500).json({ error: 'Could not read maintenance state' });
  }
});

module.exports = router;
