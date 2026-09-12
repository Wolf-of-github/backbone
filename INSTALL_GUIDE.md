# Backbone — Installation Guide

First-time install walkthrough, tested end-to-end as it's written.

Each step follows the same structure: **what** we're doing and why, **how**
to do it, and **what success looks like** before moving on.

---

## What you're building

Everything below runs on **one EC2 instance** acting as a single-node k3s
cluster. Inside it, workloads are split into namespaces by role. This
diagram reflects Phases 0-4 (substrate through async jobs) — later phases
(TLS, observability, backup, maintenance mode) layer on top without changing
this shape.

```
EC2 instance (t3.large, Ubuntu) -- single-node k3s cluster
============================================================

  internet
    |
    | :30080
    v
  [ namespace: platform ]
    Kong (API gateway)
      - route  /       -> frontend
      - route  /api/*  -> ping / auth / jobs-api  (by path)
    |
    v
  [ namespace: app ]
    frontend   (React/NGINX, serves the SPA)
    auth       (JWT issue + verify)
    ping       (example protected endpoint)
    jobs-api   (enqueues jobs)          --enqueues-->  worker
    worker     (BullMQ consumer, HPA 1-10 replicas)
    |
    v
  [ namespace: data ]
    MongoDB  (StatefulSet, 1 replica, PVC)  -- users, job records
    Redis    (StatefulSet, 1 replica, PVC)  -- sessions, BullMQ queue

  StorageClass: local-path (default) -- backs every PVC above

============================================================
Not yet in this picture (later phases):
  platform ns   += cert-manager (5A/TLS), maintenance page (6B)
  observability ns -- Prometheus / Loki / Grafana / Alertmanager (5B)
  ci ns         -- Gitea + Drone (5C, deferred by choice -- not deployed)
```

**Reading it:**
- One arrow in from the internet, on Kong's NodePort (`:30080`). Kong is the
  *only* thing anything outside the cluster ever talks to.
- Kong routes `/` to `frontend` and `/api/*` to whichever backend service
  owns that path — it does **not** check JWTs itself (see Phase 3 note in
  README); each backend service verifies its own tokens.
- `worker` is a separate Deployment from `jobs-api` — `jobs-api` only
  enqueues jobs into Redis; `worker` is what actually pulls and runs them,
  and it's the one thing that autoscales (HPA, 1-10 replicas).
- Everything that needs to persist state (MongoDB, Redis) lives in the
  `data` namespace on its own PVC, backed by the `local-path` StorageClass
  from Phase 0 — nothing else in the diagram writes to disk.

---

## Step 1 — Provision the EC2 instance

**What:** backbone needs a real Linux host to install onto — a control-plane
machine running k3s plus every service in the stack (database, cache,
gateway, auth, workers, monitoring). We provision that host first.

**How:**
1. Launch one EC2 instance:
   - **Instance type:** `t3.large` (2 vCPU / 8 GB RAM) — the full stack
     needs more than the bare-minimum size once everything is deployed.
   - **AMI:** Ubuntu 22.04 LTS+
   - **Storage:** 20 GB gp3 (default 8 GB fills up fast)
   - **Security group:** inbound `22/tcp` (SSH) only for now
2. Note the instance's public (or private, if using VPN/Tailscale) IP —
   needed for `K3S_SERVER_ADDR` in Step 2.
3. SSH in and confirm base tools:
   ```bash
   ssh -i your-key.pem ubuntu@<instance-ip>
   curl --version
   sudo -v
   ```

**Success looks like:** you have an SSH session open on the instance, and
both `curl --version` and `sudo -v` return without errors (no install
needed on stock Ubuntu).

> **Dev note:** README.md's stated minimum (1 vCPU/1GB) covers bare Phase 0
> only. Full stack requests ~1.5 vCPU/3GB before overhead — update that line
> before shipping this guide.

---

## Step 2 — Clone the repo and configure `.env`

**What:** every script in backbone reads its configuration from a single
`.env` file at the repo root. We clone the repo and set the one value that's
required before anything can be installed: the address the cluster will be
reachable at.

**How:**
1. Clone on the EC2 instance:
   ```bash
   git clone https://github.com/Wolf-of-github/backbone.git
   cd backbone
   cp .env.example .env
   ```
2. Set the one required value, `K3S_SERVER_ADDR`, to this instance's private
   IP. For a single all-in-one instance (this guide's setup), don't hand-edit
   `.env` in a text editor — it's easy to open the file, mean to fill it in,
   and leave the session without actually saving. Use this instead, which
   both gets the IP and writes it in one step:
   ```bash
   MY_IP=$(hostname -I | awk '{print $1}')
   sed -i "s/^K3S_SERVER_ADDR=.*/K3S_SERVER_ADDR=$MY_IP/" .env
   ```
   Leave `TAILSCALE=false` and `WIREGUARD=true` (defaults) — there's only one
   node, so no cross-node traffic to encrypt yet.

**Success looks like:** running
   ```bash
   grep K3S_SERVER_ADDR .env
   ```
   shows a real dotted IP address on the `K3S_SERVER_ADDR=` line — not blank,
   and not a placeholder like `<private-ip>`. Confirm this before moving on;
   a blank value here surfaces later as a confusing error in Step 3
   (`ERROR .env is missing required values: K3S_SERVER_ADDR`), not here.

> **Dev note:** `.env.example` documents `K3S_SERVER_ADDR` as "reachable from
> each machine you intend to join," which is correct for multi-node but reads
> ambiguous for someone doing a single-node install — worth a one-line example
> for the "just me, one box" case in the template itself.

---

## Step 3 — Bring up the control plane

**What:** this is the first step that actually installs anything. `make
phase0` installs the k3s server itself (the Kubernetes control plane),
creates the `platform` / `data` / `app` namespaces the rest of the stack
deploys into, and then runs a verification gate that checks the cluster is
actually healthy — not just that the install command exited without error.

No secrets to set up yet — Phase 0 creates zero Kubernetes secrets (`make
secrets` is a no-op placeholder here). The only credential this step
produces is the k3s worker join token, which is generated and cached
automatically; you don't create or supply anything. Real secrets (database
passwords) start at Step 4.

**How:**
```bash
make phase0
```
This chains four sub-steps automatically: `make cluster` (installs k3s,
writes `./kubeconfig`, caches a worker join token you won't need on a
single-node setup), `make base` (creates the namespaces, sets `local-path`
as the default StorageClass), `make secrets` (a no-op placeholder in Phase
0), and `make verify` (the acceptance checks).

**Success looks like:** the command ends with, and exits `0`:
```
[1/5] nodes Ready                 OK 1 node(s) Ready
[2/5] default StorageClass        OK default StorageClass = local-path
[3/5] namespaces                  OK namespaces platform, data, app present
[4/5] PVC binds                   OK test PVC bound and mounted
[5/5] every node can pull images  OK 1 node(s) pulled and ran a test image

PHASE 0 OK
```
Confirm independently:
```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes        # one node, STATUS = Ready
kubectl get ns           # platform, data, app present
```

**Want to look closer?** If you're curious what Phase 0 actually put on the
machine (not required to proceed — just for understanding what you now have):
```bash
kubectl get nodes -o wide        # the one node: role, k3s version, internal IP
kubectl get ns                   # should show only platform, data, app
                                  #   (plus default / kube-system / kube-public / kube-node-lease)
                                  #   observability and ci do NOT exist yet — they're created in Phase 5
kubectl get pods -A              # system pods only: coredns, local-path-provisioner, metrics-server
                                  #   no application pods yet — that starts in Phase 1
kubectl get sc                   # local-path, marked (default)
```
If `kubectl get ns` shows `observability` or `ci` at this point, that's stale
state from before a namespace-manifest fix made during this install — clean
it up with:
```bash
kubectl delete ns observability ci
make base
```

> **Known hiccup (documented in README):** if `make cluster` fails with `no
> matching resources found`, the node object just hadn't registered yet when
> the check ran — the cluster is fine. Re-run `make base && make verify`.

> **Bug found during this install:** `make phase0` failed immediately with
> `.env: line 232: 3: command not found`, exit 127. `.env` is sourced
> directly as a bash script (`scripts/lib.sh`), and `.env.example` shipped
> two unquoted cron expressions —
> `BACKUP_SCHEDULE_MONGO=0 3 * * *` — which bash parses as a command (`0`)
> with arguments, not a string. Fixed in `.env.example` by quoting both
> values. If your `.env` was copied before this fix, patch it the same way:
> ```bash
> sed -i 's/^BACKUP_SCHEDULE_MONGO=0 3 \* \* \*/BACKUP_SCHEDULE_MONGO="0 3 * * *"/' .env
> sed -i 's/^BACKUP_SCHEDULE_REDIS=0 4 \* \* \*/BACKUP_SCHEDULE_REDIS="0 4 * * *"/' .env
> ```
> then re-run `make phase0`.

> **Bug found during this install:** `kubectl get ns` after a clean Phase 0
> showed `observability` and `ci` namespaces already present — both should
> only exist starting Phase 5, and `ci` in particular shouldn't exist at all
> right now (Phase 5C/CI-CD was deferred by choice; see HANDOFF.md).
> `k8s/base/namespaces.yaml` was creating all 5 namespaces unconditionally.
> Fixed: Phase 0 now only creates `platform`/`data`/`app`; Phase 5B creates
> its own `observability` namespace when it runs. If you already ran Phase 0
> before this fix, clean up the extra namespaces (see "Want to look closer?"
> above).

---

## Step 4 — Bring up the data layer

**What:** `make phase1` deploys MongoDB and Redis — the two datastores every
later phase (auth, job queue) depends on — as single-replica StatefulSets in
the `data` namespace, each backed by persistent storage. Before it can run,
it needs six credential values in `.env`. `data-secrets.sh` refuses to
create anything if any of these are blank, rather than silently generating
one for you — you're expected to set and record them yourself.

**How:**

Generate and write all six values in one step (don't hand-edit `.env` for
this — same reasoning as Step 2: an interactive edit is easy to leave
unsaved):
```bash
MONGO_ROOT_PW=$(openssl rand -base64 24)
MONGO_APP_PW=$(openssl rand -base64 24)
REDIS_PW=$(openssl rand -base64 24)

sed -i "s|^MONGO_ROOT_PASSWORD=.*|MONGO_ROOT_PASSWORD=$MONGO_ROOT_PW|" .env
sed -i "s|^MONGO_APP_PASSWORD=.*|MONGO_APP_PASSWORD=$MONGO_APP_PW|" .env
sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$REDIS_PW|" .env

echo "MONGO_ROOT_PASSWORD=$MONGO_ROOT_PW"
echo "MONGO_APP_PASSWORD=$MONGO_APP_PW"
echo "REDIS_PASSWORD=$REDIS_PW"
```
**Save that last block's output somewhere safe right now** (a password
manager, not just your terminal scrollback) — nothing regenerates or prints
these again, and losing them means losing access to the data.

`MONGO_ROOT_USER`, `MONGO_APP_USER`, and `MONGO_APP_DB` ship with usable
defaults (`root`, `backbone_app`, `backbone`) — leave them as-is unless you
have a reason to change them.

Then deploy:
```bash
make phase1
```
This runs, in order: `data-secrets.sh` (creates the `mongodb-credentials`
and `redis-password` Kubernetes Secrets from `.env`), the Redis
StatefulSet, the MongoDB StatefulSet + a one-shot init Job (creates the
least-privilege app user/DB), then `verify-phase1.sh`.

**Success looks like:** before running `make phase1`, confirm none of the
six values are blank:
```bash
grep -E "^(MONGO_ROOT_USER|MONGO_ROOT_PASSWORD|MONGO_APP_USER|MONGO_APP_PASSWORD|MONGO_APP_DB|REDIS_PASSWORD)=" .env
```
Every line should show a real value after `=` — if any is empty,
`data-secrets.sh` will fail fast with a clear message rather than silently
skip it.

Then the command ends with, and exits `0`:
```
[1/6] StatefulSets Ready          OK redis and mongodb StatefulSets Ready (1/1)
[2/6] secrets                     OK mongodb-credentials (5 keys) and redis-password (1 key) present
[3/6] PVCs Bound                  OK data-redis-0 and data-mongodb-0 Bound
[4/6] Redis auth + round-trip     OK Redis requires AUTH; SET/GET/DEL round-trip works
[5/6] MongoDB app-user round-trip OK app user does I/O on backbone; cross-DB writes and admin ops denied
[6/6] data survives a pod restart OK Redis and MongoDB data survived deleting their pods

PHASE 1 OK
```
Also confirm the Phase 0 gate still passes (Phase 1 shouldn't regress it):
```bash
make verify
```

**Want to look closer?**
```bash
kubectl -n data get statefulset,pod,pvc,secret
                                  # redis-0 and mongodb-0 Running, both PVCs Bound
                                  # secrets mongodb-credentials, redis-password present (values hidden)
kubectl -n data get svc          # headless services: redis, mongodb
```

> **Bug found during this install:** `make verify-phase1` failed at check
> [5/6] with `MongoParseError: Password contains unescaped characters`, even
> though `data-secrets.sh` and the MongoDB init Job both succeeded. Cause:
> `openssl rand -base64 24` (the exact command this guide's Step 4 tells you
> to run) routinely produces `+` and `/`, and every script that builds a
> `mongodb://user:pass@host` connection string was splicing the raw password
> in unescaped — those characters are structurally significant in a URI, so
> MongoDB's driver correctly rejected it. This wasn't a one-off: the same
> pattern existed in four scripts (`verify-phase1.sh`, `verify-phase4.sh`,
> `verify-phase6a.sh`, `migrate.sh`). Fixed by adding a shared `urlencode()`
> helper to `scripts/lib.sh` and using it everywhere a Mongo URI is built
> from `.env`/Secret values. No action needed on your end — re-run
> `make verify-phase1` after pulling the fix.

---

## Step 5 — Bring up the edge

**What:** Phase 2 adds **Kong** as the single public entry point, plus a
minimal **ping** backend and the **React frontend**, both served through
Kong. This is the first phase that builds and pushes container images —
until Phase 5 stands up an in-cluster registry, images go to a registry you
already have an account on (Docker Hub or GHCR). No auth or TLS yet (later
phases) — plain HTTP.

**How:**

1. **Install Docker.** Nothing before this step needed it — Phases 0/1 only
   touched k3s/kubectl — so if you haven't already:
   ```bash
   sudo apt-get update
   sudo apt-get install -y docker.io
   sudo usermod -aG docker $USER
   newgrp docker          # or log out/in — applies the group change now
   docker version         # confirm it works without sudo
   ```
2. **Get a place to push images to.** `make phase2` pushes built images to
   a container registry — it does not run one for you (that's Phase 5). If
   you don't already have an account on one:
   - **Docker Hub** (simplest, used below): go to
     https://hub.docker.com/signup, create a free account, note your
     **username**. Then create an access token instead of using your account
     password directly — Account Settings → Security → **New Access
     Token** → give it Read/Write scope → copy the token (shown once).
   - GHCR is the alternative if you already have a GitHub account — see the
     note below.

3. **Put your registry username and credentials in `.env`, without opening
   an editor** (an interactive editor session is easy to leave unsaved —
   same reasoning as Steps 2 and 4):
   ```bash
   sed -i "s|^REGISTRY_URL=.*|REGISTRY_URL=docker.io/<your-dockerhub-username>|" .env
   grep REGISTRY_URL .env
   ```
   Replace `<your-dockerhub-username>` with your actual username — it must
   be **all lowercase**, or the push fails later with
   `repository name must be lowercase`.

   `docker login` is separate from `.env` — it's a Docker CLI credential,
   not something the scripts read — but the same "don't type it into a
   prompt you might fat-finger" instinct applies. Pass the token on stdin
   rather than at an interactive prompt:
   ```bash
   echo '<your-access-token>' | docker login docker.io -u <your-dockerhub-username> --password-stdin
   ```
   **Success looks like:** `Login Succeeded`.

   (For GHCR instead: `REGISTRY_URL=ghcr.io/<your-github-username>`, and
   `echo '<PAT>' | docker login ghcr.io -u <your-github-username> --password-stdin`
   with a PAT scoped to `write:packages`.)
4. **Deploy:**
   ```bash
   make phase2
   ```
   This builds and pushes the `ping` and `frontend` images, then applies
   Kong (2 replicas, DB-less declarative routing, NodePort `30080`), the
   `ping` service, and the `frontend` service, then runs the verification
   gate.

**Success looks like:**
```
[1/5] Checking Kong deployment...              OK Kong deployment ready (2/2)
[2/5] Checking ping and frontend deployments...OK Ping and frontend deployments ready (2/2 each)
[3/5] Checking Kong proxy Service...           OK Kong proxy endpoint: http://<node-ip>:30080
[4/5] Testing end-to-end HTTP routing...       OK /api/ping returns ok
                                                OK Frontend (/) returns HTML
[5/5] Verifying Kong Admin API is ClusterIP... OK Kong Admin API is accessible from inside the cluster

PHASE 2 OK
```
Then open `http://<instance-public-ip>:30080/` in a browser — you should see
the React frontend with a green "Backend status: ok (pong)" message. If the
instance's security group still only allows `22/tcp` (from Step 1), you'll
need to open inbound `30080/tcp` first, or use `curl` from the instance
itself:
```bash
curl http://localhost:30080/
curl http://localhost:30080/api/ping
```

**Want to look closer?**
```bash
kubectl -n platform get deploy,svc kong        # 2/2 ready, proxy NodePort 30080
kubectl -n app get deploy,svc ping frontend    # both 2/2 ready
./scripts/kongctl.sh routes                    # confirm / and /api/* are wired
```

---

*(Next: Step 6 — add authentication with `make phase3`.)*
