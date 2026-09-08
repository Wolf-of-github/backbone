# backbone

A from-scratch, self-hosted platform substrate on k3s. Linux only. Built for
horizontal scale: one control-plane machine, then join as many workers as you
need.

See [architecture.txt](architecture.txt) for the full design.

---

## Installation log

Real, tested commands, recorded as each piece is actually installed.

### Phase 0 - Substrate

Verified on: Ubuntu 26.04 LTS, single node `pavilion` (192.168.68.51), 15 GB RAM.

```bash
# 1. config
cp .env.example .env
sed -i "s/^K3S_SERVER_ADDR=.*/K3S_SERVER_ADDR=$(hostname -I | awk '{print $1}')/" .env

# 2. bring up the control plane  (installs k3s server -> namespaces -> verify)
make phase0
# => PHASE 0 OK

# 3. use it
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
kubectl get ns
```

Add a worker machine (any Linux box that can reach the server on 6443/tcp,
10250/tcp, 51820/udp):

```bash
# from the server, over SSH:
make node-join TARGET=user@<worker-ip>

# or, on the worker itself:
K3S_URL=https://192.168.68.51:6443 K3S_TOKEN=<.secrets/cluster-join.env> ./scripts/node-join.sh
```

Tear down:

```bash
make down                                    # uninstalls the k3s server on this host
sudo /usr/local/bin/k3s-agent-uninstall.sh   # on each worker
```
