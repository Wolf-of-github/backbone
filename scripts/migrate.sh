#!/usr/bin/env bash
# migrate.sh
# Purpose: MongoDB migration runner for use as a CI pipeline step.
# depends_on: [scripts/data-secrets.sh, scripts/lib.sh]
#
# usage: migrate.sh up [target]     apply pending migrations (optionally up to target)
#        migrate.sh down <target>   roll back to (and including) target
#        migrate.sh status          list applied and pending
#
# Migrations live in /migrations as NNN-name.js exporting { up, down }:
#
#   module.exports = {
#     up:   async (db) => { await db.collection('users').createIndex({ email: 1 }, { unique: true }); },
#     down: async (db) => { await db.collection('users').dropIndex('email_1'); },
#   };
#
# Applied migrations are tracked in the _migrations collection, so re-running
# `up` is a no-op. Runs as a Job in-cluster because the app database is only
# reachable from inside; there is no public Mongo endpoint by design.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

COMMAND="${1:-status}"
TARGET="${2:-}"

case "$COMMAND" in
  up|down|status) ;;
  *) die "usage: migrate.sh <up|down|status> [target]" ;;
esac

[ "$COMMAND" = "down" ] && [ -z "$TARGET" ] \
  && die "'down' requires an explicit target - refusing to guess how far to roll back"

MIGRATIONS_DIR="$REPO_ROOT/migrations"
[ -d "$MIGRATIONS_DIR" ] || die "no migrations directory at $MIGRATIONS_DIR"

JOB_NAME="migrate-$(date +%s)"

log "Running migrations: $COMMAND ${TARGET:-}"

# Ship the migration files in as a ConfigMap so the Job needs no image build.
kubectl -n app create configmap "$JOB_NAME-files" \
  --from-file="$MIGRATIONS_DIR" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cleanup() {
  kubectl -n app delete configmap "$JOB_NAME-files" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n app apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 0          # a failed migration must not silently retry
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migrate
        image: mongo:7.0
        # MONGO_APP_PASSWORD comes from `openssl rand -base64`, which routinely
        # produces '+' and '/' - both break an unescaped mongodb:// URI. Build
        # the URI in-container with encodeURIComponent instead of splicing the
        # raw secret value into the connection string via $(VAR) substitution.
        command: ["/bin/bash", "-c"]
        args:
          - |
            MONGO_URI="mongodb://$(node -e 'process.stdout.write(encodeURIComponent(process.env.MONGO_APP_USER))'):$(node -e 'process.stdout.write(encodeURIComponent(process.env.MONGO_APP_PASSWORD))')@mongodb.data.svc/$MONGO_APP_DB"
            exec mongosh --quiet "$MONGO_URI" --eval "$MONGO_EVAL"
        env:
        - name: MONGO_APP_USER
          valueFrom: { secretKeyRef: { name: mongodb-credentials, key: app-username } }
        - name: MONGO_APP_PASSWORD
          valueFrom: { secretKeyRef: { name: mongodb-credentials, key: app-password } }
        - name: MONGO_APP_DB
          valueFrom: { secretKeyRef: { name: mongodb-credentials, key: app-db } }
        - name: MONGO_EVAL
          value: |
            const fs = require('fs');
            const dir = '/migrations';
            const cmd = '${COMMAND}';
            const target = '${TARGET}';

            const applied = db._migrations.find().sort({ name: 1 }).toArray().map(d => d.name);
            const files = fs.readdirSync(dir).filter(f => f.endsWith('.js')).sort();

            if (cmd === 'status') {
              files.forEach(f => print((applied.includes(f) ? '[applied] ' : '[pending] ') + f));
              quit(0);
            }

            if (cmd === 'up') {
              const pending = files.filter(f => !applied.includes(f));
              if (!pending.length) { print('nothing to apply'); quit(0); }
              for (const f of pending) {
                if (target && f > target) break;
                print('applying ' + f);
                const m = require(dir + '/' + f);
                m.up(db);
                db._migrations.insertOne({ name: f, appliedAt: new Date() });
              }
              quit(0);
            }

            if (cmd === 'down') {
              const toRevert = applied.filter(f => f >= target).reverse();
              if (!toRevert.length) { print('nothing to roll back'); quit(0); }
              for (const f of toRevert) {
                print('reverting ' + f);
                const m = require(dir + '/' + f);
                m.down(db);
                db._migrations.deleteOne({ name: f });
              }
              quit(0);
            }
        volumeMounts:
        - name: migrations
          mountPath: /migrations
          readOnly: true
      volumes:
      - name: migrations
        configMap:
          name: ${JOB_NAME}-files
YAML

log "Waiting for the migration Job..."
if ! kubectl -n app wait --for=condition=complete "job/$JOB_NAME" --timeout=300s 2>/dev/null; then
  kubectl -n app logs "job/$JOB_NAME" >&2 || true
  die "migration failed - see the log above. The database was NOT left half-migrated
  unless a single migration itself failed partway (Mongo has no cross-collection
  transaction here); check _migrations against the log before re-running."
fi

kubectl -n app logs "job/$JOB_NAME"
kubectl -n app delete job "$JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true
ok "migrations $COMMAND complete"
