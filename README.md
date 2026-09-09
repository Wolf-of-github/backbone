# backbone

A from-scratch, self-hosted platform substrate on k3s. **Linux only.** Built for
horizontal scale: stand up one control-plane machine, then join as many worker
machines as you want. Nodes can be on one LAN or VPC (the common case — e.g.
several EC2s in one security group), across networks with public IPs, or behind
NAT with no public IP at all (via Tailscale). One config switch picks which.

`architecture.txt` has the full design. This file is the operator's guide:
every command, what it does, and what you should see.

---

## Phase 0 — Substrate

Gets you a running k3s cluster: a control plane, a default StorageClass so
volumes work, the `platform` / `data` / `app` namespaces, and a way to add
worker machines. Nothing application-level yet (databases, gateway, TLS come in
later phases).

### Prerequisites

| Machine | Needs |
|---|---|
| control-plane host | Linux with systemd, `curl`, `sudo`, `kubectl` |
| each worker | Linux with systemd, `curl`, `sudo` — nothing else |
| (optional) your laptop | `kubectl`, to drive the cluster remotely with the generated `./kubeconfig` |

Minimum control-plane size: 1 vCPU / 1 GB RAM / 4 GB disk. 2 GB RAM recommended.

---

### 1. Configure

```bash
cp .env.example .env
```

**Does:** creates your local config from the template. `.env` is gitignored.

Then edit `.env`. The only required setting is **`K3S_SERVER_ADDR`** — the
address workers will use to reach this machine's API server:

| Your situation | Set `K3S_SERVER_ADDR` to | Also set |
|---|---|---|
| single node | `127.0.0.1` (or the private IP) | — |
| **all nodes in one VPC / LAN** (e.g. several EC2s in one security group) | this machine's **private** IP | — |
| nodes on different networks, this machine **has** a public IP | that public IP / DNS name | — |
| nodes on different networks, this machine has **no** public IP (home box, NAT) | this machine's Tailscale IP (`tailscale ip -4`) | `TAILSCALE=true`, `WIREGUARD=false` |

Defaults (`TAILSCALE=false`, `WIREGUARD=true`) are right for the first three
rows. For the Tailscale row, `tailscale` must be installed and `sudo tailscale up`
already run on this machine.

---

### 2. Bring up the control plane

```bash
make phase0
```

**Does, in order:**

| Sub-step | What happens |
|---|---|
| `make cluster` | installs the k3s server (`curl https://get.k3s.io \| sh -`), writes `./kubeconfig`, caches a worker join token to `.secrets/cluster-join.env` |
| `make base` | creates namespaces `platform` / `data` / `app`; marks `local-path` the default StorageClass |
| `make secrets` | nothing yet — a stable hook for later phases |
| `make verify` | runs the acceptance checks (below) |

**Expect:** ~30–90 s, ending with:

```
[1/5] nodes Ready                 OK 1 node(s) Ready
[2/5] default StorageClass        OK default StorageClass = local-path
[3/5] namespaces                  OK namespaces platform, data, app present
[4/5] PVC binds                   OK test PVC bound and mounted
[5/5] every node can pull images  OK 1 node(s) pulled and ran a test image

PHASE 0 OK
```

`PHASE 0 OK` **and** the command exiting `0` means success. Any check that fails
prints `ERROR verify-phase0: ...` and stops.

> **Known hiccup:** if `make cluster` fails with `no matching resources found`
> (the node object hadn't registered when it checked), the cluster is actually
> fine — just run `make base && make verify`.

---

### 3. Use the cluster

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
kubectl get ns
```

**Expect:** one node `Ready`; namespaces `platform`, `data`, `app`, plus the
system ones. Add `export KUBECONFIG=...` to your shell profile, or copy
`./kubeconfig` to another machine that has `kubectl`.

---

### 4. Add a worker machine

You bring up the machine yourself (a VM, a cloud instance, a spare box). Then
the control plane installs k3s on it and joins it — you don't log into the
worker.

**One-time: let the control plane SSH to the worker.**

- EC2s in one VPC (or any cloud instance with a `.pem` key): copy the key onto
  the control-plane host, then either set `SSH_KEY=/path/to/key.pem` in `.env`,
  or add to the control-plane host's `~/.ssh/config`:

  ```
  Host <worker-private-ip>
    User ubuntu
    IdentityFile ~/.ssh/<key>.pem
  ```

- Same LAN, your own key already on the worker: nothing to do.

**If the cluster is Tailscale-based**, also install Tailscale on the worker
first — on the worker: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`.

**Then, from the control-plane host** — address the worker by whatever the
control plane can reach it on (private IP in a VPC, Tailscale IP otherwise):

```bash
make node-join TARGET=<login-user>@<worker-address>
```

**Does:** SSHes to the worker, runs the k3s agent installer there with the
cached join token, starts `k3s-agent`. Nothing is installed on the worker except
the agent (it brings its own container runtime).

**Expect:** the k3s install log from the worker, then `OK join dispatched`.

**Confirm:**

```bash
kubectl get nodes -o wide
make verify
```

**Expect:** the new node `Ready` within ~30 s; `make verify` now reports
`2 node(s) ...` and ends `PHASE 0 OK`.

*Alternatively*, run it on the worker itself (no SSH from the control plane):

```bash
K3S_URL=https://<server-address>:6443 \
K3S_TOKEN=<value from the server's .secrets/cluster-join.env> \
TAILSCALE=true WIREGUARD=false \        # only if the cluster is Tailscale-based
./scripts/node-join.sh
```

---

### Firewall (multi-node only)

Open **between nodes** (e.g. one cloud security group referencing itself):

| Port | For |
|---|---|
| `6443/tcp` | Kubernetes API — workers → control plane |
| `10250/tcp` | kubelet — all nodes ↔ all nodes |
| `51820/udp` | pod network (WireGuard) — `WIREGUARD=true` |
| `8472/udp` | pod network (VXLAN) — `WIREGUARD=false` |

Over Tailscale these ride the tunnel; no cloud firewall rules needed for them.

---

### Scaling

```bash
kubectl scale deploy/<name> --replicas=<n>   # more copies, spread across nodes
```

Out of capacity? Add another worker (step 4) — existing services are untouched.

---

### Stop / tear down

```bash
sudo systemctl stop k3s          # control plane: stop without uninstalling
sudo systemctl stop k3s-agent    # worker: same
```

```bash
make down                                     # control plane: uninstall k3s
sudo /usr/local/bin/k3s-agent-uninstall.sh    # run on each worker
```

**Expect:** `make down` removes the k3s server, `./kubeconfig`, and the cached
join token. Workers must be uninstalled on each worker.

---

### Troubleshooting

| Symptom | Check |
|---|---|
| `make cluster`: `no matching resources found` | harmless race — run `make base && make verify` |
| worker stuck `NotReady` | on the worker: `sudo journalctl -u k3s-agent -f` — usually a blocked port or unreachable server address |
| `make node-join`: `Permission denied (publickey)` | control plane can't SSH the worker — fix `~/.ssh/config` or set `SSH_KEY` in `.env` |
| need the join token again | on the control plane: `sudo cat /var/lib/rancher/k3s/server/node-token` |
| server won't start | `sudo journalctl -u k3s -f`; confirm `K3S_SERVER_ADDR` resolves and `:6443` is free |

---

## Phase 1 — Data layer

Brings up **MongoDB** and **Redis** — each a single-replica StatefulSet in the
`data` namespace, on the `local-path` default StorageClass from Phase 0. This is
what auth (Phase 3) and the async workers (Phase 4) build on. No replica sets /
HA yet (Phase 6), and nothing is exposed outside the cluster (Kong is Phase 2) —
you reach these only from pods inside the cluster.

Requires a cluster that already passed Phase 0 (`make verify` → `PHASE 0 OK`).

### 1. Set the data credentials

Edit `.env` and fill the **Phase 1 — Data layer** block:

| Variable | Set to |
|---|---|
| `MONGO_ROOT_USER` | `root` (default is fine) |
| `MONGO_ROOT_PASSWORD` | `openssl rand -base64 24` |
| `MONGO_APP_USER` | `backbone_app` (default is fine) |
| `MONGO_APP_PASSWORD` | `openssl rand -base64 24` |
| `MONGO_APP_DB` | `backbone` (default is fine) |
| `REDIS_PASSWORD` | `openssl rand -base64 24` |

**Record the three passwords somewhere safe** — `data-secrets.sh` does not
generate or print them, and losing them means losing access to the data.

### 2. Bring up the data layer

```bash
make phase1
```

**Does, in order:**

| Sub-step | What happens |
|---|---|
| `make data` → `data-secrets.sh` | creates Secrets `mongodb-credentials` (root + least-privilege app user) and `redis-password` in `data`, from `.env` |
| `make data` → Redis | applies `k8s/data/redis/*`, waits for `statefulset/redis` |
| `make data` → MongoDB | applies `k8s/data/mongodb/*`, waits for `statefulset/mongodb` |
| `make data` → init Job | runs `mongodb-init` — creates the app DB + `readWrite`-only app user |
| `make verify-phase1` | runs the acceptance checks (below) |

**Expect** the run to end with:

```
[1/6] StatefulSets Ready          OK redis and mongodb StatefulSets Ready (1/1)
[2/6] secrets                     OK mongodb-credentials (5 keys) and redis-password (1 key) present
[3/6] PVCs Bound                  OK data-redis-0 and data-mongodb-0 Bound
[4/6] Redis auth + round-trip     OK Redis requires AUTH; SET/GET/DEL round-trip works
[5/6] MongoDB app-user round-trip OK app user does I/O on backbone; admin ops denied
[6/6] data survives a pod restart OK Redis and MongoDB data survived deleting their pods

PHASE 1 OK
```

`make verify` (the Phase 0 gate) still passes — Phase 1 does not touch the substrate.

### 3. Connect from inside the cluster

```bash
# Redis
kubectl -n data run redis-cli --rm -it --restart=Never --image=redis:7.2-alpine -- \
  redis-cli -h redis.data.svc -a "$REDIS_PASSWORD"

# MongoDB (as the least-privilege app user)
kubectl -n data run mongosh --rm -it --restart=Never --image=mongo:7.0 -- \
  mongosh "mongodb://$MONGO_APP_USER:$MONGO_APP_PASSWORD@mongodb.data.svc/$MONGO_APP_DB"
```

Service DNS: `redis.data.svc.cluster.local:6379`, `mongodb.data.svc.cluster.local:27017`.

### Rotate a credential

```bash
$EDITOR .env                                    # change the value
make secrets-data                               # update the Secret object
kubectl -n data rollout restart statefulset/redis   # or mongodb — pods reload on restart
```

### Troubleshooting

| Symptom | Check |
|---|---|
| `data-secrets.sh`: `.env is missing required values` | fill every Phase 1 var in `.env` — none may be blank |
| pod stuck `Pending` | `kubectl -n data describe pod <name>` — usually the default StorageClass is missing; re-run `make base` |
| auth failures after a rotation | the Secret changed but the pod didn't restart — `kubectl -n data rollout restart statefulset/<name>` |
| `mongodb-init` Job failed | `kubectl -n data logs job/mongodb-init`; safe to re-run `make data` |
| `make verify-phase1` step 6 fails | data didn't survive a restart — check the PVCs are `Bound` and backed by `local-path` |
