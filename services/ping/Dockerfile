# Dockerfile
# Purpose: Multi-stage build for ping service
# depends_on: [package.json, src/index.js]

FROM node:20-alpine AS build
WORKDIR /app
COPY services/ping/package*.json ./
RUN npm ci --only=production
COPY services/ping/src ./src

FROM node:20-alpine
RUN addgroup -g 1001 appgroup && adduser -D -u 1001 -G appgroup appuser
WORKDIR /app
COPY --from=build --chown=appuser:appgroup /app ./
# Copy shared common modules
COPY --chown=appuser:appgroup services/common ./src/common
USER appuser
EXPOSE 3000
CMD ["node", "src/index.js"]
