# Backbone — Installation Guide

First-time install walkthrough, tested end-to-end as it's written.

Each step follows the same structure: **what** we're doing and why, **how**
to do it, and **what success looks like** before moving on.

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
2. Edit `.env`. The only required value at this stage is `K3S_SERVER_ADDR`.
   For a single all-in-one instance (this guide's setup), use the instance's
   **private IP** (`hostname -I | awk '{print $1}'` on the instance itself):
   ```
   K3S_SERVER_ADDR=<private-ip>
   ```
   Leave `TAILSCALE=false` and `WIREGUARD=true` (defaults) — there's only one
   node, so no cross-node traffic to encrypt yet.

**Success looks like:** `backbone/.env` exists and `K3S_SERVER_ADDR` is set
to a real IP (not blank).

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

---

*(Next: Step 4 — bring up the data layer with `make phase1`.)*
