// authContext.js
// Purpose: Shared middleware to verify JWTs and attach user info. FAILS CLOSED.
// Used by all backend services to verify authentication
// depends_on: [k8s secret jwt-keypair mounted at /secrets/jwt/public-key]
//
// HISTORY - WHY THIS FILE FAILS CLOSED NOW (issues.txt SEC-1)
// This module used to look for the key at `../jwt-public-key.pem`, a path
// NOTHING in this repo ever mounted, and on not finding it fell through to
// `jwt.decode()` - which parses a token without checking its signature - on
// the assumption that Kong had already verified it upstream.
//
// On 2026-10-04 that assumption was checked and found false: the Kong
// declarative config (k8s/platform/kong/kong-configmap.yaml) has no `plugins`
// block at all, so no JWT plugin, so no verification anywhere in the request
// path. Every service importing this module - ping and jobs-api - was
// accepting UNSIGNED tokens, including forged ones claiming roles:['admin'].
//
// Two changes close it:
//   1. The key is read from /secrets/jwt/public-key, which is where
//      scripts/jwt-keys.sh actually puts it and where
//      services/auth/src/passport.js has always correctly read it from.
//   2. There is NO fallback. A service that cannot verify tokens refuses to
//      start. A crash-looping pod is a loud, correct failure; a service
//      silently trusting forged admin tokens is not.
//
// Consequence worth knowing: every service importing this MUST mount the
// jwt-keypair secret (see k8s/app/*/deployment.yaml). That is the point - the
// mount is now load-bearing rather than optional, so forgetting it fails
// immediately instead of disabling authentication.

const jwt = require('jsonwebtoken');
const fs = require('fs');

const PUBLIC_KEY_PATH = process.env.JWT_PUBLIC_KEY_PATH || '/secrets/jwt/public-key';

function loadPublicKey() {
  let key;
  try {
    key = fs.readFileSync(PUBLIC_KEY_PATH, 'utf8');
  } catch (err) {
    throw new Error(
      `FATAL: JWT public key unreadable at ${PUBLIC_KEY_PATH} (${err.code}). ` +
      'This service cannot verify authentication and refuses to start. Mount ' +
      'the `jwt-keypair` secret into the pod (see k8s/app/auth/deployment.yaml ' +
      'for the pattern). See issues.txt SEC-1 for why there is no fallback.'
    );
  }

  // A file that exists but holds something else - an empty secret value, the
  // wrong key projected - would otherwise fail on every request instead of at
  // boot, which is much harder to diagnose.
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
 * Extract and verify JWT token from Authorization header
 * Attaches req.user if valid
 */
function authContext(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    req.user = null;
    return next();
  }

  const token = authHeader.substring(7); // Remove 'Bearer ' prefix

  try {
    // algorithms is pinned, not optional. Without it jsonwebtoken would also
    // consider alg:'none' and the symmetric algorithms - the latter being the
    // classic confusion attack, where a token is signed with HMAC using the
    // PUBLIC key as the shared secret. Both are rejected by this pin.
    const decoded = jwt.verify(token, publicKey, { algorithms: ['RS256'] });

    req.user = {
      id: decoded.sub,
      email: decoded.email,
      roles: decoded.roles || ['user']
    };
  } catch (err) {
    // Expiry is routine. A bad signature may be an attempt at forgery, so log
    // it with enough context to notice a pattern in Loki.
    if (err.name === 'TokenExpiredError') {
      req.user = null;
    } else {
      console.warn(JSON.stringify({
        level: 'warn',
        msg: 'JWT rejected',
        reason: err.message,
        ip: req.ip,
        path: req.originalUrl,
      }));
      req.user = null;
    }
  }

  next();
}

/**
 * Require authentication - return 401 if no valid user
 */
function requireAuth(req, res, next) {
  authContext(req, res, () => {
    if (!req.user) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
    next();
  });
}

/**
 * Require specific role
 */
function requireRole(role) {
  return function(req, res, next) {
    requireAuth(req, res, () => {
      if (!req.user.roles.includes(role)) {
        return res.status(403).json({ error: 'Forbidden - insufficient permissions' });
      }
      next();
    });
  };
}

/**
 * Assert resource ownership - prevent IDOR
 * @param {string} resourceOwnerId - The user ID that owns this resource
 */
function assertOwnership(req, resourceOwnerId) {
  if (!req.user) {
    throw new Error('Unauthorized');
  }

  if (req.user.id !== resourceOwnerId.toString()) {
    const error = new Error('Forbidden - you do not own this resource');
    error.statusCode = 403;
    throw error;
  }
}

module.exports = {
  authContext,
  requireAuth,
  requireRole,
  assertOwnership
};
