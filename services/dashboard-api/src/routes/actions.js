// actions.js
// Purpose: The three write actions - delete pod, scale deployment, rollout restart.
// depends_on: [services/dashboard-api/src/k8s.js, k8s/app/dashboard-api/rbac.yaml]
//
// AUDIT
// Every action logs structured JSON with `actor` (the admin's email, from the
// verified token) BEFORE it is attempted and again with the outcome. Logged
// before, because an action that crashes the process mid-flight should still
// leave a trace of who asked for it. Promtail ships these to Loki, so the
// question "who scaled kong to zero" has an answer.
//
// VALIDATION IS DELIBERATELY THIN (operator decision, 2026-10-04)
// Scale-to-zero is permitted, there is no replica ceiling, and no deployment is
// protected. The hazards are real and recorded in issues.txt AVAIL-2:
// scaling kong to 0 kills the gateway and this dashboard with it, recoverable
// only from a terminal. What IS enforced:
//   - the `data` namespace has no write RoleBinding, so RBAC refuses any write
//     there (deleting mongodb-0 is irreversible in a way nothing else here is);
//   - replicas must be a non-negative integer, because sending a string or a
//     negative number to the scale subresource produces a confusing 422 rather
//     than an honest error.
// Everything else is left to the confirm dialog, by choice, for now.

const express = require('express');
const { coreApi, appsApi } = require('../k8s');

const router = express.Router();

function audit(req, action, target, extra = {}) {
  console.log(JSON.stringify({
    level: 'info',
    msg: 'cluster action',
    actor: req.user.email,
    action,
    target,
    ...extra,
  }));
}

/** RBAC returns 403; surface that as 403 rather than a generic 500. */
function fail(res, err, fallback) {
  const code = err.statusCode === 403 ? 403
    : err.statusCode === 404 ? 404
      : err.statusCode === 409 ? 409
        : 502;
  const message = code === 403
    // The namespace allowlist is enforced by RBAC, not by this code, so a 403
    // here is the expected answer for `data` - say so instead of looking broken.
    ? 'Forbidden by cluster RBAC - this service has no write access in that namespace'
    : code === 404 ? 'Not found'
      : code === 409 ? 'Conflict - the object changed, retry'
        : fallback;
  res.status(code).json({ error: message });
}

/**
 * DELETE /api/cluster/pods/:namespace/:name
 *
 * For a controller-managed pod this is a restart, not a removal: the
 * ReplicaSet notices and creates a replacement. For a bare pod it is
 * permanent. The UI says which, since the distinction is the whole difference
 * between a routine action and data loss.
 */
router.delete('/pods/:namespace/:name', async (req, res) => {
  const { namespace, name } = req.params;
  const target = `${namespace}/${name}`;

  audit(req, 'delete-pod', target);

  try {
    const { body } = await coreApi.readNamespacedPod(name, namespace);
    const owner = (body.metadata.ownerReferences || [])[0];

    await coreApi.deleteNamespacedPod(name, namespace);

    audit(req, 'delete-pod', target, { result: 'ok', managedBy: owner ? owner.kind : 'none' });

    res.json({
      status: 'ok',
      // A pod with no owner will NOT come back. The caller needs to know that
      // it deleted something permanently rather than bounced it.
      replaced: !!owner,
      managedBy: owner ? `${owner.kind}/${owner.name}` : null,
    });
  } catch (err) {
    audit(req, 'delete-pod', target, { result: 'error', error: err.message });
    fail(res, err, 'Could not delete pod');
  }
});

/**
 * POST /api/cluster/deployments/:namespace/:name/scale   body: { replicas }
 */
router.post('/deployments/:namespace/:name/scale', async (req, res) => {
  const { namespace, name } = req.params;
  const target = `${namespace}/${name}`;
  const { replicas } = req.body || {};

  if (!Number.isInteger(replicas) || replicas < 0) {
    return res.status(400).json({ error: 'replicas must be a non-negative integer' });
  }

  audit(req, 'scale', target, { replicas });

  try {
    // Read first, so the audit log records what it was before - "scaled to 1"
    // is far less useful after the fact than "scaled 9 -> 1".
    const current = await appsApi.readNamespacedDeploymentScale(name, namespace);
    const before = (current.body.spec && current.body.spec.replicas) || 0;

    await appsApi.patchNamespacedDeploymentScale(
      name,
      namespace,
      { spec: { replicas } },
      undefined, undefined, undefined, undefined, undefined,
      { headers: { 'Content-Type': 'application/merge-patch+json' } }
    );

    audit(req, 'scale', target, { result: 'ok', from: before, to: replicas });

    res.json({
      status: 'ok',
      from: before,
      to: replicas,
      // An HPA will override a manual scale on its next evaluation. Saying so
      // prevents the "I scaled it and it went back" confusion - worker is
      // HPA-managed (k8s/app/worker/hpa.yaml), so this is a live case here.
      note: replicas === 0
        ? 'Scaled to zero. If this service fronts the dashboard (kong) or its login (auth), recover with kubectl.'
        : undefined,
    });
  } catch (err) {
    audit(req, 'scale', target, { result: 'error', error: err.message });
    fail(res, err, 'Could not scale deployment');
  }
});

/**
 * POST /api/cluster/deployments/:namespace/:name/restart
 *
 * Patching the pod template's restartedAt annotation is exactly what
 * `kubectl rollout restart` does: changing the template triggers a new
 * ReplicaSet, so pods are replaced one at a time under the deployment's
 * rolling-update strategy. With 2+ replicas that is zero-downtime; with 1 it
 * is a brief gap.
 */
router.post('/deployments/:namespace/:name/restart', async (req, res) => {
  const { namespace, name } = req.params;
  const target = `${namespace}/${name}`;

  audit(req, 'restart', target);

  try {
    const current = await appsApi.readNamespacedDeployment(name, namespace);
    const replicas = (current.body.spec && current.body.spec.replicas) || 0;

    await appsApi.patchNamespacedDeployment(
      name,
      namespace,
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
      },
      undefined, undefined, undefined, undefined, undefined,
      { headers: { 'Content-Type': 'application/merge-patch+json' } }
    );

    audit(req, 'restart', target, { result: 'ok', replicas });

    res.json({
      status: 'ok',
      replicas,
      note: replicas < 2
        ? 'Only one replica - expect a brief outage while it is replaced.'
        : 'Rolling restart; a replica stays up throughout.',
    });
  } catch (err) {
    audit(req, 'restart', target, { result: 'error', error: err.message });
    fail(res, err, 'Could not restart deployment');
  }
});

module.exports = router;
