# Multi-stage build for dashboard-api service (Phase 7)
#
# BUILD CONTEXT IS THE REPO ROOT, not services/dashboard-api - this image needs
# services/common for metrics.js. Building from the service directory fails
# with "COPY services/common: not found", which is the Phase 3 build-context
# bug all over again (see architecture.txt). scripts/build-push.sh already
# builds root-context services this way.

# Build stage
FROM node:20-alpine AS build

WORKDIR /app

COPY services/dashboard-api/package*.json ./

RUN npm install --omit=dev

# Runtime stage
FROM node:20-alpine

# Create non-root user
RUN addgroup -g 1001 appgroup && \
    adduser -u 1001 -G appgroup -s /bin/sh -D appuser

WORKDIR /app

COPY --from=build --chown=appuser:appgroup /app/node_modules ./node_modules

COPY --chown=appuser:appgroup services/dashboard-api/package.json ./
COPY --chown=appuser:appgroup services/dashboard-api/src ./src

# Shared modules (metrics.js). Mirrors services/jobs-api/Dockerfile - the
# require path in src is './common/metrics'.
COPY --chown=appuser:appgroup services/common ./src/common

USER appuser

EXPOSE 3000

# /healthz reports 503 until at least one Kubernetes watch is established, so
# this also catches "running but blind to the cluster".
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/healthz', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

CMD ["node", "src/index.js"]
