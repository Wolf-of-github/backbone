# Multi-stage build for worker service
# Build stage
FROM node:20-alpine AS build

WORKDIR /app

# Copy package files
COPY services/worker/package*.json ./

# Install dependencies
RUN npm ci --only=production

# Runtime stage
FROM node:20-alpine

# Create non-root user
RUN addgroup -g 1001 appgroup && \
    adduser -u 1001 -G appgroup -s /bin/sh -D appuser

WORKDIR /app

# Copy dependencies from build stage
COPY --from=build --chown=appuser:appgroup /app/node_modules ./node_modules

# Copy application code
COPY --chown=appuser:appgroup services/worker/package.json ./
COPY --chown=appuser:appgroup services/worker/src ./src

# Copy shared common modules
COPY --chown=appuser:appgroup services/common ./src/common

# Copy Job model from jobs-api (shared between worker and api)
COPY --chown=appuser:appgroup services/jobs-api/src/models ./src/models

# Switch to non-root user
USER appuser

# Expose port for health check
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/healthz', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start the worker
CMD ["node", "src/index.js"]
