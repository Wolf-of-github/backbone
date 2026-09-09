# Secrets convention (Phase 0-1)

`depends_on: []`

## Where secrets live

Kubernetes Secrets, created by hand for now via `scripts/create-secrets.sh`
(idempotent `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`).
No secret material is ever committed to git.

**Phase 0 creates no Kubernetes secrets.** The one credential it produces is the
k3s **cluster-join token**: `cluster-up.sh` writes it to `.secrets/cluster-join.env`
(mode 0600, gitignored), and `node-join.sh` reads it. It is a node-join
credential, not a Kubernetes Secret. Treat it like a password — anyone with it
and network access to the server's `:6443` can join a node. Regenerate/read it on
the server with `sudo cat /var/lib/rancher/k3s/server/node-token`.

`create-secrets.sh` exists as the stable entrypoint that later phases plug into.

## Phase 1 - Data layer

`scripts/data-secrets.sh` (run by `make secrets-data` / `make data`) is the first
concrete `<phase>-secrets.sh`. It reads `.env` and creates two Secrets in the
`data` namespace, idempotently:

| Secret | Keys | From `.env` | Consumed by |
|--------|------|-------------|-------------|
| `mongodb-credentials` | `root-username`, `root-password` | `MONGO_ROOT_USER`, `MONGO_ROOT_PASSWORD` | MongoDB StatefulSet (datadir bootstrap), the init Job |
| | `app-username`, `app-password`, `app-db` | `MONGO_APP_USER`, `MONGO_APP_PASSWORD`, `MONGO_APP_DB` | the init Job; later auth / jobs-api / worker (least-privilege) |
| `redis-password` | `password` | `REDIS_PASSWORD` | Redis StatefulSet (`--requirepass`), every Redis client |

The script **fails** (does not auto-generate) if any of the six `.env` values is
blank. Re-running with changed values updates the Secret objects; running pods
pick the change up only on restart (`kubectl -n data rollout restart
statefulset/<name>`).

The MongoDB `requirepass`/root password and Redis `requirepass` are passed to the
containers via `secretKeyRef` env / command args - never written into a ConfigMap.

## Namespace map

| Namespace | Holds |
|-----------|-------|
| `platform` | Gateway / infra: later Kong, cert-manager |
| `data`     | Datastores: `mongodb-credentials`, `redis-password` (Phase 1) |
| `app`      | Application services: later `jwt-*` |

## Naming

`<component>-<purpose>`, all lowercase, e.g. `mongodb-credentials`,
`redis-password` (Phase 1), `jwt-private-key`, `jwt-public-key` (Phase 3).

## Source of truth

All values originate in `.env` (from `.env.example`). Scripts read `.env`, never
prompt interactively, and never echo secret values.

## Upgrade path

Phase 0 uses plain k3s Secrets (base64, not encrypted at rest by default).
For production, adopt **Sealed Secrets** (or SOPS + age): commit encrypted
`SealedSecret` manifests, let the controller decrypt in-cluster. Consumer
manifests are unchanged (still a `Secret` at runtime).
