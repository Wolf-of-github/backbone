// auth.js
// Purpose: Admin-only JWT gate for every dashboard route. FAILS CLOSED.
// depends_on: [k8s secret jwt-keypair mounted at /secrets/jwt/public-key]
//
// WHY THIS EXISTS ALONGSIDE services/common/authContext.js
// Originally this file duplicated the shared module's job because that module
// fell back to unverified `jwt.decode()` (issues.txt SEC-1), which was
// unacceptable for a service that can delete pods. That fallback has since
// been removed - authContext.js now reads the same key path and fails closed
// too - so the duplication is gone: this file is a thin wrapper that adds the
// one thing the dashboard needs beyond requireRole('admin'), namely logging
// which admin did what, and a boot-time assertion that is deliberately
// repeated here rather than inherited.
//
// The boot assertion stays explicit because it is the single most important
// property of this service: if it cannot verify tokens, it must not serve. A
// crash-looping pod is a loud, correct failure; an open admin API that can
// scale deployments to zero is a silent, catastrophic one.

const fs = require('fs');
const jwt = require('jsonwebtoken');

const PUBLIC_KEY_PATH = process.env.JWT_PUBLIC_KEY_PATH || '/secrets/jwt/public-key';

/**
 * Read and validate the signing key at boot. Throws - the caller is expected
 * to let that kill the process rather than catch it.
 *
 * Verified eagerly for two reasons: a missing key must fail at startup (where
 * it is visible as CrashLoopBackOff) rather than on the first request, and
 * reading the file once avoids a filesystem hit per request.
 */
function loadPublicKey() {
  let key;
  try {
    key = fs.readFileSync(PUBLIC_KEY_PATH, 'utf8');
  } catch (err) {
    throw new Error(
      `FATAL: JWT public key unreadable at ${PUBLIC_KEY_PATH} (${err.code}). ` +
      'dashboard-api refuses to start without it, because the alternative is ' +
      'serving an unauthenticated admin API that can delete pods. Mount the ' +
      '`jwt-keypair` secret (see k8s/app/dashboard-api/deployment.yaml).'
    );
  }

  // A file that exists but holds something else - an empty secret key, a
  // ConfigMap mounted by mistake - would make jwt.verify() throw on every
  // request instead of at boot. Catch the shape here.
  if (!/-----BEGIN (PUBLIC KEY|RSA PUBLIC KEY)-----/.test(key)) {
    throw new Error(
      `FATAL: ${PUBLIC_KEY_PATH} does not contain a PEM public key. ` +
      'Expected the `public-key` entry of the `jwt-keypair` secret.'
    );
  }

  return key;
}

const publicKey = loadPublicKey();

/**
 * Verify the bearer token and require the admin role.
 *
 * Returns 401 for "we do not know who you are" and 403 for "we know, and you
 * may not" - the distinction matters to the frontend, which refreshes the
 * token on 401 and must NOT retry on 403.
 */
function requireAdmin(req, res, next) {
  const header = req.headers.authorization;

  if (!header || !header.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  let claims;
  try {
    // algorithms is pinned deliberately. Without it, a token with
    // alg:'none' or a symmetric alg would be considered - the classic JWT
    // confusion attack, where an attacker signs with the PUBLIC key treated
    // as an HMAC secret.
    claims = jwt.verify(header.substring(7), publicKey, { algorithms: ['RS256'] });
  } catch (err) {
    // Expiry is routine and not worth logging; anything else may be an attempt
    // at forgery and is.
    if (err.name !== 'TokenExpiredError') {
      console.warn(JSON.stringify({
        level: 'warn',
        msg: 'rejected token',
        reason: err.message,
        ip: req.ip,
      }));
    }
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const roles = claims.roles || [];
  if (!roles.includes('admin')) {
    console.warn(JSON.stringify({
      level: 'warn',
      msg: 'non-admin denied cluster access',
      actor: claims.email,
      path: req.originalUrl,
    }));
    return res.status(403).json({ error: 'Forbidden - admin role required' });
  }

  req.user = { id: claims.sub, email: claims.email, roles };
  next();
}

module.exports = { requireAdmin, PUBLIC_KEY_PATH };
