# auth.py
# Purpose: JWT verification, ported from services/common/authContext.js so
# notes-api enforces the same RS256-signature-checked auth as every other
# backbone service (see that file for the canonical Node.js version).

import functools
import os

import jwt
from flask import g, jsonify, request

_PUBLIC_KEY_PATH = os.path.join(os.path.dirname(__file__), "jwt-public-key.pem")

with open(_PUBLIC_KEY_PATH, "r") as f:
    _PUBLIC_KEY = f.read()


def _decode_token(token):
    payload = jwt.decode(token, _PUBLIC_KEY, algorithms=["RS256"])
    return {
        "id": payload.get("sub"),
        "email": payload.get("email"),
        "roles": payload.get("roles") or ["user"],
    }


def require_auth(view):
    """Reject with 401 unless Authorization: Bearer <valid RS256 JWT>."""

    @functools.wraps(view)
    def wrapped(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        if not auth_header.startswith("Bearer "):
            return jsonify({"error": "Unauthorized"}), 401

        token = auth_header[len("Bearer "):]
        try:
            g.user = _decode_token(token)
        except jwt.InvalidTokenError:
            return jsonify({"error": "Unauthorized"}), 401

        return view(*args, **kwargs)

    return wrapped


def assert_ownership(resource_owner_id):
    """Raise if the current user does not own the resource. 403 via caller."""
    if g.user["id"] != str(resource_owner_id):
        raise PermissionError("Forbidden - you do not own this resource")
