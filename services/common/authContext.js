// authContext.js
// Purpose: Shared middleware to extract JWT user info from Authorization header
// Used by all backend services to verify authentication

const jwt = require('jsonwebtoken');
const fs = require('fs');
const path = require('path');

// Load JWT public key (for services that verify locally)
let publicKey = null;
try {
  const publicKeyPath = path.join(__dirname, '../jwt-public-key.pem');
  if (fs.existsSync(publicKeyPath)) {
    publicKey = fs.readFileSync(publicKeyPath, 'utf8');
  }
} catch (err) {
  console.warn('JWT public key not found in common/, will rely on Kong verification');
}

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
    if (publicKey) {
      // Verify token locally
      const decoded = jwt.verify(token, publicKey, {
        algorithms: ['RS256']
      });

      req.user = {
        id: decoded.sub,
        email: decoded.email,
        roles: decoded.roles || ['user']
      };
    } else {
      // Decode without verification (assume Kong already verified)
      const decoded = jwt.decode(token);

      if (decoded) {
        req.user = {
          id: decoded.sub,
          email: decoded.email,
          roles: decoded.roles || ['user']
        };
      } else {
        req.user = null;
      }
    }
  } catch (err) {
    console.error('JWT verification error:', err.message);
    req.user = null;
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
