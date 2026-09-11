#!/usr/bin/env bash
# mongo-restore.sh
# Purpose: List and restore MongoDB backups from external S3.
# depends_on: [k8s/data/backup/mongo-cronjob.yaml, scripts/lib.sh]
#
# usage:
#   mongo-restore.sh list
#       show available backups (newest first) with dates and sizes
#
#   mongo-restore.sh restore <key> --target <dbname>
#       restore into a NAMED database, leaving production untouched.
#       The safe default, and what you almost always want: restore beside the
#       live data, inspect it, then copy across only what you need.
#
#   mongo-restore.sh restore <key> --overwrite-production --confirm
#       DESTRUCTIVE. Drops and replaces the live application database.
#       Requires BOTH flags - neither alone is enough, and no environment
#       variable skips them.
#
# Runs in-cluster because MongoDB has no public endpoint by design. Uses the
# mongo:7.0 image and installs the AWS CLI into it, rather than juggling two
# containers: mongorestore can then stream straight from the downloaded
# archive, and there is one place for the whole operation to fail.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source "$REPO_ROOT/scripts/lib.sh"

load_env
need kubectl

kubectl -n data get secret backup-s3-credentials >/dev/null 2>&1 \
  || die "secret/backup-s3-credentials missing - run 'make backup' first"

COMMAND="${1:-list}"
shift || true

# Shared env block: S3 credentials plus the Mongo root credential. Everything
# arrives via secretKeyRef - no secret is ever interpolated into a manifest or
# a shell string.
restore_env() {
  cat <<'ENVYAML'
        envFrom:
        - secretRef:
            name: backup-s3-credentials
        env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom: { secretKeyRef: { name: backup-s3-credentials, key: access-key } }
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom: { secretKeyRef: { name: backup-s3-credentials, key: secret-key } }
        - name: AWS_DEFAULT_REGION
          valueFrom: { secretKeyRef: { name: backup-s3-credentials, key: region } }
        - name: MONGO_ROOT_USER
          valueFrom: { secretKeyRef: { name: mongodb-credentials, key: root-username } }
        - name: MONGO_ROOT_PASSWORD
          valueFrom: { secretKeyRef: { name: mongodb-credentials, key: root-password } }
ENVYAML
}

# Two official images, no runtime installs: aws-cli fetches the archive onto a
# shared emptyDir, then mongo:7.0 restores from it. Installing the AWS CLI into
# the mongo image at run time would need internet egress on every restore and
# add a minute to the one operation you run under pressure.
#   $1 job name
#   $2 aws-cli script (initContainer) - writes to /shared
#   $3 mongo script (main container)  - reads from /shared; empty to skip
run_job() {
  local job="$1" fetch="$2" main="${3:-}"

  local main_block
  if [ -n "$main" ]; then
    main_block="      containers:
      - name: restore
        image: mongo:7.0
        command: [\"/bin/bash\",\"-c\"]
        args:
        - |
${main}
$(restore_env)
        volumeMounts:
        - { name: shared, mountPath: /shared }"
  else
    # List-only: nothing for mongo to do, but a Job needs a main container.
    main_block="      containers:
      - name: done
        image: mongo:7.0
        command: [\"/bin/bash\",\"-c\"]
        args: [\"cat /shared/output.txt\"]
        volumeMounts:
        - { name: shared, mountPath: /shared }"
  fi

  kubectl -n data apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - name: fetch
        image: amazon/aws-cli:2.17.0
        command: ["/bin/bash","-c"]
        args:
        - |
${fetch}
$(restore_env)
        volumeMounts:
        - { name: shared, mountPath: /shared }
${main_block}
      volumes:
      - { name: shared, emptyDir: {} }
YAML

  log "Job ${job} running - streaming output..."
  # Wait for the pod to exist before tailing, or logs -f races the scheduler.
  for _ in $(seq 1 60); do
    kubectl -n data get pod -l "job-name=${job}" 2>/dev/null | grep -q . && break
    sleep 1
  done
  kubectl -n data logs -f "job/${job}" 2>/dev/null || true

  if kubectl -n data wait --for=condition=complete "job/${job}" --timeout=600s >/dev/null 2>&1; then
    kubectl -n data delete job "${job}" --ignore-not-found >/dev/null 2>&1 || true
    return 0
  fi
  kubectl -n data logs "job/${job}" --tail=30 2>/dev/null || true
  kubectl -n data delete job "${job}" --ignore-not-found >/dev/null 2>&1 || true
  return 1
}

case "$COMMAND" in
  list)
    log "Available MongoDB backups (newest first):"
    JOB="mongo-list-$(date +%s)"
    run_job "$JOB" '          set -euo pipefail
          EP=""
          [ -n "${endpoint:-}" ] && EP="--endpoint-url ${endpoint}"
          aws $EP s3 ls "s3://${bucket}/${prefix}/mongo/" --human-readable \
            | sort -r > /shared/output.txt
          cat /shared/output.txt' \
      || die "could not list backups - check the bucket and credentials"
    log ""
    log "Restore safely:  ./scripts/mongo-restore.sh restore <key> --target restore_check"
    ;;

  restore)
    KEY="${1:-}"
    [ -n "$KEY" ] || die "usage: mongo-restore.sh restore <key> --target <db>
  Get <key> from: ./scripts/mongo-restore.sh list
  It is the filename only, e.g. mongo-20260911T030000Z.gz"
    shift

    TARGET_DB=""
    OVERWRITE=false
    CONFIRMED=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --target)               TARGET_DB="${2:-}"; shift 2 ;;
        --overwrite-production) OVERWRITE=true; shift ;;
        --confirm)              CONFIRMED=true; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done

    require_vars MONGO_APP_DB

    if [ "$OVERWRITE" = true ]; then
      [ "$CONFIRMED" = true ] || die "--overwrite-production also requires --confirm.

  That combination DROPS the live database '${MONGO_APP_DB}' and replaces it
  with the backup's contents. Every document written since the backup is lost,
  including accounts created since.

  Restore beside it instead - almost always what you actually want:
    ./scripts/mongo-restore.sh restore $KEY --target restore_check"
      TARGET_DB="$MONGO_APP_DB"
      log ""
      log "*** OVERWRITING THE LIVE DATABASE '${TARGET_DB}' ***"
      log ""
    else
      [ -n "$TARGET_DB" ] \
        || die "specify --target <dbname> (safe), or --overwrite-production --confirm (destructive)"
      [ "$TARGET_DB" != "$MONGO_APP_DB" ] \
        || die "--target '$TARGET_DB' IS the live database.
  Overwriting it must be explicit: --overwrite-production --confirm"
    fi

    JOB="mongo-restore-$(date +%s)"
    log "Restoring '$KEY' into database '$TARGET_DB'..."

    # --nsFrom/--nsTo rewrites the namespace as the archive is read, so a dump
    # taken from the live database lands in the scratch one. Without it
    # mongorestore writes back to whatever database the dump came from,
    # silently ignoring the target we chose.
    run_job "$JOB" "          set -euo pipefail
          EP=\"\"
          [ -n \"\${endpoint:-}\" ] && EP=\"--endpoint-url \${endpoint}\"
          echo \"downloading ${KEY}\"
          aws \$EP s3 cp \"s3://\${bucket}/\${prefix}/mongo/${KEY}\" /shared/dump.gz
          SIZE=\$(stat -c%s /shared/dump.gz)
          echo \"downloaded \${SIZE} bytes\"
          [ \"\$SIZE\" -gt 0 ] || { echo 'archive is empty'; exit 1; }" \
      "          set -euo pipefail
          echo \"restoring into database '${TARGET_DB}'\"
          mongorestore \\
            --host=mongodb.data.svc --port=27017 \\
            --username=\"\$MONGO_ROOT_USER\" --password=\"\$MONGO_ROOT_PASSWORD\" \\
            --authenticationDatabase=admin \\
            --archive=/shared/dump.gz --gzip \\
            --nsFrom='${MONGO_APP_DB}.*' --nsTo='${TARGET_DB}.*' \\
            --drop
          echo 'restore complete'" \
      || die "restore failed - the live database was not modified unless you passed --overwrite-production"

    ok "Restored into '$TARGET_DB'"
    if [ "$OVERWRITE" != true ]; then
      log ""
      log "Inspect it without touching production:"
      log "  kubectl -n data run mongosh --rm -it --restart=Never --image=mongo:7.0 -- \\"
      log "    mongosh \"mongodb://<root-user>:<pw>@mongodb.data.svc/${TARGET_DB}?authSource=admin\""
      log ""
      log "Drop it when finished:  db.dropDatabase()"
    fi
    ;;

  *)
    die "usage: mongo-restore.sh <list|restore>"
    ;;
esac
