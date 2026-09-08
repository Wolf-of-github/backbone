# backbone - Phase 0 task entrypoints (k3d: k3s-in-Docker, machine-agnostic).
# depends_on: [scripts/cluster-up.sh, scripts/cluster-down.sh,
#              k8s/base/namespaces.yaml, scripts/create-secrets.sh,
#              scripts/verify-phase0.sh]

SHELL := /usr/bin/env bash
KUBECONFIG ?= ./kubeconfig
export KUBECONFIG

.PHONY: help cluster base secrets verify phase0 down lint

help:
	@echo "Targets:"
	@echo "  make cluster  - create the k3d cluster (k3s in Docker) + built-in registry"
	@echo "  make base     - apply namespaces + default StorageClass"
	@echo "  make secrets  - create Phase 0 secrets (none yet; stable entrypoint)"
	@echo "  make verify   - run the Phase 0 acceptance gate"
	@echo "  make phase0   - cluster -> base -> secrets -> verify"
	@echo "  make down     - delete the k3d cluster"
	@echo "  make lint     - shellcheck scripts + kubectl dry-run manifests"

cluster:
	./scripts/cluster-up.sh

base: _need-kubeconfig
	kubectl apply -f k8s/base/namespaces.yaml
	kubectl patch storageclass local-path \
	  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true

secrets: _need-kubeconfig
	./scripts/create-secrets.sh

verify: _need-kubeconfig
	./scripts/verify-phase0.sh

phase0: cluster base secrets verify

down:
	./scripts/cluster-down.sh

lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck not installed - skipping"
	@if [ -f ./kubeconfig ]; then \
	  kubectl apply --dry-run=server -f k8s/base/ ; \
	else \
	  echo "no ./kubeconfig - skipping manifest dry-run"; \
	fi

_need-kubeconfig:
	@test -f $(KUBECONFIG) || { echo "missing $(KUBECONFIG) - run 'make cluster' first"; exit 1; }
