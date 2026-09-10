# Multi-stage build for jobs-api service
# Build stage
FROM node:20-alpine AS build

WORKDIR /app

# Copy package files
COPY services/jobs-api/package*.json ./

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
COPY --chown=appuser:appgroup services/jobs-api/package.json ./
COPY --chown=appuser:appgroup services/jobs-api/src ./src

# Copy shared common modules
COPY --chown=appuser:appgroup services/common ./src/common

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/healthz', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start the service
CMD ["node", "src/index.js"]
