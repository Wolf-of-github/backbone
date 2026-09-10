# backbone - task entrypoints. Linux; installs a k3s server + joinable workers,
# then brings up the platform phase by phase.
# depends_on: [scripts/cluster-up.sh, scripts/cluster-down.sh, scripts/node-join.sh,
#              k8s/base/namespaces.yaml, scripts/create-secrets.sh,
#              scripts/verify-phase0.sh, scripts/data-secrets.sh,
#              scripts/bootstrap-data.sh, scripts/verify-phase1.sh]

SHELL := /usr/bin/env bash
KUBECONFIG ?= ./kubeconfig
export KUBECONFIG

.PHONY: help cluster base secrets verify phase0 down lint node-join \
        secrets-data data verify-phase1 phase1 \
        build-push edge verify-phase2 phase2 \
        jwt-keys auth verify-phase3 phase3 \
        jobs verify-phase4 phase4

help:
	@echo "backbone Phase 0 (Linux). 'make cluster' installs a k3s SERVER here;"
	@echo "other machines join as workers. Set K3S_SERVER_ADDR in .env first."
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
	@echo "  make lint                         - shellcheck scripts + kubectl dry-run manifests"

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

down:
	./scripts/cluster-down.sh

lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/lib.sh scripts/cluster-up.sh scripts/cluster-down.sh scripts/node-join.sh scripts/create-secrets.sh scripts/verify-phase0.sh scripts/data-secrets.sh scripts/bootstrap-data.sh scripts/verify-phase1.sh scripts/build-push.sh scripts/bootstrap-edge.sh scripts/kongctl.sh scripts/verify-phase2.sh scripts/jwt-keys.sh scripts/bootstrap-auth.sh scripts/verify-phase3.sh scripts/bootstrap-jobs.sh scripts/verify-phase4.sh || echo "shellcheck not installed - skipping"
	@if [ -f ./kubeconfig ]; then \
	  kubectl apply --dry-run=server -f k8s/base/ ; \
	  kubectl apply --dry-run=server -R -f k8s/data/ ; \
	  kubectl apply --dry-run=server -R -f k8s/platform/ ; \
	  kubectl apply --dry-run=server -R -f k8s/app/ ; \
	else \
	  echo "no ./kubeconfig - skipping manifest dry-run"; \
	fi

_need-kubeconfig:
	@test -f $(KUBECONFIG) || { echo "missing $(KUBECONFIG) - run 'make cluster' first"; exit 1; }
