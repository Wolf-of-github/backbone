# app.py
# Purpose: Notes CRUD demo API. POST enqueues a BullMQ job (async write);
# GET reads directly from MongoDB (sync reads - only the write path needs
# to prove out the Redis/BullMQ queue).
# Depends on: MongoDB + Redis (Phase 1), jwt-public-key Secret (Phase 3)

import asyncio
import os
import uuid
from datetime import datetime, timezone

from bson import ObjectId
from bson.errors import InvalidId
from bullmq import Queue
from flask import Flask, g, jsonify, request
from pymongo import MongoClient
from urllib.parse import quote_plus

from auth import assert_ownership, require_auth

app = Flask(__name__)

MONGO_HOST = os.environ.get("MONGO_HOST", "mongodb.data.svc")
MONGO_PORT = os.environ.get("MONGO_PORT", "27017")
MONGO_APP_USER = os.environ["MONGO_APP_USER"]
MONGO_APP_PASSWORD = os.environ["MONGO_APP_PASSWORD"]
MONGO_APP_DB = os.environ["MONGO_APP_DB"]

# MONGO_APP_PASSWORD is generated with `openssl rand -base64` and routinely
# contains '+' or '/' - both break an unescaped mongodb:// URI (see
# INSTALL_GUIDE.md's Step 4/6 findings for the exact failure this caused
# elsewhere in this repo). Always percent-encode.
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
_queue = Queue(QUEUE_NAME, {"connection": REDIS_URL})


def _run_async(coro):
    """bullmq's Python port is asyncio-based; Flask's request handlers are
    sync. Each request gets its own short-lived event loop rather than
    sharing one across requests/threads."""
    return asyncio.new_event_loop().run_until_complete(coro)


def _serialize(note):
    return {
        "id": str(note["_id"]),
        "ownerId": note["ownerId"],
        "title": note.get("title"),
        "body": note.get("body"),
        "status": note.get("status", "completed"),
        "createdAt": note.get("createdAt"),
        "updatedAt": note.get("updatedAt"),
    }


@app.get("/healthz")
def healthz():
    return jsonify({"status": "healthy"})


@app.post("/api/notes")
@require_auth
def create_note():
    """Enqueues the write instead of doing it inline - proves the
    Redis/BullMQ pipeline end to end. The note does not exist in MongoDB
    the instant this returns; it exists once notes-worker processes the job."""
    payload = request.get_json(silent=True) or {}
    title = payload.get("title")
    body = payload.get("body", "")

    if not title:
        return jsonify({"error": "title is required"}), 400

    pending_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    # A placeholder record lets GET /api/notes/<id> report "pending"
    # immediately, before the worker has run - same pattern jobs-api uses
    # for its job status field.
    notes_collection.insert_one(
        {
            "_id": ObjectId(),
            "pendingId": pending_id,
            "ownerId": g.user["id"],
            "title": title,
            "body": body,
            "status": "pending",
            "createdAt": now,
            "updatedAt": now,
        }
    )

    _run_async(
        _queue.add(
            "create-note",
            {
                "pendingId": pending_id,
                "ownerId": g.user["id"],
                "title": title,
                "body": body,
            },
            {"attempts": 3, "backoff": {"type": "exponential", "delay": 2000}},
        )
    )

    return jsonify({"pendingId": pending_id, "status": "queued"}), 202


@app.get("/api/notes")
@require_auth
def list_notes():
    notes = notes_collection.find({"ownerId": g.user["id"]}).sort("createdAt", -1)
    return jsonify({"notes": [_serialize(n) for n in notes]})


@app.get("/api/notes/<note_id>")
@require_auth
def get_note(note_id):
    # A note is looked up by its Mongo _id once the worker has created the
    # real document, but by pendingId immediately after enqueueing (the
    # client only has pendingId at that point).
    try:
        note = notes_collection.find_one({"_id": ObjectId(note_id)})
    except InvalidId:
        note = notes_collection.find_one({"pendingId": note_id})

    if not note:
        return jsonify({"error": "not found"}), 404

    try:
        assert_ownership(note["ownerId"])
    except PermissionError:
        return jsonify({"error": "Forbidden - you do not own this resource"}), 403

    return jsonify(_serialize(note))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 3000)))
