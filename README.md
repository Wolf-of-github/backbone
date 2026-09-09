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
| nodes on different networks, this machine has **no** public IP (home box, NAT) | this machine's Tailscale IP (`tailscale ip -4`) | `TAILSCALE=true` (keep `WIREGUARD=true`) |

Defaults (`TAILSCALE=false`, `WIREGUARD=true`) are right for the first three
rows. For the Tailscale row, `tailscale` must be installed and `sudo tailscale up`
already run on this machine — and keep `WIREGUARD=true`: the k3s scripts then
pin the node to `tailscale0` (`--node-ip` / `--flannel-iface`) and run the pod
overlay as WireGuard over the tunnel. (Plain VXLAN over Tailscale is unreliable.)

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
TAILSCALE=true \                        # only if the cluster is Tailscale-based
./scripts/node-join.sh
```

---

### Firewall (multi-node only)

Open **between nodes** (e.g. one cloud security group referencing itself):

| Port | For |
|---|---|
| `6443/tcp` | Kubernetes API — workers → control plane |
| `10250/tcp` | kubelet — all nodes ↔ all nodes |
| `51820/udp` | pod network (WireGuard) — `WIREGUARD=true` (the default) |
| `8472/udp` | pod network (VXLAN) — `WIREGUARD=false` |

You need **exactly one** of the two pod-network ports, matching `WIREGUARD`.
Open neither and cross-node pods + in-cluster DNS silently time out (100% packet
loss, no error) — this is the most common bring-up failure.

**Over Tailscale you still need the pod-network port.** Tailscale usually
negotiates a *direct* connection between cloud VMs, so that UDP rides the nodes'
public IPs and hits the cloud security group anyway. Allow `51820/udp` (or
`8472/udp`) from the tailnet CIDR `100.64.0.0/10`. Only `6443` / `10250` reliably
ride the tunnel unaided.

After a join, sanity-check the overlay by hand:

```bash
kubectl run a --image=nicolaka/netshoot --restart=Never \
  --overrides='{"spec":{"nodeName":"<the-worker-node>"}}' -it --rm -- \
  ping -c3 <IP-of-any-pod-on-the-control-plane>
```

0% loss = overlay healthy. Timeouts = the port above isn't open, or (Tailscale)
the node didn't pin to `tailscale0`.

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
[5/6] MongoDB app-user round-trip OK app user does I/O on backbone; cross-DB writes and admin ops denied
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

---

## Phase 2 — Edge

Adds **Kong API Gateway** as the single public HTTP entry point, plus a minimal
**ping service** (backend) and a **React frontend** served through Kong. This
proves the full chain: Docker build → push to registry → k8s deploy → Kong
routes requests end-to-end. No auth yet (Phase 3), no TLS yet (Phase 5) — HTTP
only.

Requires Phase 0 passed (`make verify` → `PHASE 0 OK`). Phase 1 is not strictly
required (Kong/ping/frontend don't use MongoDB/Redis yet), but recommended to
have the full stack.

### 1. Set the registry URL

Edit `.env` and set **`REGISTRY_URL`** in the Phase 2 block. This is where
your built images are pushed (until Phase 5 brings up the in-cluster registry).

```bash
# Examples:
REGISTRY_URL=docker.io/youruser        # Docker Hub
REGISTRY_URL=ghcr.io/youruser          # GitHub Container Registry
```

**Then authenticate Docker** on the control-plane host:

```bash
docker login                                      # Docker Hub
# or
docker login ghcr.io                              # GitHub (needs a PAT with write:packages)
```

If using a **private** registry, create a pull secret (Phase 5 automates this):

```bash
kubectl -n app create secret docker-registry registry-credentials \
  --docker-server=<registry> \
  --docker-username=<user> \
  --docker-password=<token>
```

### 2. Build and deploy

```bash
make phase2
```

**Does, in order:**

| Sub-step | What happens |
|---|---|
| `make edge` → `build-push.sh` | builds `ping` and `frontend` Docker images (multi-stage), tags with git SHA + `latest`, pushes both to `REGISTRY_URL` |
| `make edge` → Kong | applies `k8s/platform/kong/*` — ConfigMap (declarative routes), Deployment (2 replicas, DB-less mode), proxy Service (NodePort 30080), admin Service (ClusterIP only) |
| `make edge` → ping | applies `k8s/app/ping/*` — Deployment (2 replicas), Service (ClusterIP) |
| `make edge` → frontend | applies `k8s/app/frontend/*` — Deployment (2 replicas, NGINX serving the built React SPA), Service (ClusterIP) |
| `make verify-phase2` | runs end-to-end checks (below) |

**Expect** the run to end with:

```
[1/5] Checking Kong deployment...              OK Kong deployment ready (2/2)
[2/5] Checking ping and frontend deployments...OK Ping and frontend deployments ready (2/2 each)
[3/5] Checking Kong proxy Service...           OK Kong proxy endpoint: http://<node-ip>:30080
[4/5] Testing end-to-end HTTP routing...       OK /api/ping returns ok
                                                OK Frontend (/) returns HTML
[5/5] Verifying Kong Admin API is ClusterIP... OK Kong Admin API is accessible from inside the cluster

PHASE 2 OK

Access your platform:
  Frontend: http://<node-ip>:30080/
  Ping API: http://<node-ip>:30080/api/ping
```

**Note:** The node IP shown is the first **Ready** node (skips down nodes).

### 3. Access the platform

**From your browser** (if the control plane has a public IP or is reachable):

```
http://<control-plane-public-ip>:30080/
```

You should see the React frontend ("Backbone - Phase 2") with a green message:
`Backend status: ok (pong)`. This proves Kong routed `/` to the frontend and
the frontend's fetch to `/api/ping` worked through Kong.

**From the command line:**

```bash
# Get the public endpoint
ENDPOINT=$(kubectl -n platform get svc kong-proxy -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True")) | .status.addresses[] | select(.type=="InternalIP") | .address' | head -1)

# Test the ping API
curl http://${NODE_IP}:${ENDPOINT}/api/ping
# {"status":"ok","timestamp":...,"message":"pong"}

# Test the frontend
curl http://${NODE_IP}:${ENDPOINT}/
# <html>...</html> (React SPA)
```

### Kong control wrapper

```bash
./scripts/kongctl.sh health    # Kong health status
./scripts/kongctl.sh routes    # List configured routes
./scripts/kongctl.sh reload    # Instructions for reloading declarative config
```

### Rebuild and redeploy

After changing code in `services/ping/` or `services/frontend/`:

```bash
make build-push      # Rebuild images and push
kubectl -n app rollout restart deployment/ping deployment/frontend
```

After changing Kong config (`k8s/platform/kong/kong-configmap.yaml`):

```bash
kubectl apply -f k8s/platform/kong/kong-configmap.yaml
kubectl -n platform rollout restart deployment/kong
```

### Troubleshooting

| Symptom | Check |
|---|---|
| `build-push.sh`: `repository name must be lowercase` | `REGISTRY_URL` in `.env` must be all lowercase |
| `docker push` fails with `unauthorized` | run `docker login` (or `docker login ghcr.io` for GitHub) |
| Kong pods `OOMKilled` or `CrashLoopBackOff` | increase memory limit in `k8s/platform/kong/deployment.yaml` to `1Gi` or higher |
| `make verify-phase2` hangs on "Testing /api/ping" | a node is down — script only uses Ready nodes, but may be slow; check `kubectl get nodes` |
| Frontend loads but shows error fetching `/api/ping` | check Kong routes with `./scripts/kongctl.sh routes`; check ping pods are Running |
| `ImagePullBackOff` on ping or frontend | `REGISTRY_URL` is wrong, or images weren't pushed, or (private registry) the `registry-credentials` secret is missing |

---

## Phase 3 — Auth

Adds **JWT-based authentication** via a dedicated auth service. Users register and login to get RS256-signed access tokens (15 min) and refresh tokens (7 days). The auth service stores users in MongoDB and refresh tokens in Redis. Protected routes (like `/api/ping`) now require a valid JWT. The frontend gains login/register forms with automatic token refresh.

**Architecture note:** Kong routes requests without authentication at the gateway level. Backend services verify JWT tokens themselves using shared middleware (`services/common/authContext.js`) for maximum flexibility and service autonomy.

Requires Phase 0, Phase 1, and Phase 2 complete (`make verify`, `make verify-phase1`, `make verify-phase2` all pass).

### 1. Configure JWT settings

Edit `.env` and fill the **Phase 3 — Auth** block:

| Variable | Set to |
|---|---|
| `JWT_ACCESS_EXPIRY` | `15m` (or your preferred short-lived token duration) |
| `JWT_REFRESH_EXPIRY` | `7d` (or your preferred refresh token duration) |
| `FRONTEND_URL` | The Kong proxy public endpoint from Phase 2 (e.g., `http://100.64.195.64:30080`) |

JWT keypair (RS256, 2048-bit) is auto-generated by `scripts/jwt-keys.sh` and stored in `.secrets/jwt/` (gitignored).

### 2. Deploy Phase 3

```bash
make phase3
```

**Does, in order:**

| Sub-step | What happens |
|---|---|
| `make auth` → `jwt-keys.sh` | Generates RS256 keypair if not present, creates `jwt-keypair` secret (app ns) for auth service signing |
| `make auth` → `bootstrap-auth.sh` | Creates `auth-config` ConfigMap, updates Kong with auth routes, builds and pushes auth service image, deploys auth service, rebuilds ping (with auth middleware) and frontend (with login/register UI) |
| `make verify-phase3` | Runs 8 end-to-end checks (below) |

**Expect** the run to end with:

```
[1/8] Auth Deployment status             OK Auth deployment ready (2/2)
[2/8] JWT secrets                        OK JWT secrets present
[3/8] User registration                  OK Registration successful
[4/8] User login and token issuance      OK Login successful, tokens issued
[5/8] Token verification (/api/auth/me)  OK /api/auth/me with token returns 200
                                          OK /api/auth/me without token returns 401
[6/8] Protected route (/api/ping)        OK /api/ping requires valid token
[7/8] Token refresh and rotation         OK Token refresh works, single-use enforced
[8/8] Logout and token revocation        OK Logout successful, token revoked

PHASE 3 OK
```

`PHASE 3 OK` **and** the command exiting `0` means success.

### 3. Use authentication

**From your browser:**

```
http://<kong-proxy-ip>:30080/
```

You'll see the login page. Click "Register" to create an account, then login. Once authenticated, you'll see the logged-in UI with the `/api/ping` result (now includes your user email).

**Endpoints:**

- `POST /api/auth/register` - Create new user (email + password ≥8 chars)
- `POST /api/auth/login` - Get access token + refresh token
- `POST /api/auth/refresh` - Rotate tokens (single-use)
- `POST /api/auth/logout` - Revoke refresh token
- `GET /api/auth/me` - Get current user (requires Bearer token)
- `GET /api/ping` - Now requires authentication (returns user info)

**Token flow:**

1. User registers → 201
2. User logs in → receives `accessToken` (15 min) + `refreshToken` (7 days)
3. Frontend stores tokens in localStorage
4. All `/api/*` requests include `Authorization: Bearer <accessToken>`
5. When access token expires (15 min), frontend auto-refreshes using refresh token
6. Refresh token is single-use → old token revoked, new tokens issued
7. Logout revokes the refresh token → user must login again

### 4. Protect new services

To add auth to a new backend service:

1. **Copy the shared auth middleware:**
   ```bash
   # In your service's Dockerfile (assuming repo root build context):
   COPY --chown=appuser:appgroup services/common ./src/common
   ```

2. **Add jsonwebtoken dependency:**
   ```json
   // package.json
   "dependencies": {
     "jsonwebtoken": "^9.0.2"
   }
   ```

3. **Require auth on routes:**
   ```javascript
   const { requireAuth } = require('./common/authContext');

   app.get('/api/your-endpoint', requireAuth, (req, res) => {
     // req.user = { id, email, roles }
     res.json({ user: req.user });
   });
   ```

4. **For role-based access:**
   ```javascript
   const { requireRole } = require('./common/authContext');

   app.post('/api/admin/action', requireRole('admin'), (req, res) => {
     // Only users with 'admin' role can access
   });
   ```

5. **Prevent IDOR (cross-user access):**
   ```javascript
   const { assertOwnership } = require('./common/authContext');

   app.get('/api/resource/:id', requireAuth, async (req, res) => {
     const resource = await Resource.findById(req.params.id);
     assertOwnership(req, resource.ownerId); // Throws 403 if mismatch
     res.json(resource);
   });
   ```

### Rotating JWT keys

```bash
rm -rf .secrets/jwt/                    # Delete old keys
make jwt-keys                            # Generate new keypair
kubectl -n app rollout restart deployment/auth   # Restart auth service
```

All existing tokens will be invalidated.

### Troubleshooting

| Symptom | Check |
|---|---|
| Auth pod stuck `Pending` | Check Phase 1 MongoDB/Redis are healthy: `kubectl -n data get statefulset` |
| `jwt-keys.sh` fails | Ensure `openssl` is installed: `which openssl` |
| Login returns 500 | Check auth pod logs: `kubectl -n app logs -l app=auth --tail=50` |
| Login works but `/api/ping` returns 401 | Ping service didn't rebuild with auth middleware — run `make auth` again |
| Frontend shows login page but can't register/login | Check FRONTEND_URL in auth-config ConfigMap matches Kong proxy address |
| Token refresh fails | Refresh tokens stored in Redis — check Redis is healthy: `kubectl -n data get statefulset/redis` |
| All tokens rejected after restart | JWT keys changed — run `make jwt-keys` to regenerate from `.secrets/jwt/` |

---
