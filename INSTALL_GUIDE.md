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
needed on stock Ubuntu). **Also confirm the disk is actually 20GB** before
moving on — a launch wizard defaulting back to 8GB is easy to miss, and it
will not cause a visible failure until several phases later (Phase 4's
`--no-cache` rebuilds are what finally filled an undersized disk during
this install, four steps after it was provisioned):
```bash
lsblk
```
The root disk (commonly `nvme0n1`) should show ~20G, not 8G. If it doesn't,
fix it now — in the AWS Console: EC2 → Volumes → find this instance's
volume → Modify Volume → 20GB+ → Apply. Then on the instance:
```bash
sudo growpart /dev/nvme0n1 1   # device name from lsblk - may differ
sudo resize2fs /dev/nvme0n1p1
df -h /                        # should now show ~20G
```

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

> **Stop — do this before anything else in this step.** Nothing before
> Phase 2 needed Docker (Phases 0/1 only touch k3s/kubectl), so it is almost
> certainly not installed yet. Install it now:
> ```bash
> sudo apt-get update
> sudo apt-get install -y docker.io
> sudo usermod -aG docker $USER
> newgrp docker          # or log out/in — applies the group change now
> ```
> **Success looks like:** `docker version` prints both a Client and Server
> section with no error, and no `sudo` was needed to run it. If you see
> `Command 'docker' not found`, the block above wasn't run (or wasn't run on
> this instance) — do it now before continuing; the registry login and
> `make phase2` below both fail without it.

**How:**

1. **Get a place to push images to.** `make phase2` pushes built images to
   a container registry — it does not run one for you (that's Phase 5). If
   you don't already have an account on one:
   - **Docker Hub** (simplest, used below): go to
     https://hub.docker.com/signup, create a free account, note your
     **username**. Then create an access token instead of using your account
     password directly — Account Settings → Security → **New Access
     Token** → give it Read/Write scope → copy the token (shown once).
   - GHCR is the alternative if you already have a GitHub account — see the
     note below.

2. **Put your registry username and credentials in `.env`, without opening
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
3. **Deploy:**
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

> **Bug found during this install:** `make phase2` (specifically
> `verify-phase2.sh`) failed at check [4/5] with `Failed to reach /api/ping`,
> even though Kong, ping, and frontend were all deployed and Ready. Cause:
> this repo's branches are phased (`phase-0-substrate`, `phase-1-data-layer`,
> `phase-2-edge`, …), but the documented install path is to clone and stay
> on `master`/`main` and run each `make phaseN` in order — and `master`
> already has *every* phase's code merged in, including Phase 3's auth
> middleware on `/api/ping`. So `curl /api/ping` correctly returned `401
> Unauthorized`, and the gate — written assuming Phase 2 code has no auth —
> treated that 401 as "unreachable" instead of "reachable, and correctly
> enforcing auth that Phase 3 already added." Fixed: `verify-phase2.sh` now
> accepts both `200` (no auth yet) and `401` (Phase 3's code present) as a
> pass, and only fails on a genuinely unreachable endpoint. No action needed
> on your end — re-run `make verify-phase2` after pulling the fix.
>
> **If you saw this and haven't pulled the fix yet:** `git pull` then
> `make verify-phase2`. Registering a real user (Step 6, next) and passing a
> valid token is the actual proof `/api/ping` works — the 401 alone doesn't
> confirm auth is wired correctly end-to-end, only that it's present.

---

## Step 6 — Add authentication

**What:** deploys the **auth** service (JWT via Passport.js). Users register
and log in to get a short-lived access token (15 min) and a longer-lived
refresh token (7 days); `/api/ping` and any future protected route check
this token before responding. Since Phase 3's code was already present in
this checkout (that's what the Step 5 finding proved — `/api/ping` returned
401 before this step even ran), most of what `make phase3` does is generate
the signing key and wire up the pieces that were already sitting in the
image.

**How:**

1. Set `FRONTEND_URL` to the Kong endpoint from Step 5's output — this is
   the URL the auth service will treat as the legitimate frontend origin.
   Derive it from the instance itself rather than typing an IP by hand (same
   reasoning as Step 2's `K3S_SERVER_ADDR`):
   ```bash
   MY_IP=$(hostname -I | awk '{print $1}')
   sed -i "s|^FRONTEND_URL=.*|FRONTEND_URL=http://$MY_IP:30080|" .env
   grep FRONTEND_URL .env
   ```
   `JWT_ACCESS_EXPIRY` (`15m`) and `JWT_REFRESH_EXPIRY` (`7d`) already ship
   with usable defaults — no change needed unless you want different token
   lifetimes.
2. Deploy:
   ```bash
   make phase3
   ```
   This generates an RS256 JWT keypair (`scripts/jwt-keys.sh`, stored in
   `.secrets/jwt/`, gitignored), creates the `jwt-keypair` Secret, deploys
   the auth service, rebuilds `ping` and `frontend` (both gain
   auth-awareness), updates Kong with the auth routes, then runs the
   verification gate.

**Success looks like:**
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

Confirm by hand — register, log in, and hit the now-working `/api/ping`:
```bash
ENDPOINT="http://$(hostname -I | awk '{print $1}'):30080"

curl -X POST $ENDPOINT/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpass123"}'

TOKEN=$(curl -s -X POST $ENDPOINT/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpass123"}' | jq -r '.accessToken')

curl $ENDPOINT/api/ping -H "Authorization: Bearer $TOKEN"
# now returns 200, unlike the 401 you saw in Step 5
```

Or just open `http://<your-instance-ip>:30080/` in a browser (the same IP
`FRONTEND_URL` was set to above) — you should see a login/register page;
register, log in, and the page should show the ping result with your email
attached.

**Want to look closer?**
```bash
kubectl -n app get deploy auth              # 2/2 ready
kubectl -n app logs -l app=auth --tail=50   # registration/login activity
ls .secrets/jwt/                            # the generated keypair (gitignored)
```

> **Bug found during this install:** `make phase3` failed at
> `[4/7] Building and pushing auth service image...` with
> `COPY services/auth/package*.json ./: no source files were specified`.
> Cause: `scripts/bootstrap-auth.sh` re-implemented its own `docker build`
> calls instead of using `scripts/build-push.sh` (despite its header saying
> it depends on that script), and got the auth build wrong — it built from
> `services/auth/` as the context, but `services/auth/Dockerfile` needs the
> **repo root** as context (it `COPY`s in `services/common`, which only
> exists there). `build-push.sh` already handled this correctly per
> service; `bootstrap-auth.sh` just wasn't calling it. Fixed by having
> `bootstrap-auth.sh` delegate all three builds (auth, ping, frontend) to
> `build-push.sh`. No action needed on your end — re-run `make phase3`
> after pulling the fix.

> **Bug found during this install (2 more, same phase):** even after the
> build-context fix above, `make phase3` still hung at
> `Waiting for deployment "auth" rollout to finish: 0 out of 2 new replicas
> have been updated...` until it timed out. Two separate bugs stacked here:
>
> 1. `kubectl describe replicaset -l app=auth` showed
>    `Error creating: ... serviceaccount "auth" not found`. The auth
>    Deployment's pod spec runs as ServiceAccount `auth`, which is defined in
>    `k8s/app/auth/rbac.yaml` — but `bootstrap-auth.sh` only ever applied
>    `deployment.yaml` and `service.yaml`, never `rbac.yaml`, so the
>    ServiceAccount never existed and Kubernetes refused to create any pods
>    at all.
> 2. After that fix, pods were created but sat in `CrashLoopBackOff` with
>    `Error: secret "mongodb-credentials" not found`. HANDOFF.md already
>    documented that `mongodb-credentials` and `redis-password` "must exist
>    in BOTH `data` and `app` namespaces for Phase 3 to work" — Kubernetes
>    Secrets don't cross namespace boundaries on their own, and Phase 1's
>    `data-secrets.sh` only ever creates them in `data`. Nothing actually did
>    the documented copy into `app`.
>
> Fixed: `bootstrap-auth.sh` now applies `rbac.yaml` before the Deployment,
> and mirrors both Secrets from `data` into `app` (re-reading from `data`
> each run, so a later credential rotation via `make secrets-data`
> propagates automatically on the next `make phase3`).

> **Bug found during this install (the actual last one):** with both of the
> above fixed, the auth pods started but still crash-looped, this time with
> an application-level error in `kubectl -n app logs -l app=auth`:
> `MongoParseError: Password contains unescaped characters` — the *exact*
> bug from Step 4's Phase 1 finding, but this time in the real application
> code, not a verification script. The earlier fix (adding `urlencode()` and
> using it in the shell scripts) missed that `services/auth/src/index.js`,
> `services/worker/src/index.js`, and `services/jobs-api/src/index.js` all
> build their own `mongodb://` connection string the same unsafe way, by
> splicing `MONGO_APP_PASSWORD` in raw — and that password, generated by
> `openssl rand -base64` per this guide's own Step 4, routinely contains `+`
> or `/`. Fixed with `encodeURIComponent()` on the username and password in
> all three files. No action needed on your end — re-run `make phase3` after
> pulling the fix.

---

## Step 7 — Add async jobs

**What:** deploys **jobs-api** (enqueues background jobs, auth-protected)
and **worker** (a separate Deployment that actually pulls jobs off Redis and
runs them, auto-scaling 1–10 replicas via HPA). This proves the full async
pattern: API enqueues → Redis queue (BullMQ) → worker processes → result
written to MongoDB → API can report status. No new `.env` values needed —
it reuses the MongoDB/Redis credentials from Step 4.

**How:**
```bash
make phase4
```
This builds and pushes the `jobs-api` and `worker` images, deploys both
(worker with its HPA), adds the `/api/jobs` route to Kong, restarts Kong,
then runs the verification gate.

**Success looks like:**
```
[1/7] Deployments and services       OK jobs-api (2/2) and worker (>=1 replicas) ready, HPA configured
[2/7] End-to-end job creation        OK Job created: <job-id>
[3/7] Job completion polling          OK Job completed successfully with correct result
[4/7] Failing job retry               OK Failing job retried and failed as expected
[5/7] Job ownership (IDOR prevention) OK IDOR prevention works
[6/7] Worker resilience               OK Worker resilience verified
[7/7] List jobs                       OK Job listing works

PHASE 4 OK
```

Confirm by hand — create a job as an authenticated user and poll it:
```bash
ENDPOINT="http://$(hostname -I | awk '{print $1}'):30080"

TOKEN=$(curl -s -X POST $ENDPOINT/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"testpass123"}' | jq -r '.accessToken')

JOB_ID=$(curl -s -X POST $ENDPOINT/api/jobs \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"hello-world","data":{"name":"World"}}' | jq -r '.jobId')

sleep 3
curl $ENDPOINT/api/jobs/$JOB_ID -H "Authorization: Bearer $TOKEN"
# status should be "completed", with a result.greeting field
```

**Want to look closer?**
```bash
kubectl -n app get deploy jobs-api worker      # jobs-api 2/2, worker >=1
kubectl -n app get hpa worker-hpa              # current/target CPU, replica range
kubectl -n app logs -l app=worker --tail=50    # job pickup/processing activity
```

> **Bug found during this install (the disk really does need to be 20GB):**
> `make phase4` left `jobs-api` stuck `CrashLoopBackOff`/`Evicted` in a way
> that had nothing to do with the application. `kubectl describe node` showed
> `DiskPressure: True`, and the actual disk (`df -h /`) was only **6.7GB
> total** — not the 20GB this guide's Step 1 specifies. Repeated `--no-cache`
> Docker builds (needed for the cache-busting fix below) plus k3s's own
> separate containerd image store, sharing one small root volume with the
> OS and Kubernetes PVC data, filled it completely; `docker system prune`
> didn't help because k3s uses its own containerd, not the standalone Docker
> daemon you build images with — two independent copies of every image on
> one disk. **If you provisioned the EC2 instance with a smaller root volume
> than Step 1 specifies** (check with `lsblk` — if the disk shows less than
> ~18GB, this is you), fix it now rather than waiting to hit this later:
> resize the EBS volume to 20GB+ in the AWS Console (EC2 → Volumes → Modify
> Volume), then on the instance:
> ```bash
> sudo growpart /dev/nvme0n1 1   # device name may differ - check with lsblk
> sudo resize2fs /dev/nvme0n1p1
> df -h /
> ```

> **Bug found during this install (the actual application bug):** even with
> disk space available, `jobs-api` kept crash-looping with the same
> `MongoParseError: Password contains unescaped characters` from Step 4/6 —
> despite the source fix (`encodeURIComponent`) already being on disk and
> the image rebuilding without errors. `kubectl get pod ... -o
> jsonpath='{.items[0].status.containerStatuses[0].imageID}'` revealed why:
> the running image's digest was hours old, unrelated to anything just
> built. Cause: `k8s/app/jobs-api/deployment.yaml` and
> `k8s/app/worker/deployment.yaml` pull `REGISTRY_URL/backbone-jobs-api` and
> `REGISTRY_URL/backbone-worker` (the same `backbone-<service>` naming every
> other service uses), but `scripts/bootstrap-jobs.sh` was building and
> pushing to `REGISTRY_URL/jobs-api` and `REGISTRY_URL/worker` — no prefix,
> a completely different image name. Every "successful" build/push was
> invisible to the actual Deployment, which kept pulling whatever stale
> image already existed at the `backbone-jobs-api` tag. Fixed by renaming
> the build/push targets in `bootstrap-jobs.sh` to match. No action needed
> on your end — re-run `make phase4` after pulling the fix.

> **Bug found during this install (a small one, in cleanup):**
> `make verify-phase4` passed all 7 real checks and then crashed during its
> own test-user cleanup step with `line 219: in: unbound variable`. The
> cleanup's `mongosh --eval` string uses MongoDB's `$in` operator inside a
> double-quoted bash string; bash tried to expand `$in` as a shell variable
> instead of passing it through literally. Fixed by escaping it (`\$in`). No
> action needed on your end.

---

## Step 8 — TLS and observability

**What:** Phase 5 has three independent tracks: 5A (TLS), 5B (observability),
5C (CI/CD + in-cluster registry). This install does **5A and 5B only** — this
repo's own HANDOFF.md documents 5C as deliberately deferred (it was built,
tested, and then not adopted: for a single-operator setup it replaces a
`make` flow that isn't a bottleneck with a Gitea StatefulSet + Drone
server/runner + a 20Gi PVC + two more credentials, and the one real attempt
left `gitea-0` in an undiagnosed CrashLoopBackOff). Run the two tracks
individually rather than `make phase5`, which chains **all three** including
5C.

5A adds HTTPS at the gateway with a self-signed certificate (no domain
needed — `TLS_MODE=selfsigned` is the default and works directly on the node
IP; browsers will warn, but the encryption is real). 5B adds Prometheus
(metrics), Loki (logs), Grafana (dashboards), and Alertmanager, all in a new
`observability` namespace.

**How:**

1. TLS needs no new `.env` values — the defaults already work:
   ```bash
   make tls
   make verify-phase5a
   ```
2. Observability needs one password:
   ```bash
   sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24)|" .env
   grep GRAFANA_ADMIN_PASSWORD .env
   make obs
   make verify-phase5b
   ```
   **Save that password somewhere safe** — it's your Grafana login and, like
   every other credential this guide has generated, nothing prints or
   regenerates it afterward.

> **Note on which IP to use where:** every `curl`/command in this guide runs
> *on the EC2 instance itself* and uses `hostname -I` — the instance's
> **private** VPC IP (e.g. `172.31.x.x`). That's correct there. But opening
> any of these URLs in a browser **on your own laptop** needs the
> instance's **public** IPv4 address instead (AWS Console → EC2 →
> Instances → your instance → "Public IPv4 address" — a different-looking
> number, e.g. `3.x/34.x/54.x...`). The private IP is only reachable from
> inside the VPC; from outside, it just times out, which looks identical to
> a firewall or certificate problem but isn't one.

**Success looks like:** `verify-phase5a.sh` ends with `PHASE 5A OK`;
`verify-phase5b.sh` ends with `PHASE 5B OK` and reports Prometheus targets
UP. Confirm by hand:
```bash
# HTTPS now works (self-signed, so -k skips certificate verification)
curl -k https://$(hostname -I | awk '{print $1}'):30443/api/ping

# Grafana, through Kong
# open in a browser: https://<instance-ip>:30443/grafana
#   user: admin   password: the one you just generated
```

**Want to look closer?**
```bash
kubectl -n platform get certificate,clusterissuer   # cert-manager objects, both Ready
kubectl -n observability get pods                   # prometheus, loki, grafana, alertmanager, promtail all Running
kubectl -n observability port-forward svc/prometheus 9090:9090 &
# then browse http://localhost:9090 from a machine that can reach this instance,
# or curl it locally on the instance itself
```

> **Note:** since this is an all-in-one single-node install, `t3.large`'s
> ~1.5 vCPU/3GB baseline from Step 1 now also carries Prometheus (up to
> 1 vCPU/2GB at its configured limit) and Loki (up to 1 vCPU/1GB) on top of
> everything from Phases 1-4. If pods start getting `OOMKilled` or the node
> shows `MemoryPressure`, that's this — worth knowing before assuming it's a
> new bug.

> **Transient flake seen during this install (not a bug, no fix needed):**
> `verify-phase5b.sh` failed once with `promtail DaemonSet is 0/1 Ready`. The
> pod was already `1/1 Running` by the time we looked — on first start,
> promtail scans every pod's existing log files on the node (there are a lot,
> by Phase 5), and that initial scan was enough to make it miss the `/ready`
> HTTP probe's deadline a couple of times before catching up. Its log also
> showed `dial tcp ...:3100: connect: connection refused` while pushing to
> Loki, because Loki itself wasn't up yet either. Both settled within about a
> minute. If you hit this, just re-run `make verify-phase5b` once before
> assuming something's actually broken.

---

## Step 9 — Backups and disaster recovery

**What:** Phase 6A deploys scheduled CronJobs that dump MongoDB and Redis and
ship them to an S3 bucket, plus PodDisruptionBudgets so routine node
maintenance can't take down every replica of a service at once. Unlike every
earlier phase, its own verification gate doesn't stop at "the CronJob
exists" — it writes a real sentinel document, takes a real backup, destroys
the source data, restores from S3, and confirms the sentinel came back. A
backup you haven't test-restored is a hope, not a backup, and this phase is
built around proving that distinction.

This is also the first phase needing a **real AWS resource outside the
EC2 instance** — an S3 bucket and an IAM user scoped to just that bucket.

**How:**

1. **Create the bucket and a scoped IAM user** (in the AWS Console, not on
   the instance):
   - S3 → Create bucket → pick a globally-unique name (e.g.
     `<your-name>-backbone-backups`) → same region you'd query most from →
     leave "Block all public access" **on**.
   - IAM → Users → Create user → no console access needed → attach an
     inline policy scoped to just this bucket (not full `AmazonS3FullAccess`
     — this key can write and delete backups, so it deserves the same
     restraint as a database password):
     ```json
     {
       "Version": "2012-10-17",
       "Statement": [{
         "Effect": "Allow",
         "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"],
         "Resource": [
           "arn:aws:s3:::<your-bucket-name>",
           "arn:aws:s3:::<your-bucket-name>/*"
         ]
       }]
     }
     ```
   - Security credentials tab → Create access key → note the **Access key
     ID** and **Secret access key** (shown once).

2. **Put the bucket name in `.env` now** (not secret, safe to script):
   ```bash
   sed -i "s|^BACKUP_S3_BUCKET=.*|BACKUP_S3_BUCKET=<your-bucket-name>|" .env
   sed -i "s|^BACKUP_S3_REGION=.*|BACKUP_S3_REGION=<your-bucket-region>|" .env
   grep -E "^BACKUP_S3_(BUCKET|REGION)=" .env
   ```
   Leave `BACKUP_S3_ENDPOINT` blank (that's only for non-AWS S3-compatible
   providers) and `BACKUP_S3_PREFIX` at its default (`backbone`).

3. **Put the access key and secret key in `.env` yourself, directly on the
   EC2 instance** — same reasoning as Step 5's Docker Hub token: an access
   key that can write/delete your backups shouldn't be typed anywhere but
   your own terminal. Run this on the instance, pasting your own values:
   ```bash
   sed -i "s|^BACKUP_S3_ACCESS_KEY=.*|BACKUP_S3_ACCESS_KEY=<paste-access-key-id>|" .env
   sed -i "s|^BACKUP_S3_SECRET_KEY=.*|BACKUP_S3_SECRET_KEY=<paste-secret-access-key>|" .env
   ```
   Confirm both are non-empty without printing the values themselves:
   ```bash
   grep -c -E "^BACKUP_S3_(ACCESS_KEY|SECRET_KEY)=.+" .env   # should print 2
   ```

4. **Deploy:**
   ```bash
   make phase6a
   ```
   This creates the `backup-s3-credentials` Secret, preflights bucket
   access (fails fast with a clear message if the bucket/credentials are
   wrong, before creating anything that depends on them), then applies the
   staging PVC, both CronJobs (`mongo-backup` at `0 3 * * *`, `redis-backup`
   at `0 4 * * *`), and the PodDisruptionBudgets — then runs the
   verification gate, which is the real restore drill described above.

**Success looks like:** the command ends with, and exits `0`:
```
[1/7] Secret, staging volume and CronJobs   OK secret (6 keys), staging PVC Pending (WaitForFirstConsumer - binds on the first backup), both CronJobs present with Forbid
[2/7] PodDisruptionBudgets                  OK PDBs present for multi-replica services; correctly absent for single-replica StatefulSets
[3/7] Bucket reachability                   OK bucket reachable with the configured credentials
[4/7] Mongo backup and restore round trip   OK sentinel written, backed up, destroyed, and restored from S3 intact
[5/7] Redis backup                          OK redis snapshot uploaded and RDB integrity-checked: <key>
[6/7] Retention pruning                     OK objects older than 30 days are pruned
[7/7] Backup freshness                      OK most recent backup: <date> <time> <key>

PHASE 6A OK
```
This takes longer than earlier gates (a couple of minutes) — it's actually
running backup Jobs and a restore, not just checking object existence.

**Want to look closer?**
```bash
kubectl -n data get cronjob mongo-backup redis-backup   # schedule, last run
kubectl -n data get pdb -A                              # kong, auth, ping, jobs-api, frontend only
aws s3 ls s3://<your-bucket-name>/backbone/mongo/        # (from your own machine, with your IAM creds)
```
Take a manual backup any time with `./scripts/backup-now.sh mongo` (or
`redis`) — useful right before anything risky, since the RPO between
scheduled runs is up to 24h.

> **Note:** if you'd rather not create real cloud storage just to complete
> this walkthrough, Phase 6A can be brought up "wiring only" with
> `make backup && ./scripts/verify-phase6a.sh --no-s3` — this deploys
> everything but skips the checks that need a real bucket, and deliberately
> prints `PHASE 6A PARTIAL` rather than `OK`. Treat that as a placeholder,
> not a working backup — nothing has actually been proven restorable until
> you come back and do the real thing above.

> **Bug found during this install:** the first `make phase6a` run passed
> checks [1]–[3], took a real backup, uploaded it, and logged
> `uploaded: mongo-<timestamp>.gz` — but then check [4] (the actual
> restore-and-compare test) failed with `the sentinel document did NOT come
> back from the restore`. Re-running the restore manually to see the real
> error showed the download step failing with a flat 404: the object no
> longer existed in the bucket, only minutes after being uploaded and
> verified. Cause: `verify-phase6a.sh`'s own `cleanup()` (registered via
> `trap cleanup EXIT`) deleted the backup object it had just created on
> *every* exit path, including a failed one — so the moment check [4] failed
> and the script exited, its own cleanup destroyed the only evidence needed
> to debug the failure (and on a fresh install, the only backup that
> existed at all). Fixed: cleanup now only deletes the S3 object once the
> restore has actually been proven to work (check [4] passed); on failure it
> logs that it's leaving the object in place instead. No action needed on
> your end — re-run `make verify-phase6a` after pulling the fix. (The
> underlying "is the backup actually restorable" question is still open —
> see the next entry once resolved.)

---

## Step 10 — Maintenance mode

**What:** Phase 6B deploys a standing "site under maintenance" page and a
`maintenance` CLI that flips Kong's routing to it — public traffic gets a
503 while the real services keep running underneath (nothing is stopped,
so ending maintenance is one Kong restart, not a cold start). A fixed
bypass list (`/api/auth/login`, `/internal/maintenance`, the ACME challenge
path) always stays routed normally — that's what keeps you from locking
yourself out, since otherwise nobody could authenticate to turn it back off.

Its own verification gate is unusually blunt about the risk: proving
maintenance mode actually works means actually turning it on against your
live gateway, which briefly 503s everything (~60 seconds, across two Kong
restarts) — so the gate refuses to run that part unless you explicitly pass
a flag saying you accept the downtime.

**How:**

1. Deploy:
   ```bash
   make phase6b
   ```
   This applies the maintenance page + its state ConfigMap (left untouched
   if maintenance already happens to be on — safe to re-run), the RBAC the
   auth service needs to expose an HTTP off-switch, and redeploys auth to
   pick up its ServiceAccount, then runs the (non-disruptive) verification
   gate.

2. **Promote an admin user** — the HTTP off-switch (`/internal/maintenance`)
   needs an admin account to call it; the CLI (`./scripts/maintenance off`)
   doesn't, but having one is worth doing now, using the test account from
   Step 6:
   ```bash
   MONGO_ROOT_USER=$(grep '^MONGO_ROOT_USER=' .env | cut -d= -f2)
   MONGO_ROOT_PASSWORD=$(grep '^MONGO_ROOT_PASSWORD=' .env | cut -d= -f2)
   kubectl -n data exec -it statefulset/mongodb -- mongosh \
     "mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASSWORD}@localhost/backbone?authSource=admin" \
     --eval 'db.users.updateOne({email:"test@example.com"},{$addToSet:{roles:"admin"}})'
   ```
   (This reads the password out of your own `.env` into a local shell
   variable and straight into `mongosh` — it's never typed by hand or shown
   in a prompt.)

3. **Run the real on/off cycle** — this is the part that actually proves it
   works, and the part that takes the platform down briefly. Do it when
   that's acceptable (it's a good dry run for a real future maintenance
   window, not just a formality). `make verify-phase6b` doesn't take
   arguments, so call the script directly:
   ```bash
   ./scripts/verify-phase6b.sh --i-know-this-causes-downtime
   ```

**Success looks like:** the command ends with, and exits `0`:
```
[1/6] Maintenance page deployment      OK maintenance page Running (state: off), Service present
[2/6] The page itself returns 503 + Retry-After   OK 503 + Retry-After for traffic; /healthz stays 200
[3/6] Auth service RBAC is narrowly scoped         OK auth SA can edit the maintenance ConfigMaps; cannot read secrets in app/data/platform
[4/6] Turning maintenance ON (the platform will 503 briefly)   OK public traffic 503s; /api/auth/login and the ACME path still answer
[5/6] Turning maintenance OFF and checking routing is restored OK routing restored intact (N entries), state is off, site answers normally
[6/6] State hygiene                    OK saved config cleared after restore

PHASE 6B OK
```

Confirm by hand any time afterward:
```bash
./scripts/maintenance status                              # OFF (normal routing)
./scripts/maintenance on --reason "testing" --pause-queues # flips to the 503 page, pauses BullMQ
curl -k https://$(hostname -I | awk '{print $1}'):30443/    # 503
curl -k https://$(hostname -I | awk '{print $1}'):30443/api/auth/login -X POST \
  -H "Content-Type: application/json" -d '{"email":"x","password":"y"}'  # NOT 503 - bypass list working
./scripts/maintenance off                                  # restores routing, resumes queues
```

**Want to look closer?**
```bash
kubectl -n platform get deploy,svc maintenance         # the standing 503 page
kubectl -n platform get configmap maintenance-state -o yaml   # on/off, reason, saved routing
kubectl -n app get sa auth -o yaml                     # the ServiceAccount the off-endpoint runs as
```

> **Note:** if you'd rather not take the platform down yet, `make phase6b`
> alone (without the disruptive flag) still deploys everything and runs
> checks [1]–[3] — the page, its Service, and RBAC scoping — but prints
> `PHASE 6B PARTIAL`, explicitly meaning the on/off cycle itself is
> unverified. Come back and run the real cycle before you actually need
> maintenance mode for something — the failure mode this phase exists to
> catch is discovering you can't turn it back off, which you'd rather learn
> now than during a real migration.

---

*(This completes every phase in the build order except 5C/CI-CD, deferred by
choice — see Step 8's note. The install is done.)*
