# backbone - Phase 0 task entrypoints.
# depends_on: [scripts/install-k3s.sh, scripts/bootstrap-registry.sh,
#              k8s/base/namespaces.yaml, scripts/create-secrets.sh,
#              scripts/verify-phase0.sh]

SHELL := /usr/bin/env bash
KUBECONFIG ?= ./kubeconfig
export KUBECONFIG

.PHONY: help cluster base secrets registry verify phase0 clean lint

help:
	@echo "Targets:"
	@echo "  make cluster   - install k3s, write ./kubeconfig, wait Ready"
	@echo "  make base      - apply namespaces + default StorageClass"
	@echo "  make secrets   - create Phase 0 secrets from .env"
	@echo "  make registry  - stand up the private registry + node trust"
	@echo "  make verify    - run the Phase 0 acceptance gate"
	@echo "  make phase0    - cluster -> base -> secrets -> registry -> verify"
	@echo "  make lint      - shellcheck scripts + kubectl dry-run manifests"

cluster:
	./scripts/install-k3s.sh

base: _need-kubeconfig
	kubectl apply -f k8s/base/namespaces.yaml
	kubectl patch storageclass local-path \
	  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' || true

secrets: _need-kubeconfig
	./scripts/create-secrets.sh

registry: _need-kubeconfig
	./scripts/bootstrap-registry.sh

verify: _need-kubeconfig
	./scripts/verify-phase0.sh

phase0: cluster base secrets registry verify

lint:
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck not installed - skipping"
	@if [ -f ./kubeconfig ]; then \
	  kubectl apply --dry-run=server -f k8s/base/ -f k8s/platform/registry/ ; \
	else \
	  echo "no ./kubeconfig - skipping manifest dry-run"; \
	fi

clean:
	@echo "Removing generated local artifacts (NOT the cluster)."
	rm -rf ./.secrets ./config/registries.yaml

_need-kubeconfig:
	@test -f $(KUBECONFIG) || { echo "missing $(KUBECONFIG) - run 'make cluster' first"; exit 1; }
