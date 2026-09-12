# worker.py
# Purpose: Consumes the "notes" BullMQ queue and does the actual MongoDB
# write for a note create - this is the async half of notes-api's
# POST /api/notes (see services/notes-api/src/app.py). Modeled on
# services/worker/src/index.js (Phase 4's reference BullMQ consumer),
# ported to Python with the official `bullmq` package so it speaks the
# same wire format against the same Redis instance.
# Depends on: MongoDB + Redis (Phase 1), notes-api (enqueues the jobs)

import asyncio
import os
import signal
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote_plus

from bullmq import Worker
from pymongo import MongoClient

MONGO_HOST = os.environ.get("MONGO_HOST", "mongodb.data.svc")
MONGO_PORT = os.environ.get("MONGO_PORT", "27017")
MONGO_APP_USER = os.environ["MONGO_APP_USER"]
MONGO_APP_PASSWORD = os.environ["MONGO_APP_PASSWORD"]
MONGO_APP_DB = os.environ["MONGO_APP_DB"]

# Same unescaped-password bug this repo hit repeatedly elsewhere
# (INSTALL_GUIDE.md Step 4/6) - always percent-encode.
_mongo_uri = (
    f"mongodb://{quote_plus(MONGO_APP_USER)}:{quote_plus(MONGO_APP_PASSWORD)}"
    f"@{MONGO_HOST}:{MONGO_PORT}/{MONGO_APP_DB}"
)
_mongo_client = MongoClient(_mongo_uri)
_db = _mongo_client[MONGO_APP_DB]
notes_collection = _db["notes"]

REDIS_HOST = os.environ.get("REDIS_HOST", "redis.data.svc")
REDIS_PORT = os.environ.get("REDIS_PORT", "6379")
REDIS_PASSWORD = os.environ["REDIS_PASSWORD"]
REDIS_URL = f"redis://:{quote_plus(REDIS_PASSWORD)}@{REDIS_HOST}:{REDIS_PORT}"

QUEUE_NAME = "notes"
CONCURRENCY = int(os.environ.get("WORKER_CONCURRENCY", "5"))


async def process(job, token):
    if job.name != "create-note":
        raise ValueError(f"unknown job type: {job.name}")

    data = job.data
    now = datetime.now(timezone.utc).isoformat()

    # notes-api already inserted a "pending" placeholder keyed by pendingId
    # so GET /api/notes/<pendingId> has something to return immediately
    # after enqueueing. This is the async write actually landing.
    result = notes_collection.update_one(
        {"pendingId": data["pendingId"]},
        {
            "$set": {
                "title": data["title"],
                "body": data.get("body", ""),
                "status": "completed",
                "updatedAt": now,
            }
        },
    )

    if result.matched_count == 0:
        raise RuntimeError(f"no placeholder note found for pendingId={data['pendingId']}")

    print(f"note {data['pendingId']} created for owner {data['ownerId']}", flush=True)
    return {"pendingId": data["pendingId"], "status": "completed"}


class _HealthzHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"healthy"}')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass  # keep the worker's own logs uncluttered


def _start_health_server():
    # Same reasoning as services/worker/src/index.js: a Deployment with no
    # HTTP port has no clean httpGet probe target, so this consumer runs a
    # trivial health server on the side purely for k8s liveness/readiness.
    server = HTTPServer(("0.0.0.0", 3000), _HealthzHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


async def main():
    _start_health_server()
    worker = Worker(
        QUEUE_NAME,
        process,
        {"connection": REDIS_URL, "concurrency": CONCURRENCY},
    )
    print(f"notes-worker listening on queue '{QUEUE_NAME}' (concurrency={CONCURRENCY})", flush=True)

    stop = asyncio.Event()

    def _handle_signal():
        print("shutting down...", flush=True)
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _handle_signal)

    await stop.wait()
    await worker.close()


if __name__ == "__main__":
    asyncio.run(main())
