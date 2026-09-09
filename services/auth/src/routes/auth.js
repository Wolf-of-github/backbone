// routes/auth.js
// Purpose: Authentication routes (register, login, refresh, logout, me)
// Depends on: User model, tokenStore, passport

const express = require('express');
const passport = require('passport');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const User = require('../models/user');
const tokenStore = require('../tokenStore');
const { loadJwtKeys } = require('../passport');

const router = express.Router();

// Load JWT keys and expiry settings
const { privateKey } = loadJwtKeys();
const JWT_ACCESS_EXPIRY = process.env.JWT_ACCESS_EXPIRY || '15m';
const JWT_REFRESH_EXPIRY = process.env.JWT_REFRESH_EXPIRY || '7d';

// Helper: convert expiry string to seconds
function expiryToSeconds(expiry) {
  const match = expiry.match(/^(\d+)([smhd])$/);
  if (!match) return 3600; // default 1 hour

  const value = parseInt(match[1], 10);
  const unit = match[2];

  const multipliers = { s: 1, m: 60, h: 3600, d: 86400 };
  return value * (multipliers[unit] || 60);
}

// Helper: validate email format
function isValidEmail(email) {
  const re = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return re.test(email);
}

// Helper: validate password
function isValidPassword(password) {
  return password && password.length >= 8;
}

// POST /api/auth/register
router.post('/register', async (req, res) => {
  try {
    const { email, password } = req.body;

    // Validation
    if (!email || !isValidEmail(email)) {
      return res.status(400).json({ error: 'Invalid email address' });
    }

    if (!isValidPassword(password)) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    // Check if user already exists
    const existingUser = await User.findOne({ email: email.toLowerCase() });
    if (existingUser) {
      return res.status(409).json({ error: 'User already exists' });
    }

    // Create user (password will be hashed by pre-save hook)
    const user = new User({
      email: email.toLowerCase(),
      passwordHash: password,  // Will be hashed by model
      roles: ['user']
    });

    await user.save();

    console.log(`User registered: ${email}`);
    res.status(201).json({ message: 'User registered successfully' });
  } catch (err) {
    console.error('Registration error:', err);
    res.status(500).json({ error: 'Registration failed' });
  }
});

// POST /api/auth/login
router.post('/login', (req, res, next) => {
  passport.authenticate('local', { session: false }, async (err, user, info) => {
    try {
      if (err) {
        console.error('Login error:', err);
        return res.status(500).json({ error: 'Authentication failed' });
      }

      if (!user) {
        return res.status(401).json({ error: info?.message || 'Invalid credentials' });
      }

      if (!privateKey) {
        console.error('Private key not available');
        return res.status(500).json({ error: 'Server configuration error' });
      }

      // Generate access token (RS256)
      const accessToken = jwt.sign(
        {
          sub: user._id.toString(),
          email: user.email,
          roles: user.roles
        },
        privateKey,
        {
          algorithm: 'RS256',
          expiresIn: JWT_ACCESS_EXPIRY
        }
      );

      // Generate refresh token (random UUID)
      const refreshTokenId = uuidv4();
      const refreshTtlSeconds = expiryToSeconds(JWT_REFRESH_EXPIRY);

      // Store refresh token in Redis
      await tokenStore.storeRefreshToken(
        user._id.toString(),
        refreshTokenId,
        refreshTtlSeconds
      );

      console.log(`User logged in: ${user.email}`);

      res.json({
        accessToken,
        refreshToken: refreshTokenId,
        expiresIn: JWT_ACCESS_EXPIRY
      });
    } catch (err) {
      console.error('Login token generation error:', err);
      res.status(500).json({ error: 'Login failed' });
    }
  })(req, res, next);
});

// POST /api/auth/refresh
router.post('/refresh', async (req, res) => {
  try {
    const { refreshToken } = req.body;

    if (!refreshToken) {
      return res.status(400).json({ error: 'Refresh token required' });
    }

    // Validate and consume refresh token (single-use)
    const userId = await tokenStore.validateRefreshToken(refreshToken);

    if (!userId) {
      return res.status(401).json({ error: 'Invalid or expired refresh token' });
    }

    // Get user
    const user = await User.findById(userId);
    if (!user) {
      return res.status(401).json({ error: 'User not found' });
    }

    if (!privateKey) {
      console.error('Private key not available');
      return res.status(500).json({ error: 'Server configuration error' });
    }

    // Generate new access token
    const accessToken = jwt.sign(
      {
        sub: user._id.toString(),
        email: user.email,
        roles: user.roles
      },
      privateKey,
      {
        algorithm: 'RS256',
        expiresIn: JWT_ACCESS_EXPIRY
      }
    );

    // Generate new refresh token (rotation)
    const newRefreshTokenId = uuidv4();
    const refreshTtlSeconds = expiryToSeconds(JWT_REFRESH_EXPIRY);

    await tokenStore.storeRefreshToken(
      user._id.toString(),
      newRefreshTokenId,
      refreshTtlSeconds
    );

    console.log(`Token refreshed for user: ${user.email}`);

    res.json({
      accessToken,
      refreshToken: newRefreshTokenId,
      expiresIn: JWT_ACCESS_EXPIRY
    });
  } catch (err) {
    console.error('Refresh error:', err);
    res.status(500).json({ error: 'Token refresh failed' });
  }
});

// POST /api/auth/logout
router.post('/logout', async (req, res) => {
  try {
    const { refreshToken } = req.body;

    if (!refreshToken) {
      return res.status(400).json({ error: 'Refresh token required' });
    }

    // Revoke refresh token
    await tokenStore.revokeRefreshToken(refreshToken);

    console.log('User logged out');
    res.json({ message: 'Logged out successfully' });
  } catch (err) {
    console.error('Logout error:', err);
    res.status(500).json({ error: 'Logout failed' });
  }
});

// GET /api/auth/me
router.get('/me', passport.authenticate('jwt', { session: false }), (req, res) => {
  // User is attached by passport JWT strategy
  res.json({
    id: req.user.id,
    email: req.user.email,
    roles: req.user.roles
  });
});

module.exports = router;
