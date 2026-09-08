# backbone

A from-scratch, self-hosted platform substrate on k3s. Linux only. Built for
horizontal scale: one control-plane machine, then join as many workers as you
need — even across networks / behind NAT, over Tailscale.

See [architecture.txt](architecture.txt) for the full design.

---

## Installation log

Real, tested commands, recorded as each piece is actually installed.

### Phase 0 - Substrate

Verified: 2-node cluster —
- `pavilion` — home VM, Ubuntu 26.04, control plane
- `ip-172-31-19-225` — AWS EC2, Ubuntu 26.04, worker
- joined over Tailscale (home VM has no public IP); `make verify` → `PHASE 0 OK`.

#### 1. Control plane (on the server)

Same-network setup — `K3S_SERVER_ADDR` = the server's LAN/VPC IP:

```bash
cp .env.example .env
sed -i "s/^K3S_SERVER_ADDR=.*/K3S_SERVER_ADDR=$(hostname -I | awk '{print $1}')/" .env
make phase0                     # k3s server -> namespaces -> verify  => PHASE 0 OK

export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
```

Cross-network setup (server behind NAT / no public IP) — use Tailscale:

```bash
# tailscale already up on this box:
tailscale ip -4                 # e.g. 100.64.195.64

cp .env.example .env
# in .env set:
#   K3S_SERVER_ADDR=100.64.195.64      (this box's tailscale IP)
#   TAILSCALE=true
#   WIREGUARD=false                    (tailscale already encrypts)
make phase0                     # => PHASE 0 OK
```

> If `make cluster` ever fails on `no matching resources found` (node object not
> registered yet), just re-run `make base && make verify` — the cluster is fine.

#### 2. Add a worker

The master does it — SSH from server to worker, install the agent there:

```bash
# one-time: let the server SSH to the worker.
#   same network: normal key auth.
#   AWS worker: put the .pem on the server and add to ~/.ssh/config:
#     Host <worker-ip>
#       User ubuntu
#       IdentityFile ~/.ssh/aws.pem
#   (or set SSH_KEY=/path/to/key.pem in .env)

# worker also needs tailscale if the cluster is Tailscale-based:
#   on the worker:  curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up

# then, from the server:
make node-join TARGET=ubuntu@<worker-tailscale-or-lan-ip>

kubectl get nodes -o wide       # worker shows Ready in ~30s
make verify                     # now reports "2 node(s) ..."  => PHASE 0 OK
```

Or run it on the worker itself (no SSH needed):

```bash
K3S_URL=https://<server-ip>:6443 \
K3S_TOKEN=<from server: .secrets/cluster-join.env> \
TAILSCALE=true WIREGUARD=false \
./scripts/node-join.sh
```

#### Tear down

```bash
make down                                    # uninstalls the k3s server on this host
sudo /usr/local/bin/k3s-agent-uninstall.sh   # on each worker
```
