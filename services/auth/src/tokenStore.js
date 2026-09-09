// tokenStore.js
// Purpose: Redis-backed refresh token allowlist with single-use rotation
// Depends on: Redis from Phase 1

const Redis = require('ioredis');

class TokenStore {
  constructor() {
    this.redis = null;
  }

  // Initialize Redis connection
  async connect() {
    const redisHost = process.env.REDIS_HOST || 'redis.data.svc';
    const redisPort = process.env.REDIS_PORT || 6379;
    const redisPassword = process.env.REDIS_PASSWORD;

    if (!redisPassword) {
      throw new Error('REDIS_PASSWORD environment variable is required');
    }

    this.redis = new Redis({
      host: redisHost,
      port: redisPort,
      password: redisPassword,
      retryStrategy: (times) => {
        const delay = Math.min(times * 50, 2000);
        return delay;
      }
    });

    this.redis.on('error', (err) => {
      console.error('Redis connection error:', err);
    });

    this.redis.on('ready', () => {
      console.log(`Connected to Redis at ${redisHost}:${redisPort}`);
    });

    // Test connection
    await this.redis.ping();
  }

  // Store refresh token (userId -> tokenId mapping with TTL)
  async storeRefreshToken(userId, tokenId, ttlSeconds) {
    if (!this.redis) {
      throw new Error('Redis not connected');
    }

    const key = `refresh:${tokenId}`;
    await this.redis.set(key, userId, 'EX', ttlSeconds);

    // Log only prefix for security
    console.log(`Stored refresh token ${tokenId.substring(0, 8)}... for user ${userId}`);
  }

  // Validate and consume refresh token (single-use rotation)
  async validateRefreshToken(tokenId) {
    if (!this.redis) {
      throw new Error('Redis not connected');
    }

    const key = `refresh:${tokenId}`;
    const userId = await this.redis.get(key);

    if (!userId) {
      console.log(`Refresh token ${tokenId.substring(0, 8)}... not found or expired`);
      return null;
    }

    // Delete immediately (single-use)
    await this.redis.del(key);

    console.log(`Validated and consumed refresh token ${tokenId.substring(0, 8)}... for user ${userId}`);
    return userId;
  }

  // Revoke refresh token (logout)
  async revokeRefreshToken(tokenId) {
    if (!this.redis) {
      throw new Error('Redis not connected');
    }

    const key = `refresh:${tokenId}`;
    const result = await this.redis.del(key);

    if (result > 0) {
      console.log(`Revoked refresh token ${tokenId.substring(0, 8)}...`);
      return true;
    }

    console.log(`Refresh token ${tokenId.substring(0, 8)}... not found (already revoked or expired)`);
    return false;
  }

  // Health check
  async ping() {
    if (!this.redis) {
      throw new Error('Redis not connected');
    }
    return await this.redis.ping();
  }

  // Close connection
  async disconnect() {
    if (this.redis) {
      await this.redis.quit();
      this.redis = null;
    }
  }
}

module.exports = new TokenStore();
