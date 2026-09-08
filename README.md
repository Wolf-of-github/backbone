# backbone

A from-scratch, fully self-hosted platform substrate. It runs **anywhere Docker
runs** - the Kubernetes layer is **k3s inside Docker via [k3d](https://k3d.io)**,
the same "one binary, one command" model as Minikube. Linux, macOS, and
Windows+WSL2 are all identical.

See [architecture.txt](architecture.txt) for the full design, build order, and
per-phase file manifest.

## Phase 0 - Substrate

Brings up the ground everything else stands on:

- a **k3d** cluster (k3s nodes as Docker containers), Traefik disabled (Kong later)
- **local-path** as the default StorageClass (PVCs bind with no annotation)
- the `platform` / `data` / `app` **namespaces**
- k3d's **built-in container registry** (local, auto-trusted by every node)
- a **secrets convention** (none needed yet; stable entrypoint for later phases)

### Prerequisites

- **Docker** (Docker Desktop, Rancher Desktop, Colima, or plain `dockerd`) - running.
- **k3d** - `brew install k3d`, or
  `curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash`,
  or `choco install k3d` on Windows.
- **kubectl**.
- That's it - no Linux VM, no `sudo`, no k3s install on the host.

### Bring up

```bash
git clone <this-repo> backbone && cd backbone
cp .env.example .env          # defaults work for local use; edit ports if 8080/5000 are taken

make phase0                   # cluster -> base -> secrets -> verify
```

Step by step:

```bash
make cluster   # ./scripts/cluster-up.sh   -> k3d cluster + registry, writes ./kubeconfig
make base      # namespaces + default StorageClass
make secrets   # ./scripts/create-secrets.sh (no-op in Phase 0)
make verify    # ./scripts/verify-phase0.sh -> prints "PHASE 0 OK"

make down      # ./scripts/cluster-down.sh  -> delete the cluster when done
```

Use the repo-local kubeconfig for ad-hoc `kubectl`:
`export KUBECONFIG=$PWD/kubeconfig`.

### What "done" looks like

`make verify` asserts, and exits non-zero on the first failure:

1. all nodes `Ready`
2. exactly one default StorageClass, and it is `local-path`
3. namespaces `platform`, `data`, `app` exist
4. a throwaway 1Gi PVC binds and mounts
5. a test image pushes to the k3d registry at `localhost:5000` **and** pulls
   back inside the cluster as `backbone-registry:5000/...`

Success = the final `PHASE 0 OK` line and `make` exiting `0`.

### Registry: two names, one registry

| From | Use |
|------|-----|
| your machine (`docker push`) | `localhost:5000/<img>:<tag>` |
| image refs in k8s manifests / CI | `backbone-registry:5000/<img>:<tag>` |

k3d injects the `backbone-registry` hostname into every node, so both resolve to
the same registry container.

### Files

| Path | Purpose |
|------|---------|
| `.env.example` | config template -> copy to `.env` (gitignored) |
| `config/k3d-cluster.yaml` | k3d cluster definition (image, ports, registry, `--disable=traefik`) |
| `k8s/base/namespaces.yaml` | `platform` / `data` / `app` |
| `k8s/base/storageclass.yaml` | desired default StorageClass (applied via `kubectl patch`) |
| `scripts/cluster-up.sh` | create/reuse the k3d cluster, write `./kubeconfig` |
| `scripts/cluster-down.sh` | delete the k3d cluster |
| `scripts/create-secrets.sh` | stable secrets entrypoint (no-op in Phase 0) |
| `scripts/verify-phase0.sh` | the acceptance gate |
| `docs/secrets.md` | namespace map, naming, Sealed Secrets upgrade path |

### Security notes

- `.env`, `./kubeconfig`, the rendered k3d config, and any future cert material
  are gitignored. Nothing sensitive is committed.
- Scripts run `set -euo pipefail` and never echo secret values.
- The k3d registry is unauthenticated **by design** - it is local to your
  machine. Phase 5 introduces the real, authenticated registry behind Kong + TLS.
