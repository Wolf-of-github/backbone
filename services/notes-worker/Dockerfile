# Multi-stage build for notes-worker service
FROM python:3.12-slim AS build

WORKDIR /app

COPY services/notes-worker/requirements.txt ./
RUN pip install --no-cache-dir --target=/app/deps -r requirements.txt

FROM python:3.12-slim

RUN addgroup --gid 1001 appgroup && \
    adduser --uid 1001 --gid 1001 --disabled-password --gecos "" appuser

WORKDIR /app

COPY --from=build --chown=appuser:appgroup /app/deps /app/deps
ENV PYTHONPATH=/app/deps

COPY --chown=appuser:appgroup services/notes-worker/src ./src

USER appuser

# Port 3000 serves only /healthz (see worker.py) - the queue consumption
# itself has no HTTP surface.
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:3000/healthz').status == 200 else 1)"

CMD ["python", "src/worker.py"]
