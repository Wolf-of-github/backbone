# Secrets convention (Phase 0)

`depends_on: []`

## Where secrets live

Kubernetes Secrets, created by hand for now via `scripts/create-secrets.sh`
(idempotent `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`).
No secret material is ever committed to git.

**Phase 0 creates no Kubernetes secrets.**
- `MULTI_NODE=false`: the k3d built-in registry is local, unauthenticated, and
  auto-trusted by every node — nothing to store.
- `MULTI_NODE=true`: `cluster-up.sh` generates the k3s **join token** and caches
  it at `.secrets/cluster-join.env` (mode 0600, gitignored). It is a node-join
  credential, not a Kubernetes Secret; `node-join.sh` reads it. Treat it like a
  password — anyone with it and network access to `:6443` can join a node.

`create-secrets.sh` exists as the stable entrypoint that later phases plug into.

## Namespace map

| Namespace | Holds |
|-----------|-------|
| `platform` | Gateway / infra: later Kong, cert-manager |
| `data`     | Datastores: later `mongodb-credentials`, `redis-password` |
| `app`      | Application services: later `jwt-*` |

## Naming

`<component>-<purpose>`, all lowercase, e.g. `mongodb-credentials`,
`redis-password`, `jwt-private-key`, `jwt-public-key` (Phases 1 and 3).

## Source of truth

All values originate in `.env` (from `.env.example`). Scripts read `.env`, never
prompt interactively, and never echo secret values.

## Upgrade path

Phase 0 uses plain k3s Secrets (base64, not encrypted at rest by default).
For production, adopt **Sealed Secrets** (or SOPS + age): commit encrypted
`SealedSecret` manifests, let the controller decrypt in-cluster. Consumer
manifests are unchanged (still a `Secret` at runtime).
