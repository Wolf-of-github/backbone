# Multi-stage build for notes-api service
# Build stage - installs deps into their own layer
FROM python:3.12-slim AS build

WORKDIR /app

COPY services/notes-api/requirements.txt ./
RUN pip install --no-cache-dir --target=/app/deps -r requirements.txt

# Runtime stage
FROM python:3.12-slim

RUN addgroup --gid 1001 appgroup && \
    adduser --uid 1001 --gid 1001 --disabled-password --gecos "" appuser

WORKDIR /app

COPY --from=build --chown=appuser:appgroup /app/deps /app/deps
ENV PYTHONPATH=/app/deps

COPY --chown=appuser:appgroup services/notes-api/src ./src

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:3000/healthz').status == 200 else 1)"

CMD ["gunicorn", "--chdir", "src", "--bind", "0.0.0.0:3000", "--workers", "2", "app:app"]
