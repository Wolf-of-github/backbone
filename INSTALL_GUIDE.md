# Backbone — Installation Guide

A quick, guided install onto a single Linux host. Three commands, one
interactive setup step, then everything else runs unattended.

---

## What you're building

Everything below runs on **one host** acting as a single-node k3s cluster.
Workloads split into namespaces by role:

```
Your host -- single-node k3s cluster
============================================================

  internet
    |
    | :30443 (HTTPS)
    v
  [ namespace: platform ]
    Kong (API gateway, TLS termination)
      - route  /       -> frontend
      - route  /api/*  -> ping / auth / jobs-api  (by path)
    cert-manager (TLS certs), maintenance page (503 switch)
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

  [ namespace: observability ]
    Prometheus / Loki / Grafana / Alertmanager / Promtail
```

Kong is the only thing anything outside the cluster ever talks to; it does
**not** check JWTs itself, each backend service verifies its own tokens.
`jobs-api` only enqueues work into Redis - `worker` is the separate
Deployment that actually processes it, and the only piece that autoscales.

---

## Prerequisites

- **A Linux host.** Tested spec: `t3.large` (2 vCPU / 8GB RAM), Ubuntu 22.04+,
  **20GB+ disk** (the default 8GB fills up once every image is built and
  running - resize now if `lsblk` shows less than ~18GB).
- **Inbound firewall rules** open before you start (on AWS: EC2 → your
  instance → Security tab → the security group → Edit inbound rules → Add
  rule, for each):
  | Port | Protocol | Purpose |
  |---|---|---|
  | `22` | TCP | SSH |
  | `30443` | TCP | HTTPS - the platform, once Phase 5A (TLS) is up |
  | `30080` | TCP | HTTP - only needed if you want to check Phases 2-4 from a browser *before* TLS is deployed; safe to skip if you're not doing that |

  Without `30443` open, `make backbone` still succeeds (every check runs
  from the host itself), but nothing outside the host - including your own
  browser - can reach the site afterward.
- **Docker Hub or GHCR account** - built images get pushed there. (An
  in-cluster registry + CI/CD track, Phase 5C, was built and evaluated but
  is deferred by choice on this branch - see HANDOFF.md.)
- **An S3-compatible bucket + a scoped access key**, if you want working
  backups (Phase 6A) - optional, can be added later.
- Basic tools present on stock Ubuntu: `curl`, `git`, `openssl`, `sudo`.
  `make` and Docker are not preinstalled - Step 1 below installs both.

If you're opening any URL from your own browser rather than from the host
itself, use the host's **public** IP address, not a private/VPC-internal
one (`172.x`, `10.x`, `192.168.x`) - the private address only works from
inside that network and otherwise just times out.

---

## Step 1 — Get the code and install Docker + make

```bash
git clone https://github.com/Wolf-of-github/backbone.git
cd backbone

# make runs every command in this guide; not preinstalled on stock Ubuntu
sudo apt-get update
sudo apt install make        # version 4.4.1-3, or newer, is fine

# Docker is needed from here on (k3s itself uses its own separate runtime)
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker   # or log out/in - applies the group change now
docker version  # should show both a Client and Server section
```

---

## Step 2 — Run the setup wizard

```bash
make setup
```

This is the **only** interactive step. It asks each question once and
writes everything straight into `.env` - you never open or hand-edit that
file yourself. For anything it can safely generate (database passwords,
Grafana's admin password), press **Enter** to auto-generate, or type your
own. For things it can't generate (your registry login, an S3 access key),
it prompts and can log in to your registry for you on the spot.

You'll be asked for:
- This host's address (auto-detected; just confirm it)
- A container registry URL + optional login (Docker Hub/GHCR)
- Database passwords (MongoDB root + app user, Redis) - Enter to generate
- Whether you have a real domain (no = self-signed HTTPS, no domain needed)
- A Grafana admin password - Enter to generate
- S3 bucket + credentials for backups (optional - skip and add later)
- An email to promote to admin, for maintenance mode's HTTP off-switch

**Whatever you generate, note somewhere safe (a password manager)** —
nothing prints these values again after this step.

---

## Step 3 — Bring up the whole platform

```bash
make backbone
```

This runs every phase in order, unattended: cluster + namespaces → MongoDB
+ Redis → Kong + frontend → auth → async jobs → TLS → observability →
backups (if you configured a bucket) → maintenance mode. Each phase's own
verification gate runs as part of this, so the command only succeeds if
everything it built is actually working, not just deployed.

This takes a while (building and pushing several container images, standing
up ~15 pods) - expect single-digit minutes, not seconds.

**Success looks like:** the command ends with
```
backbone is up. See INSTALL_GUIDE.md for what to check next.
```
with no `ERROR` lines above it. If something fails partway, the error names
which phase and check failed - fix what it describes and re-run
`make backbone`. It picks up where it left off rather than starting over:
each phase is marked done once it succeeds, and a re-run skips anything
already completed. To force a full re-run from Phase 0 instead, run `make
backbone-reset` first.

---

## Step 4 — Confirm it's working

```bash
# from the host itself
curl -k https://$(hostname -I | awk '{print $1}'):30443/api/ping
```

Then from your own browser, open (using the host's **public** IP if you're
off-host):
```
https://<host-public-ip>:30443/
```
Expect a certificate warning (self-signed, unless you configured a real
domain) - click through it. You should see the frontend; register a user,
log in, and the ping check should succeed.

Grafana is at `/grafana` on the same address, logging in as `admin` with
the password you set in Step 2.

**Check backups actually restore** (skip if you didn't configure a bucket):
```bash
./scripts/verify-phase6a.sh
```

**Rehearse maintenance mode** (briefly takes the site down, ~60s - do this
on your own schedule, not required to finish the install):
```bash
./scripts/verify-phase6b.sh --i-know-this-causes-downtime
```

---

## Everyday commands

```bash
./scripts/maintenance status|on|off      # flip public traffic to a 503 page and back
./scripts/backup-now.sh mongo|redis      # take a backup right now
./scripts/mongo-restore.sh list          # see available backups
make verify                              # re-run Phase 0's health gate
kubectl get pods -A                      # see everything running
```

The public maintenance page has no admin controls on it by design - it's
served to every visitor with no login in front of it, so anything clickable
there would reveal that an admin off-switch exists. Turn maintenance off
from wherever you can reach this repo (SSH into the instance, or `kubectl`
access) with `./scripts/maintenance off` - not from the page itself.

Running each phase individually (`make phase0`, `make phase1`, … `make
phase6b`), rather than all at once via `make backbone`, is also supported —
useful if you're debugging one phase specifically. Run `make help` for the
full command list.

---

## Adding a worker node

**What:** the control-plane instance from Step 1-3 can run everything alone,
but joining a second machine as a k3s **worker** adds real capacity - pods
get scheduled across both. The joined machine only ever runs workloads; it
never becomes a second control-plane (this platform runs single-server k3s,
not an HA/multi-server setup) - if the original instance goes down, the
cluster's API goes down regardless of how many workers are joined.

**Prerequisite:** the new instance must be in the **same AWS account, VPC,
and region** as the control-plane. Private IPs (`172.31.x.x`) only route
within one VPC - a different account or VPC needs cross-account networking
(VPC peering) that isn't covered here.

**How:**

1. **Launch the worker instance** - same AMI, same VPC/subnet/region as the
   control-plane. Nothing needs installing on it ahead of time (no k3s,
   Docker, or cloned repo) - the join pushes everything it needs over SSH.

2. **Security groups - both directions, not just one.** It's easy to open
   the new instance's inbound rules and assume that's the whole job; the
   control-plane's own security group also needs new inbound rules to
   accept traffic *from* the worker, or the join hangs indefinitely on
   `failed to get CA certs` with no obvious cause.

   On the **worker's** security group, allow inbound from the control-plane's private IP:
   | Port | Protocol | Source |
   |---|---|---|
   | `22` | TCP | your IP (for SSH access) |
   | `6443` | TCP | control-plane's private IP `/32` |
   | `10250` | TCP | control-plane's private IP `/32` |
   | `51820` | UDP | control-plane's private IP `/32` |

   On the **control-plane's** security group, add inbound rules allowing the same three ports from the **worker's** private IP `/32` (`6443`, `10250`, `51820`) - this is the direction that's easy to miss.

3. **SSH access from the control-plane to the worker.** The control-plane
   instance itself (not your laptop) needs the private key for the
   worker's key pair, since it's the one dispatching the join over SSH. If
   you only have the `.pem` on your own machine, copy it over:
   ```bash
   # from your own machine, in the folder with the .pem
   scp -i your-key.pem your-key.pem ubuntu@<control-plane-public-ip>:~/.ssh/
   ```
   Then on the control-plane:
   ```bash
   chmod 600 ~/.ssh/your-key.pem
   sed -i "s|^SSH_KEY=.*|SSH_KEY=/home/ubuntu/.ssh/your-key.pem|" .env
   grep '^SSH_KEY=' .env
   ```

4. **Run the join, from the control-plane:**
   ```bash
   ./scripts/node-join.sh ubuntu@<worker-private-ip>
   ```

**Success looks like:**
```bash
kubectl get nodes -o wide
```
showing two `Ready` nodes - the original as `control-plane,etcd,master`,
the new one with no role (a plain worker).

**Want to look closer?** If the join hangs at "No change detected so
skipping service start" or the worker's `k3s-agent` logs (`sudo journalctl
-u k3s-agent -n 30 --no-pager`, on the worker) show repeating `failed to
get CA certs: ... context deadline exceeded`, that's a network path
problem to port 6443, not an SSH/key problem - re-check step 2 above,
specifically the control-plane's own inbound rules.
