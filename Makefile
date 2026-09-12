# backbone - task entrypoints. Linux; installs a k3s server + joinable workers,
# then brings up the platform phase by phase.
# depends_on: [scripts/cluster-up.sh, scripts/cluster-down.sh, scripts/node-join.sh,
#              k8s/base/namespaces.yaml, scripts/create-secrets.sh,
#              scripts/verify-phase0.sh, scripts/data-secrets.sh,
#              scripts/bootstrap-data.sh, scripts/verify-phase1.sh]

SHELL := /usr/bin/env bash
KUBECONFIG ?= ./kubeconfig
export KUBECONFIG

.PHONY: help setup backbone cluster base secrets verify phase0 down lint node-join \
        secrets-data data verify-phase1 phase1 \
        build-push apply-app edge verify-phase2 phase2 \
        jwt-keys auth verify-phase3 phase3 \
        jobs verify-phase4 phase4 \
        tls verify-phase5a obs verify-phase5b \
        verify-phase5 phase5 \
        backup backup-now verify-phase6a phase6a \
        maintenance verify-phase6b phase6b promote-admin

help:
	@echo "backbone Phase 0 (Linux). 'make cluster' installs a k3s SERVER here;"
	@echo "other machines join as workers. Set K3S_SERVER_ADDR in .env first."
	@echo ""
	@echo "  Quick start"
	@echo "  make setup                        - one-time interactive wizard, builds .env"
	@echo "  make backbone                     - setup -> every phase (0-4, 5A, 5B, 6A, 6B), unattended"
	@echo ""
	@echo "Targets:"
	@echo "  Phase 0 - Substrate"
	@echo "  make phase0                       - cluster -> base -> secrets -> verify"
	@echo "  make cluster                      - install the k3s server, write ./kubeconfig"
	@echo "  make base                         - apply namespaces + default StorageClass"
	@echo "  make secrets                      - Phase 0 secrets (none yet; stable entrypoint)"
	@echo "  make verify                       - run the Phase 0 acceptance gate"
	@echo "  make node-join TARGET=user@host   - join a worker machine over SSH"
	@echo "  make down                         - uninstall the k3s server on this host"
	@echo ""
	@echo "  Phase 1 - Data layer (set the Phase 1 vars in .env first)"
	@echo "  make phase1                       - data -> verify-phase1"
	@echo "  make secrets-data                 - create mongodb-credentials + redis-password"
	@echo "  make data                         - bootstrap Redis + MongoDB in the data namespace"
	@echo "  make verify-phase1                - run the Phase 1 acceptance gate"
	@echo ""
	@echo "  Phase 2 - Edge (set REGISTRY_URL in .env first)"
	@echo "  make phase2                       - edge -> verify-phase2"
	@echo "  make build-push                   - build and push ping + frontend images"
	@echo "  make edge                         - bootstrap Kong + ping + frontend"
	@echo "  make verify-phase2                - run the Phase 2 acceptance gate"
	@echo ""
	@echo "  Phase 3 - Auth (set JWT expiry vars in .env first)"
	@echo "  make phase3                       - auth -> verify-phase3"
	@echo "  make jwt-keys                     - generate JWT RS256 keypair"
	@echo "  make auth                         - bootstrap auth service + update Kong/ping/frontend"
	@echo "  make verify-phase3                - run the Phase 3 acceptance gate"
	@echo ""
	@echo "  Phase 4 - Async Jobs (requires Phase 0-3 complete)"
	@echo "  make phase4                       - jobs -> verify-phase4"
	@echo "  make jobs                         - bootstrap jobs-api + worker services"
	@echo "  make verify-phase4                - run the Phase 4 acceptance gate"
	@echo ""
	@echo "  Phase 5 - Operate (two tracks; each has its own gate)"
	@echo "  make phase5                       - tls -> obs -> verify-phase5"
	@echo "  make tls                          - 5A: HTTPS at Kong (works with NO domain)"
	@echo "  make verify-phase5a               - run the Phase 5A gate"
	@echo "  make obs                          - 5B: Prometheus + Loki + Grafana"
	@echo "  make verify-phase5b               - run the Phase 5B gate"
	@echo "  make verify-phase5                - run both Phase 5 gates"
	@echo "  (5C - CI/CD + in-cluster registry - is not on this branch; see phase-5c-cicd)"
	@echo ""
	@echo "  Phase 6A - Backup / DR (set the BACKUP_S3_* vars in .env first)"
	@echo "  make phase6a                      - backup -> verify-phase6a"
	@echo "  make backup                       - CronJobs + staging PVC + PodDisruptionBudgets"
	@echo "  make backup-now                   - take a backup right now (before risky work)"
	@echo "  make verify-phase6a               - run the Phase 6A gate (performs a real restore)"
	@echo ""
	@echo "  Phase 6B - Maintenance mode"
	@echo "  make phase6b                      - maintenance -> verify-phase6b"
	@echo "  make maintenance                  - deploy the 503 page + auth RBAC"
	@echo "  make verify-phase6b               - run the Phase 6B gate"
	@echo "    ./scripts/maintenance on|off|status   - the control CLI"
	@echo ""
	@echo "  make lint                         - shellcheck scripts + kubectl dry-run manifests"

setup:
	./scripts/setup-env.sh

# Runs every phase in the documented build order, unattended, against the
# .env that `make setup` just built. Stops at the first failure - each phase
# depends on the one before it, so continuing past a failure just produces a
# more confusing failure two phases later.
#
# 5C (CI/CD + in-cluster registry) is not on this branch - deferred by
# choice; see HANDOFF.md and the phase-5c-cicd branch.
# 6A is skipped entirely (not degraded) when no bucket was configured in
# .env - backup-secrets.sh hard-requires real S3 credentials for even the
# wiring-only path, so there is no partial mode to fall back to here.
backbone:
	@[ -f .env ] || $(MAKE) setup
	$(MAKE) phase0
	$(MAKE) phase1
	$(MAKE) phase2
	$(MAKE) phase3
	$(MAKE) phase4
	$(MAKE) tls
	$(MAKE) verify-phase5a
	$(MAKE) promote-admin
	$(MAKE) obs
	$(MAKE) verify-phase5b
	@if [ -n "$$(grep '^BACKUP_S3_BUCKET=' .env | cut -d= -f2-)" ]; then \
		$(MAKE) phase6a; \
	else \
		echo "  No BACKUP_S3_BUCKET set in .env - skipping Phase 6A (backups)."; \
		echo "  Run 'make setup' again to add a bucket, then 'make phase6a'."; \
	fi
	$(MAKE) phase6b
	@echo ""
	@echo "  backbone is up. See INSTALL_GUIDE.md for what to check next."

promote-admin: _need-kubeconfig
	./scripts/promote-admin.sh

cluster:
	./scripts/cluster-up.sh

node-join:
	@test -n "$(TARGET)" || { echo "usage: make node-join TARGET=user@<worker-ip>"; exit 1; }
	./scripts/node-join.sh "$(TARGET)"

base: _need-kubeconfig
	kubectl apply -f k8s/base/namespaces.yaml
	@for i in $$(seq 1 30); do kubectl get storageclass local-path >/dev/null 2>&1 && break; echo "waiting for local-path StorageClass..."; sleep 2; done
	kubectl patch storageclass local-path \
	  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

secrets: _need-kubeconfig
	./scripts/create-secrets.sh

verify: _need-kubeconfig
	./scripts/verify-phase0.sh

phase0: cluster base secrets verify

# --- Phase 1: Data layer -------------------------------------------------
secrets-data: _need-kubeconfig
	./scripts/data-secrets.sh

data: _need-kubeconfig
	./scripts/bootstrap-data.sh

verify-phase1: _need-kubeconfig
	./scripts/verify-phase1.sh

phase1: data verify-phase1

# --- Phase 2: Edge -------------------------------------------------------
build-push: _need-kubeconfig
	./scripts/build-push.sh

# Apply k8s/app/* with the registry substituted into the image placeholder.
# Never `kubectl apply -f k8s/app/...` directly - those files are templates and
# a direct apply sets the image to the literal placeholder (InvalidImageName).
apply-app: _need-kubeconfig
	./scripts/apply-app-manifests.sh

edge: _need-kubeconfig
	./scripts/bootstrap-edge.sh

verify-phase2: _need-kubeconfig
	./scripts/verify-phase2.sh

phase2: edge verify-phase2

# --- Phase 3: Auth -----------------------------------------------------------
jwt-keys: _need-kubeconfig
	./scripts/jwt-keys.sh

auth: _need-kubeconfig
	./scripts/bootstrap-auth.sh

verify-phase3: _need-kubeconfig
	./scripts/verify-phase3.sh

phase3: auth verify-phase3

# --- Phase 4: Async Jobs --------------------------------------------------------
jobs: _need-kubeconfig
	./scripts/bootstrap-jobs.sh

verify-phase4: _need-kubeconfig
	./scripts/verify-phase4.sh

phase4: jobs verify-phase4

# --- Phase 5: Operate ------------------------------------------------------
# Three tracks, gated independently. Order matters: 5B's cert-expiry alert
# consumes 5A, and 5C is served over 5A's TLS listener.
tls: _need-kubeconfig
	./scripts/bootstrap-tls.sh

verify-phase5a: _need-kubeconfig
	./scripts/verify-phase5a.sh

obs: _need-kubeconfig
	./scripts/bootstrap-observability.sh

verify-phase5b: _need-kubeconfig
	./scripts/verify-phase5b.sh

verify-phase5: _need-kubeconfig
	./scripts/verify-phase5.sh

phase5: tls obs verify-phase5

# --- Phase 6A: Backup / Disaster Recovery ----------------------------------
backup: _need-kubeconfig
	./scripts/bootstrap-backup.sh

backup-now: _need-kubeconfig
	./scripts/backup-now.sh $(WHAT)

verify-phase6a: _need-kubeconfig
	./scripts/verify-phase6a.sh

phase6a: backup verify-phase6a

# --- Phase 6B: Maintenance mode ---------------------------------------------
maintenance: _need-kubeconfig
	./scripts/bootstrap-maintenance.sh

verify-phase6b: _need-kubeconfig
	./scripts/verify-phase6b.sh

phase6b: maintenance verify-phase6b

down:
	./scripts/cluster-down.sh

lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/lib.sh scripts/setup-env.sh scripts/promote-admin.sh scripts/cluster-up.sh scripts/cluster-down.sh scripts/node-join.sh scripts/create-secrets.sh scripts/verify-phase0.sh scripts/data-secrets.sh scripts/bootstrap-data.sh scripts/verify-phase1.sh scripts/build-push.sh scripts/bootstrap-edge.sh scripts/kongctl.sh scripts/verify-phase2.sh scripts/jwt-keys.sh scripts/bootstrap-auth.sh scripts/verify-phase3.sh scripts/bootstrap-jobs.sh scripts/verify-phase4.sh scripts/cert-manager-install.sh scripts/bootstrap-tls.sh scripts/verify-phase5a.sh scripts/bootstrap-observability.sh scripts/verify-phase5b.sh scripts/migrate.sh scripts/verify-phase5.sh scripts/apply-app-manifests.sh scripts/backup-secrets.sh scripts/bootstrap-backup.sh scripts/backup-now.sh scripts/mongo-restore.sh scripts/redis-restore.sh scripts/verify-phase6a.sh scripts/bootstrap-maintenance.sh scripts/verify-phase6b.sh scripts/maintenance || echo "shellcheck not installed - skipping"
	@if [ -f ./kubeconfig ]; then \
	  kubectl apply --dry-run=server -f k8s/base/ ; \
	  kubectl apply --dry-run=server -R -f k8s/data/ ; \
	  kubectl apply --dry-run=server -R -f k8s/app/ ; \
	  kubectl apply --dry-run=server -f k8s/platform/kong/ ; \
	  echo "note: k8s/platform/cert-manager/ and k8s/observability/ are"; \
	  echo "      templates (\$${VAR} placeholders) - they are dry-run from"; \
	  echo "      .rendered/ by their bootstrap scripts, not from source."; \
	else \
	  echo "no ./kubeconfig - skipping manifest dry-run"; \
	fi

_need-kubeconfig:
	@test -f $(KUBECONFIG) || { echo "missing $(KUBECONFIG) - run 'make cluster' first"; exit 1; }
