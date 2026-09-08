# Secrets convention (Phase 0)

`depends_on: []`

## Where secrets live

Kubernetes Secrets, created by hand for now via `scripts/create-secrets.sh`
(idempotent `kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -`).
No secret material is ever committed to git (`.gitignore` blocks `.env`, `*.key`,
`*.crt`, `htpasswd`, `config/registries.yaml`).

## Namespace map

| Namespace | Holds |
|-----------|-------|
| `platform` | Gateway / infra: `registry-auth`, `registry-tls`, later Kong, cert-manager |
| `data`     | Datastores: later `mongodb-credentials`, `redis-password` |
| `app`      | Application services: later `jwt-*`, image pull secrets |

## Naming

`<component>-<purpose>`, all lowercase, e.g.:

- `registry-auth`  — htpasswd file for the private registry (`generic`, key `htpasswd`)
- `registry-tls`   — TLS cert/key for the registry (`kubernetes.io/tls`)
- `mongodb-credentials`, `redis-password` — added in Phase 1
- `jwt-private-key`, `jwt-public-key` — added in Phase 3

## Source of truth

All values originate in `.env` (from `.env.example`). Scripts read `.env`, never
prompt interactively in CI, and never echo secret values to stdout.

## Rotation / re-run

Every secret-creating script is idempotent. Re-running after changing `.env`
updates the Secret in place; you must then restart the consuming pods.

## Upgrade path

Phase 0 uses plain k3s Secrets (base64, not encrypted at rest by default).
For production, adopt **Sealed Secrets** (or SOPS + age): commit encrypted
`SealedSecret` manifests, let the controller decrypt in-cluster. Migration is
per-namespace and does not change consumer manifests (still a `Secret` at runtime).
