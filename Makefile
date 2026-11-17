# Boccob Lakehouse — infrastructure entry points.
# Every target wraps a script in scripts/. No logic lives here.
#
#   make help
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ENV    ?= dev
STACK  ?=
GROUPS ?=
BUNDLE ?=
S := scripts

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo; echo "  Variables: ENV=dev|test|prod  STACK=<stacks/NN-*>  GROUPS=cluster,foundation,...  BUNDLE=<dir>"

# --- versions / air-gap ---------------------------------------------------------
.PHONY: lock tools airgap-mirror airgap-bundle airgap-load airgap-check providers-mirror node-bundle
lock: ## Resolve versions.yaml -> versions.lock.yaml (needs internet)
	$(S)/lock-update.sh
tools: ## Install pinned cosign/trivy/syft into ~/.cache/boccob/bin
	$(S)/tools-install.sh
airgap-mirror: ## Connected: copy locked images + charts into Zot (GROUPS=.. to limit)
	MIRROR_GROUPS=$(GROUPS) $(S)/airgap/mirror.sh sync $(ENV)
airgap-bundle: ## Connected: export a transferable bundle (BUNDLE=<dir>, TAR=1 for a tarball)
	MIRROR_GROUPS=$(GROUPS) $(S)/airgap/mirror.sh bundle $(ENV) $(BUNDLE)
airgap-load: ## Air-gapped: push a bundle (BUNDLE=<dir>) into Zot
	MIRROR_GROUPS=$(GROUPS) $(S)/airgap/mirror.sh load $(ENV) $(BUNDLE)
airgap-check: ## Verify Zot holds every locked image (by digest) and chart
	MIRROR_GROUPS=$(GROUPS) $(S)/airgap/mirror.sh check $(ENV)
providers-mirror: ## Mirror OpenTofu providers for offline `tofu init`
	$(S)/airgap/providers-mirror.sh $(BUNDLE)
node-bundle: ## Build the k3s node bundle for test/prod hosts
	$(S)/airgap/node-bundle.sh $(ENV)

# --- supply chain ---------------------------------------------------------------
.PHONY: scan sbom verify-signatures
scan: ## Trivy scan of mirrored images (FAIL_ON=CRITICAL to gate)
	MIRROR_GROUPS=$(GROUPS) $(S)/supply-chain/scan.sh $(ENV)
sbom: ## SPDX SBOMs of mirrored images (syft)
	MIRROR_GROUPS=$(GROUPS) $(S)/supply-chain/sbom.sh $(ENV)
verify-signatures: ## cosign verification per scripts/supply-chain/signature-policy.yaml
	MIRROR_GROUPS=$(GROUPS) $(S)/supply-chain/verify-signatures.sh $(ENV)

# --- cluster ----------------------------------------------------------------------
.PHONY: registry-up cluster-up cluster-down
registry-up: ## dev: start the Zot bootstrap registry (Podman)
	$(S)/cluster/registry-up.sh $(ENV)
cluster-up: ## dev: Zot + hardened k3s in Podman; test/prod: install k3s on hosts over SSH
	$(S)/cluster/up.sh $(ENV)
cluster-down: ## dev: stop node + registry containers (volumes and local state are kept)
	$(S)/cluster/dev-down.sh $(ENV)

# --- deploy -----------------------------------------------------------------------
.PHONY: deploy plan openbao-init openbao-unseal verify destroy
deploy: ## Apply all stacks in order, or one with STACK=..
	$(S)/deploy.sh $(ENV) $(STACK)
plan: ## Plan all stacks, or one with STACK=..
	PLAN_ONLY=1 $(S)/deploy.sh $(ENV) $(STACK)
openbao-init: ## Initialise + unseal OpenBao (runs automatically after 10-foundation-secrets)
	$(S)/openbao/init.sh $(ENV)
openbao-unseal: ## Unseal OpenBao after a restart
	$(S)/openbao/init.sh $(ENV) --unseal
verify: ## Smoke test of cluster + foundation
	$(S)/verify.sh $(ENV)
destroy: ## Destroy stacks (CONFIRM=<env> required; STACK=.. for one; CLUSTER=1 also removes the dev cluster)
	$(S)/destroy.sh $(ENV) $(STACK)

# --- quality ----------------------------------------------------------------------
.PHONY: lint fmt
lint: ## shellcheck + tofu fmt -check + tofu validate + lock consistency
	$(S)/lint.sh
fmt: ## tofu fmt -recursive
	tofu fmt -recursive .
