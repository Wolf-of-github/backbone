# backbone - Phase 0 task entrypoints. Linux; installs a k3s server + joinable workers.
# depends_on: [scripts/cluster-up.sh, scripts/cluster-down.sh, scripts/node-join.sh,
#              k8s/base/namespaces.yaml, scripts/create-secrets.sh,
#              scripts/verify-phase0.sh]

SHELL := /usr/bin/env bash
KUBECONFIG ?= ./kubeconfig
export KUBECONFIG

.PHONY: help cluster base secrets verify phase0 down lint node-join

help:
	@echo "backbone Phase 0 (Linux). 'make cluster' installs a k3s SERVER here;"
	@echo "other machines join as workers. Set K3S_SERVER_ADDR in .env first."
	@echo ""
	@echo "Targets:"
	@echo "  make phase0                       - cluster -> base -> secrets -> verify"
	@echo "  make cluster                      - install the k3s server, write ./kubeconfig"
	@echo "  make base                         - apply namespaces + default StorageClass"
	@echo "  make secrets                      - Phase 0 secrets (none yet; stable entrypoint)"
	@echo "  make verify                       - run the Phase 0 acceptance gate"
	@echo "  make node-join TARGET=user@host   - join a worker machine over SSH"
	@echo "  make down                         - uninstall the k3s server on this host"
	@echo "  make lint                         - shellcheck scripts + kubectl dry-run manifests"

cluster:
	./scripts/cluster-up.sh

node-join:
	@test -n "$(TARGET)" || { echo "usage: make node-join TARGET=user@<worker-ip>"; exit 1; }
	./scripts/node-join.sh "$(TARGET)"

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
	@command -v shellcheck >/dev/null && shellcheck scripts/lib.sh scripts/cluster-up.sh scripts/cluster-down.sh scripts/node-join.sh scripts/create-secrets.sh scripts/verify-phase0.sh || echo "shellcheck not installed - skipping"
	@if [ -f ./kubeconfig ]; then \
	  kubectl apply --dry-run=server -f k8s/base/ ; \
	else \
	  echo "no ./kubeconfig - skipping manifest dry-run"; \
	fi

_need-kubeconfig:
	@test -f $(KUBECONFIG) || { echo "missing $(KUBECONFIG) - run 'make cluster' first"; exit 1; }
