# backbone

A from-scratch, fully self-hosted platform substrate on **k3s**. This repo is
built phase by phase; see [architecture.txt](architecture.txt) for the full
design, build order, and file manifest.

## Phase 0 - Substrate

Brings up the ground everything else stands on:

- a pinned single-node **k3s** cluster (agents optional)
- **local-path** as the default StorageClass (PVCs bind with no annotation)
- the `platform` / `data` / `app` **namespaces**
- a private, TLS + basic-auth **container registry** that every node trusts
- a **secrets convention** (plain k3s Secrets now, Sealed Secrets later)

### Prerequisites

- A Linux host you can `sudo` on (the k3s server). macOS/dev: run Phase 0 in a Linux VM.
- `curl`, `kubectl`, `openssl`, `htpasswd` (apache2-utils / httpd-tools), and
  `docker` or `nerdctl` on the machine that runs `make verify`.
- The registry host/IP in `.env` must resolve from every node.

### Bring up from a bare machine

```bash
git clone <this-repo> backbone && cd backbone
cp .env.example .env
$EDITOR .env            # set DOMAIN, REGISTRY_*, K3S_VERSION, K3S_SERVER_IP

make phase0             # cluster -> base -> secrets -> registry -> verify
```

Or step by step:

```bash
make cluster    # ./scripts/install-k3s.sh  -> writes ./kubeconfig
make base       # namespaces + default StorageClass
make secrets    # ./scripts/create-secrets.sh (registry-auth, registry-tls)
make registry   # ./scripts/bootstrap-registry.sh (+ /etc/rancher/k3s/registries.yaml on nodes)
make verify     # ./scripts/verify-phase0.sh  -> prints "PHASE 0 OK"
```

`export KUBECONFIG=$PWD/kubeconfig` (or use the repo default) for ad-hoc `kubectl`.

### What "done" looks like

`make verify` asserts, and exits non-zero on the first failure:

1. all nodes `Ready`
2. exactly one default StorageClass, and it is `local-path`
3. namespaces `platform`, `data`, `app` exist
4. a throwaway 1Gi PVC binds and mounts
5. a test image pushes to and pulls from the private registry (auth + TLS + node trust)

### Files

| Path | Purpose |
|------|---------|
| `.env.example` | host config template -> copy to `.env` (gitignored) |
| `config/k3s-config.yaml` | k3s server config (Traefik/ServiceLB disabled, TLS SANs) |
| `config/registries.yaml.example` | template for `/etc/rancher/k3s/registries.yaml` |
| `k8s/base/namespaces.yaml` | `platform` / `data` / `app` |
| `k8s/base/storageclass.yaml` | desired default StorageClass (applied via `kubectl patch`) |
| `k8s/platform/registry/` | registry PVC + Deployment + Service |
| `scripts/install-k3s.sh` | install k3s, write `./kubeconfig` |
| `scripts/registry-secret.sh` | htpasswd + self-signed TLS -> `registry-auth`, `registry-tls` |
| `scripts/create-secrets.sh` | single entrypoint for all Phase 0 secrets |
| `scripts/bootstrap-registry.sh` | registry manifests + per-node trust |
| `scripts/verify-phase0.sh` | the acceptance gate |
| `docs/secrets.md` | namespace map, naming, Sealed Secrets upgrade path |

### Security notes

- `.env`, `./kubeconfig`, `config/registries.yaml`, and all cert/htpasswd material
  are gitignored. Nothing sensitive is committed.
- Scripts run `set -euo pipefail`, pass secrets as argument arrays (no shell
  string interpolation), and never echo secret values.
- The registry cert is self-signed and trusted per-node via `registries.yaml`.
  Phase 5 replaces it with a real Let's Encrypt chain behind Kong.
