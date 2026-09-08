# backbone

A from-scratch, fully self-hosted platform substrate whose whole point is
**horizontal scale**: add machines, get capacity, with no per-service rewiring.

One switch in `.env` picks the shape:

| `MULTI_NODE` | What you get | Prereqs |
|---|---|---|
| `false` (default) | **k3d** — k3s inside Docker on *this* machine. Dev/demo. Same "one command" model as Minikube. | Docker + `k3d` + `kubectl` |
| `true` | A real **k3s server** (control plane) on one Linux host; every other machine (EC2, spare box, another cloud) joins as a worker with one command. | server: Linux + `curl` + `sudo` · worker: Linux + `curl` + `sudo` **only** |

A joined worker installs **only the k3s agent** (~100 MB, its own containerd) —
no Docker, no k3d, no kubectl. Services on different machines talk via the same
`svc.namespace.svc.cluster.local` DNS; the overlay network makes machine location
invisible. Scaling a service = raise its replica count; the scheduler spreads
pods across every node.

See [architecture.txt](architecture.txt) for the full design and file manifest.

## Phase 0 - Substrate

Brings up the ground everything else stands on:

- the **cluster** (k3d, or k3s server + joinable workers), Traefik disabled (Kong later)
- **local-path** as the default StorageClass (PVCs bind with no annotation)
- the `platform` / `data` / `app` **namespaces**
- an image path: k3d's **built-in registry** (single-machine), or public registries
  (multi-node) — the real authenticated in-cluster registry lands in Phase 5
- a **secrets convention** (no Kubernetes secrets yet; stable entrypoint for later phases)

---

## Mode A — single machine (`MULTI_NODE=false`)

```bash
git clone <this-repo> backbone && cd backbone
cp .env.example .env          # defaults work locally; change ports if 8080 / 5001 are taken

make phase0                   # cluster -> base -> secrets -> verify   => "PHASE 0 OK"
make down                     # delete the k3d cluster when done
```

Install k3d if needed: `brew install k3d` /
`curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash` /
`choco install k3d`.

### Registry: two names, one registry

| From | Use |
|------|-----|
| your machine (`docker push`) | `localhost:5001/<img>:<tag>` |
| image refs in k8s manifests / CI | `backbone-registry:5000/<img>:<tag>` |

Host port and in-cluster port may differ (macOS holds `:5000`, so the host port
defaults to `5001`); k3d injects the `backbone-registry` hostname into every node.

---

## Mode B — many machines (`MULTI_NODE=true`)

**On the control-plane machine** (a Linux VM / bare metal / EC2):

```bash
cp .env.example .env
# set:  MULTI_NODE=true
#       K3S_SERVER_ADDR=<ip or DNS every worker can reach>
#       NODE_EXTERNAL_IP=<same public ip>   # only if workers are on another network
#       WIREGUARD=true                      # encrypts node-to-node; keep for cross-network

make phase0                                 # installs the k3s server => "PHASE 0 OK"
```

**Add a worker** — either from the server over SSH:

```bash
make node-join TARGET=ubuntu@<worker-ip>
```

…or run this *on the worker itself* (copy the repo or just `scripts/`):

```bash
K3S_URL=https://<server>:6443 K3S_TOKEN=<token> ./scripts/node-join.sh
```

(the server prints the exact command, and caches the token to
`.secrets/cluster-join.env`, gitignored).

Confirm: `kubectl get nodes -L backbone.dev/role` shows every machine `Ready`.

### Firewall — open BETWEEN nodes only

| Port | Purpose |
|------|---------|
| `6443/tcp` | Kubernetes API (workers → server) |
| `10250/tcp` | kubelet (all ↔ all) |
| `51820/udp` | flannel WireGuard (`WIREGUARD=true`) |
| `8472/udp` | flannel VXLAN (`WIREGUARD=false`, trusted network only) |

On AWS: one security group that references itself. Public traffic reaches the
platform through Kong (Phase 2), **not** these ports.

### Tear down

```bash
make down                                        # uninstalls the k3s server on this host
# on EACH worker:
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

---

## What "done" looks like

`make verify` asserts, exiting non-zero on the first failure:

1. all nodes `Ready`
2. exactly one default StorageClass, and it is `local-path`
3. namespaces `platform`, `data`, `app` exist (with their `default` ServiceAccount)
4. a throwaway 1Gi PVC binds and mounts
5. image pull works —
   - **k3d:** push to `localhost:<REGISTRY_PORT>` then pull in-cluster as `backbone-registry:5000/...`
   - **k3s:** every node pulls and runs a test image

Success = the final `PHASE 0 OK` line and `make` exiting `0`.

## Files

| Path | Purpose |
|------|---------|
| `.env.example` | config template → copy to `.env` (gitignored); `MULTI_NODE` + a block per mode |
| `config/k3d-cluster.yaml` | k3d cluster definition (single-machine mode) |
| `k8s/base/namespaces.yaml` | `platform` / `data` / `app` |
| `k8s/base/storageclass.yaml` | desired default StorageClass (applied via `kubectl patch`) |
| `scripts/lib.sh` | shared `.env` loader / helpers |
| `scripts/cluster-up.sh` | bring up the cluster — branches on `MULTI_NODE` |
| `scripts/node-join.sh` | join a machine as a k3s worker (local or SSH) |
| `scripts/cluster-down.sh` | tear down — branches on `MULTI_NODE` |
| `scripts/create-secrets.sh` | stable secrets entrypoint (no-op in Phase 0) |
| `scripts/verify-phase0.sh` | the acceptance gate |
| `docs/secrets.md` | namespace map, naming, Sealed Secrets upgrade path |

## Security notes

- `.env`, `./kubeconfig`, the rendered k3d config, and `.secrets/` (the cluster
  join token) are gitignored. Nothing sensitive is committed.
- Scripts run `set -euo pipefail` and never echo secret values.
- Node-to-node traffic is WireGuard-encrypted by default in multi-node mode.
- The k3d registry is unauthenticated **by design** (local to your machine).
  Phase 5 introduces the real authenticated registry behind Kong + TLS for both modes.
