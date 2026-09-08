# backbone

A from-scratch, fully self-hosted platform substrate built for **horizontal
scale**: stand up one control-plane machine, then join as many worker machines
as you need — the scheduler spreads your pods across all of them, and services
find each other by DNS regardless of which machine they land on.

**Linux only.** `make cluster` installs a k3s server on the host; workers install
only the k3s agent. Any laptop can drive the cluster afterward by pointing
`kubectl` at `./kubeconfig` — nothing is installed on the laptop.

See [architecture.txt](architecture.txt) for the full design and file manifest.

## Phase 0 - Substrate

- the **control plane**: a k3s server (embedded etcd, HA-ready), Traefik disabled (Kong later)
- **workers**: any Linux box joins with one command
- **local-path** as the default StorageClass (PVCs bind with no annotation)
- the `platform` / `data` / `app` **namespaces**
- WireGuard-encrypted node-to-node overlay by default

The authenticated in-cluster image registry arrives in Phase 5 (behind Kong +
TLS); until then, pods pull from public registries.

## Prerequisites

| Machine | Needs |
|---|---|
| control-plane host | Linux, `curl`, `sudo`, `kubectl` |
| each worker | Linux, `curl`, `sudo` — **nothing else** (no Docker, no kubectl) |
| your laptop (optional, to drive the cluster) | `kubectl` + a copy of `./kubeconfig` |

A small always-on Linux VM (cheap EC2 / VPS / home server) is the natural
control-plane host.

## Bring up the control plane

```bash
git clone <this-repo> backbone && cd backbone
cp .env.example .env
$EDITOR .env
#   K3S_SERVER_ADDR = ip or DNS every worker can reach
#   NODE_EXTERNAL_IP = the server's public ip   (only if workers are on another network)
#   WIREGUARD = true                            (keep for cross-network)

make phase0        # cluster -> base -> secrets -> verify   => "PHASE 0 OK"
```

`make phase0` runs, in order:

| Step | Command | Does |
|---|---|---|
| `make cluster` | `scripts/cluster-up.sh` | `curl https://get.k3s.io \| sh -` with server flags; writes `./kubeconfig`; caches the join token to `.secrets/cluster-join.env` |
| `make base` | `kubectl apply` + `kubectl patch` | namespaces `platform`/`data`/`app`; marks `local-path` default |
| `make secrets` | `scripts/create-secrets.sh` | no-op in Phase 0 (stable entrypoint) |
| `make verify` | `scripts/verify-phase0.sh` | the acceptance gate below |

Then, for ad-hoc `kubectl`: `export KUBECONFIG=$PWD/kubeconfig`.

## Add a worker machine

**Option 1 — from the control-plane host, over SSH:**

```bash
make node-join TARGET=ubuntu@<worker-ip>
```

**Option 2 — on the worker itself** (copy the repo, or just `scripts/`):

```bash
K3S_URL=https://<server>:6443 K3S_TOKEN=<token> ./scripts/node-join.sh
```

(the server prints the exact command; the token is in
`.secrets/cluster-join.env`, or `sudo cat /var/lib/rancher/k3s/server/node-token`).

Confirm: `kubectl get nodes -o wide -L backbone.dev/role` — every machine `Ready`.

### Firewall — open BETWEEN nodes only

| Port | Purpose |
|------|---------|
| `6443/tcp` | Kubernetes API (workers → server) |
| `10250/tcp` | kubelet (all ↔ all) |
| `51820/udp` | flannel WireGuard (`WIREGUARD=true`, default) |
| `8472/udp` | flannel VXLAN (`WIREGUARD=false`, trusted network only) |

On AWS: one security group that references itself. Public traffic reaches the
platform through Kong (Phase 2), **not** these ports.

## Scaling

- **More pods:** `kubectl scale deploy/<name> --replicas=N`, or let an HPA do it.
  The scheduler places them across every node with capacity.
- **More capacity:** join another worker (above). No reconfiguration — existing
  Services and Deployments are untouched.
- **A worker dies:** its pods reschedule onto the others. (The server is a single
  point of failure until Phase 6 adds 3-server etcd HA.)

## What "done" looks like

`make verify` asserts, exiting non-zero on the first failure:

1. all nodes `Ready`
2. exactly one default StorageClass, and it is `local-path`
3. namespaces `platform`, `data`, `app` exist (with their `default` ServiceAccount)
4. a throwaway 1Gi PVC binds and mounts
5. every node can pull and run a test image

Success = the final `PHASE 0 OK` line and `make` exiting `0`.

## Tear down

```bash
make down                                    # uninstalls the k3s server on this host
# on EACH worker:
sudo /usr/local/bin/k3s-agent-uninstall.sh
```

To stop without uninstalling: `sudo systemctl stop k3s` (server) /
`sudo systemctl stop k3s-agent` (worker); `systemctl start` to resume.

## Files

| Path | Purpose |
|------|---------|
| `.env.example` | config template → copy to `.env` (gitignored) |
| `k8s/base/namespaces.yaml` | `platform` / `data` / `app` |
| `k8s/base/storageclass.yaml` | desired default StorageClass (applied via `kubectl patch`) |
| `scripts/lib.sh` | shared `.env` loader / helpers |
| `scripts/cluster-up.sh` | install the k3s server, write `./kubeconfig`, cache the join token |
| `scripts/node-join.sh` | join a machine as a k3s worker (local or SSH) |
| `scripts/cluster-down.sh` | uninstall the k3s server on this host |
| `scripts/create-secrets.sh` | stable secrets entrypoint (no-op in Phase 0) |
| `scripts/verify-phase0.sh` | the acceptance gate |
| `docs/secrets.md` | namespace map, naming, Sealed Secrets upgrade path |

## Security notes

- `.env`, `./kubeconfig`, and `.secrets/` (the cluster join token) are gitignored.
  Nothing sensitive is committed.
- Scripts run `set -euo pipefail` and never echo secret values.
- Node-to-node traffic is WireGuard-encrypted by default.
- The join token grants node membership — guard it like a password.
