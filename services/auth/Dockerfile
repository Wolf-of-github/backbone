# Multi-stage build for auth service
FROM node:20-alpine AS build

WORKDIR /app

# Build context is the REPO ROOT (see scripts/build-push.sh) so that
# services/common can be copied in - Phase 5B needs metrics.js here.
COPY services/auth/package*.json ./

# Install dependencies
RUN npm ci --only=production

# Copy source code
COPY services/auth/src ./src

# Shared modules (metrics.js; authContext.js/queue.js available if needed)
COPY services/common ./src/common

# Production stage
FROM node:20-alpine

# Create non-root user
RUN addgroup -g 1001 appgroup && \
    adduser -D -u 1001 -G appgroup appuser

WORKDIR /app

# Copy from build stage
COPY --from=build --chown=appuser:appgroup /app ./

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/healthz', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start service
CMD ["node", "src/index.js"]
