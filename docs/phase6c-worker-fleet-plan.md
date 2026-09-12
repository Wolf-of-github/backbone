# Phase 6C — Provisioned Worker Fleet (Terraform) — PLANNED, NOT BUILT

**Status:** Design only. No `terraform/` directory, no code, nothing applied. Parked on this
branch deliberately until there's time to implement carefully — the explicit worry driving that
caution is Terraform silently creating (and billing for) unnecessary EC2 instances.

This supersedes the older, stale "Track C" sketch in `architecture.txt` (~line 2990), which used
an imperative `make workers COUNT=n` / `count = var.worker_count` model. That model has a real
foot-gun: deleting worker N with count-based indexing shifts every later index and makes Terraform
destroy-and-recreate them too. This plan uses `for_each` keyed by name instead, specifically to
avoid that.

## Goal

Let the operator describe desired EC2 worker nodes as files, and have Terraform reconcile AWS to
match — while making it structurally hard to spin up (or destroy) something unintended.

## Layout

```
cluster_node_specs/
  node1.yaml
  node2.yaml
terraform/
  main.tf              # provider + for_each over cluster_node_specs/*.yaml
  variables.tf          # max_workers cap, defaults (instance_type, ami, tailscale, etc.)
  modules/worker/       # per-instance aws_instance + security group
  outputs.tf
  backend.tf.example    # optional remote state (S3 + DynamoDB lock); local state by default
.gitignore additions: /terraform/.terraform/, *.tfstate*, /terraform/backend.tf
```

**Node spec schema** (`cluster_node_specs/node1.yaml`):
```yaml
name: node1              # required, unique — becomes k8s node label + AWS Name tag
instance_type: t3.small  # default t3.small
spot: false
key_name: ""             # optional, break-glass SSH
```

Region/AMI/networking are top-level Terraform vars (from `.env`), not per-node-spec — supporting
per-node regions would need per-region provider aliasing, real added complexity for no clear
current need. Revisit if that changes.

## Key design decisions

1. **`for_each` keyed by `name`, not `count`.** Deleting `node2.yaml` destroys only that instance;
   nothing else is touched. This is the main correction to the old sketch.

2. **Plan-gated apply via a saved plan artifact.**
   - `make workers-plan` → `terraform plan -out=.terraform/tfplan` (review only, no changes).
   - `make workers-apply` → `terraform apply .terraform/tfplan`. Terraform refuses to apply if
     state has drifted since the plan was taken, so there's no window where `apply` can diverge
     from what was actually reviewed.
   - Neither ever passes `-auto-approve`.

3. **Hard cap.** A `max_workers` Terraform variable (default small, e.g. 3) with a `validation`
   block on the spec count, so a typo'd file or bad glob can't fan out past that without an
   explicit override.

4. **One source of truth for the k3s-agent join command.** The old sketch had the install command
   duplicated in `node-join.sh`'s `emit_remote_script` and a separate cloud-init template, "kept in
   sync" only by a verify step that greps both. Instead: extract the snippet into one template file
   that both `node-join.sh` and Terraform's `templatefile()` render, so drift is structurally
   impossible rather than just checked for.
   - Needs care: Terraform's `${...}` templating syntax collides with bash's. Runtime-bash
     variables (computed on the instance at boot, e.g. a Tailscale IP) need to be written as
     `$${VAR}` in the `.tftpl` to produce a literal `${VAR}`; Terraform-time values use plain
     `${var}`.
   - Reference: `scripts/node-join.sh`'s `emit_remote_script()` (lines ~26-63) is the exact
     command-building logic to extract — quoted in full in the exploration notes below.

5. **Node cleanup tied to instance lifecycle.** A `local-exec` provisioner with `when = destroy`
   runs `kubectl delete node <name>` when that specific instance is destroyed. This works
   identically whether a single spec file is removed or a full `workers-destroy` is run — the old
   sketch's separate manual cleanup loop only covered the full-destroy case.

6. **Credentials never touch disk as a tfvars file.**
   - `.env` holds a scoped IAM user's `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — least
     privilege: `ec2:RunInstances`/`TerminateInstances`/`Describe*` + security groups + tagging
     only, never root/admin. Same sensitivity framing `backup-secrets.sh` already uses for the S3
     backup credentials.
   - The Makefile target exports these as env vars for the `terraform` process (idiomatic
     Terraform; avoids a new secret-bearing file to gitignore and manage).
   - `K3S_URL` / `K3S_TOKEN` (already in `.secrets/cluster-join.env`, written by `cluster-up.sh`)
     are passed the same way, as `TF_VAR_*` env vars.

7. **Networking matches what's actually running.** Per `docs/handoff.md`, the real cluster
   (`pavilion`) has no public IP and joins over Tailscale. The worker module defaults to
   `TAILSCALE=true`, needs a `TAILSCALE_AUTHKEY` in `.env`, and its security group opens only the
   one overlay port matching `WIREGUARD` (default `51820/udp`) from the tailnet CIDR
   `100.64.0.0/10` — per the firewall table already in `architecture.txt` (~line 143), which is the
   authoritative source for this and must not be re-derived by hand. No public ingress on workers
   at all; that's Kong's job (Phase 2), gateway-node only.

## Makefile targets

```
make workers-plan     # terraform plan -out=tfplan, shows diff, no changes made
make workers-apply    # terraform apply tfplan — the only target that touches AWS
make workers-destroy  # plan + apply an empty/reduced spec set through the same gate
make workers-list     # terraform output + kubectl get nodes -l backbone.dev/role=worker
```

## Verification (opt-in, costs money)

`scripts/verify-phase6c.sh`, skipped by default (mirrors the 6A/6B `--i-know-this-...` pattern):

```bash
./scripts/verify-phase6c.sh --i-know-this-costs-money
```

Writes a temporary `cluster_node_specs/_verify.yaml` (t3.micro), plans + applies, waits for the
node to go Ready and carry `backbone.dev/role=worker`, schedules a test Deployment and confirms it
lands there, then destroys through the same plan-gated flow and confirms the node disappears from
`kubectl get nodes`.

## Existing conventions this must reuse (do not reinvent)

- `scripts/lib.sh`: `log`/`ok`/`die`/`load_env`/`require_vars`/`need` helpers; `REPO_ROOT`
  resolution; `set -euo pipefail` + header-comment (`# depends_on: [...]`) convention every script
  in this repo follows.
- `scripts/node-join.sh`'s `emit_remote_script()` — the exact k3s agent install command to factor
  into the shared template (see decision 4 above).
- `.env.example` style: banner-commented sections (`# === Phase N - <Name> ===`), `SCOPE_PURPOSE`
  naming, a comment on every var noting which script consumes it and how to generate it if secret.
- Makefile style: `_need-kubeconfig` prerequisite, phase targets as dependency chains
  (`phase6a: backup verify-phase6a`), `.PHONY` list, `lint` target's explicit shellcheck file list.
- `scripts/backup-secrets.sh` — the closest existing precedent for external-cloud-credential
  handling and its sensitivity framing (though note: it writes creds into a **Kubernetes Secret**
  for an in-cluster workload, which is a different case from Terraform's **local CLI** credential
  use in decision 6 above — don't copy that mechanism directly, just the framing).

## Not decided yet / revisit before implementing

- Exact `max_workers` default.
- Whether `instance_type` per spec needs validation against an allowlist (e.g. to keep costs
  predictable) or is left to the operator's judgement.
- Whether remote Terraform state (S3 + DynamoDB lock) is adopted now or deferred — local state is
  fine for a single operator but is itself a small blast-radius risk (accidental `rm`).
