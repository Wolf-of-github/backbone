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
