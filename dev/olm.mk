# olm.mk — Shared OLM deployment targets for medik8s operators
#
# Include this from any operator's Makefile:
#   TOOLS_DIR ?= $(shell cd .. && pwd)/tools
#   -include $(TOOLS_DIR)/dev/olm.mk
#
# All targets are prefixed with 'olm-' to avoid collisions.
#
# Operators with agent images (SBR, etc.) should set OLM_AGENT_IMAGES before include:
#   OLM_AGENT_IMAGES ?= sbr-agent
# or for multiple agents:
#   OLM_AGENT_IMAGES ?= agent1 agent2
#
# This file intentionally keeps variables and helper targets prefixed with OLM_
# so existing development targets remain unchanged.

OLM_TARGETS := check-go versions olm-controller-gen olm-operator-sdk \
	       olm-kustomize olm-tools olm-build-push deploy-olm undeploy-olm olm-help

$(OLM_TARGETS): SHELL := /usr/bin/env bash
$(OLM_TARGETS): .SHELLFLAGS := -euo pipefail -c

# Public tool-version knobs, matching the names used by the main Makefile.
# When this file is included, the main Makefile's file-local defaults remain
# untouched; command-line/environment values are honored below.
CONTROLLER_GEN_VERSION ?= v0.20.1
OPERATOR_SDK_VERSION ?= v1.42.3
KUSTOMIZE_VERSION ?= v5@v5.8.1

# Keep the conventional tool-version variable names usable from the
# environment/command line. The main Makefile has its own defaults, so its
# file-local values are deliberately not inherited by this isolated flow.
OLM_CONTROLLER_GEN_VERSION ?= v0.20.1
OLM_OPERATOR_SDK_VERSION ?= v1.42.3
OLM_KUSTOMIZE_VERSION ?= v5.8.1
ifneq ($(filter command line environment environment override,$(origin CONTROLLER_GEN_VERSION)),)
OLM_CONTROLLER_GEN_VERSION := $(CONTROLLER_GEN_VERSION)
endif
ifneq ($(filter command line environment environment override,$(origin OPERATOR_SDK_VERSION)),)
OLM_OPERATOR_SDK_VERSION := $(OPERATOR_SDK_VERSION)
endif
ifneq ($(filter command line environment environment override,$(origin KUSTOMIZE_VERSION)),)
OLM_KUSTOMIZE_VERSION := $(KUSTOMIZE_VERSION)
ifneq (,$(filter v5@v%,$(KUSTOMIZE_VERSION)))
OLM_KUSTOMIZE_VERSION := $(patsubst v5@v%,v%,$(KUSTOMIZE_VERSION))
endif
endif

# Operator-specific configuration (override in including Makefile)
OLM_OPERATOR_NAME ?= $(error OLM_OPERATOR_NAME must be set before including olm.mk)
OLM_PACKAGE_NAME ?= $(OLM_OPERATOR_NAME)
OLM_OPERATOR_NAMESPACE ?= openshift-workload-availability
OLM_CHANNEL ?= stable
OLM_GO_TOOLCHAIN_VERSION := $(shell awk '$$1 == "toolchain" {print $$2}' go.mod 2>/dev/null)
OLM_CATALOG_SOURCE_NAME ?= $(OLM_PACKAGE_NAME)-catalog
OLM_CATALOG_SOURCE_NAMESPACE ?= $(OLM_OPERATOR_NAMESPACE)
OLM_OPERATOR_GROUP_NAME ?= operator-sdk-og
OLM_INSTALL_MODE ?= AllNamespaces
OLM_SECURITY_CONTEXT_CONFIG ?= restricted

# Agent images configuration (space-separated list of agent names)
# Each agent must have:
#   - cmd/<agent-name>/Dockerfile
#   - RBAC generation path at paths="./cmd/<agent-name>/..."
# Example for SBR: OLM_AGENT_IMAGES ?= sbr-agent
OLM_AGENT_IMAGES ?=

TTL_DURATION ?= 1h
OLM_TTL_DURATION ?= $(TTL_DURATION)
OLM_GIT_REV ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo local)
OLM_IMAGE_PREFIX ?= ttl.sh/$(OLM_OPERATOR_NAME)-$(OLM_GIT_REV)
OLM_OPERATOR_IMAGE ?= $(OLM_IMAGE_PREFIX):$(OLM_TTL_DURATION)
OLM_BUNDLE_IMAGE ?= $(OLM_IMAGE_PREFIX)-bundle:$(OLM_TTL_DURATION)

OLM_PLATFORM ?= linux/amd64
OLM_CONTAINER_TOOL ?= $(if $(shell command -v podman 2>/dev/null),podman,$(if $(shell command -v docker 2>/dev/null),docker,))
OLM_OC ?= $(if $(shell command -v oc 2>/dev/null),oc,kubectl)
OLM_GOOS ?= $(shell go env GOOS 2>/dev/null || echo linux)
OLM_GOARCH ?= $(shell go env GOARCH 2>/dev/null || echo amd64)

OLM_LOCALBIN ?= $(if $(LOCALBIN),$(LOCALBIN),$(CURDIR)/bin)/olm
OLM_OPERATOR_SDK ?= $(OLM_LOCALBIN)/operator-sdk-$(OLM_OPERATOR_SDK_VERSION)
OLM_CONTROLLER_GEN ?= $(OLM_LOCALBIN)/controller-gen-$(OLM_CONTROLLER_GEN_VERSION)
OLM_KUSTOMIZE ?= $(OLM_LOCALBIN)/kustomize-$(OLM_KUSTOMIZE_VERSION)

$(info Using Container Tool: $(OLM_CONTAINER_TOOL))

define OLM_CHECK_TOOL_VERSION
	@printf "\n\033[1m$(1) Version Check:\033[0m\n"
	@if [ -x "$(2)" ]; then \
		installed_version="$$($(3) || echo unknown)"; \
		expected_version="$(4)"; \
		if [ "$$installed_version" = "$$expected_version" ]; then \
			printf "\033[32m%-30s\033[0m %-20s %s\n" "$(5)" "$$installed_version" "✓ matches Makefile"; \
		else \
			printf "\033[33m%-30s\033[0m %-20s %s\n" "$(5)" "$$installed_version" "⚠ differs from Makefile ($$expected_version)"; \
		fi; \
	else \
		printf "\033[31m%-30s\033[0m %-20s %s\n" "$(5)" "not found" "✗ not installed in $(OLM_LOCALBIN)"; \
	fi
endef

.PHONY: check-go
check-go: ## Check if go binary is available in PATH.
	@if ! command -v go >/dev/null 2>&1; then \
		printf '\033[31m✗ Error: go binary not found in PATH\033[0m\n'; \
		printf 'Go is required to install the pinned source-deployment tools.\n'; \
		exit 1; \
	fi
	@printf '\033[32m✓ Go binary found in PATH\033[0m\n'

.PHONY: versions
versions: check-go olm-tools ## Display source-deployment tool and project versions.
	@printf '\033[36m%-30s\033[0m %s\n' 'GO_VERSION' "$$(go version | awk '{print $$3}')"
	@printf '\n\033[1m%-30s %-20s %s\033[0m\n' 'Tool and Project Versions:' 'Value' 'Used by Targets'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'DEFAULT_VERSION' '$(DEFAULT_VERSION)' 'bundle'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'VERSION' '$(VERSION)' 'bundle, deploy-olm'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'OPERATOR_SDK_VERSION' '$(OLM_OPERATOR_SDK_VERSION)' 'operator-sdk, bundle'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'ENVTEST_K8S_VERSION' 'not used' 'not used by source deployment'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'GOLANGCI_LINT_VERSION' 'not used' 'not used by source deployment'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'KUSTOMIZE_VERSION' '$(OLM_KUSTOMIZE_VERSION)' 'kustomize, bundle'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'CONTROLLER_TOOLS_VERSION' '$(OLM_CONTROLLER_GEN_VERSION)' 'controller-gen, bundle'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'OLM_VERSION' '$(VERSION)' 'bundle, deploy-olm'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'OLM_CHANNEL' '$(OLM_CHANNEL)' 'bundle, deploy-olm'
	@printf '\033[36m%-30s\033[0m %-20s %s\n' 'GO_TOOLCHAIN_VERSION' '$(OLM_GO_TOOLCHAIN_VERSION)' '(informational only)'
	$(call OLM_CHECK_TOOL_VERSION,Operator-SDK Version Check:,$(OLM_OPERATOR_SDK),$(OLM_OPERATOR_SDK) version | awk '{print $$NF}',$(OLM_OPERATOR_SDK_VERSION),OPERATOR_SDK_LOCAL)
	$(call OLM_CHECK_TOOL_VERSION,Controller-Gen Version Check:,$(OLM_CONTROLLER_GEN),$(OLM_CONTROLLER_GEN) --version | awk '{print $$2}',$(OLM_CONTROLLER_GEN_VERSION),CONTROLLER_GEN_LOCAL)
	$(call OLM_CHECK_TOOL_VERSION,Kustomize Version Check:,$(OLM_KUSTOMIZE),$(OLM_KUSTOMIZE) version --short | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+',$(OLM_KUSTOMIZE_VERSION),KUSTOMIZE_LOCAL)

.PHONY: olm-controller-gen
olm-controller-gen: $(OLM_CONTROLLER_GEN) ## Install controller-gen.
$(OLM_CONTROLLER_GEN):
	@GOBIN=$(OLM_LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(OLM_CONTROLLER_GEN_VERSION)
	@mv $(OLM_LOCALBIN)/controller-gen $@

.PHONY: olm-operator-sdk
olm-operator-sdk: $(OLM_OPERATOR_SDK) ## Install operator-sdk.
$(OLM_OPERATOR_SDK):
	@mkdir -p $(OLM_LOCALBIN)
	@curl -fsSL -o $@ "https://github.com/operator-framework/operator-sdk/releases/download/$(OLM_OPERATOR_SDK_VERSION)/operator-sdk_$(OLM_GOOS)_$(OLM_GOARCH)"
	@chmod +x $@

.PHONY: olm-kustomize
olm-kustomize: $(OLM_KUSTOMIZE) ## Install kustomize.
$(OLM_KUSTOMIZE):
	@mkdir -p $(OLM_LOCALBIN)
	@GOBIN=$(OLM_LOCALBIN) go install sigs.k8s.io/kustomize/kustomize/v5@$(if $(filter v%,$(OLM_KUSTOMIZE_VERSION)),$(OLM_KUSTOMIZE_VERSION),v$(OLM_KUSTOMIZE_VERSION))
	@mv $(OLM_LOCALBIN)/kustomize $@

.PHONY: olm-tools
olm-tools: olm-controller-gen olm-operator-sdk olm-kustomize ## Install all OLM deployment tools.

.PHONY: olm-build-push
olm-build-push: olm-tools ## Build and push source and OLM bundle images to ttl.sh.
	@command -v "$(OLM_CONTAINER_TOOL)" >/dev/null 2>&1 || { echo "Container tool '$(OLM_CONTAINER_TOOL)' is not available" >&2; exit 1; }
	@echo "Building $(OLM_OPERATOR_IMAGE) with the Konveyor builder"
	$(OLM_CONTAINER_TOOL) build --platform=$(OLM_PLATFORM) \
		-f Dockerfile -t $(OLM_OPERATOR_IMAGE) .
	$(foreach agent,$(OLM_AGENT_IMAGES), \
		@echo "Building agent: $(agent)"; \
		$(OLM_CONTAINER_TOOL) build --platform=$(OLM_PLATFORM) \
			-f cmd/$(agent)/Dockerfile -t localhost/$(agent):$(OLM_GIT_REV) . ; \
		$(OLM_CONTAINER_TOOL) tag localhost/$(agent):$(OLM_GIT_REV) $(OLM_IMAGE_PREFIX)-$(agent):$(OLM_TTL_DURATION) ;)
	@echo "Generating OLM bundle with operator-sdk $(OLM_OPERATOR_SDK_VERSION)"
	GOFLAGS=-mod=mod $(OLM_CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases
	$(foreach agent,$(OLM_AGENT_IMAGES), \
		GOFLAGS=-mod=mod $(OLM_CONTROLLER_GEN) rbac:roleName=$(agent)-role,fileName=$(agent)_generated_role.yaml paths="./cmd/$(agent)/..." output:rbac:artifacts:config=config/rbac/ ;)
	$(OLM_OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(OLM_KUSTOMIZE) edit set image controller=$(OLM_OPERATOR_IMAGE)
	@if [ -n "$(OLM_AGENT_IMAGES)" ]; then \
		agent_subs=""; \
		for agent in $(OLM_AGENT_IMAGES); do \
			agent_upper=$$(echo "$$agent" | tr 'a-z-' 'A-Z_'); \
			agent_subs="$$agent_subs | sed 's|[\$$]{$${agent_upper}_IMG}|$(OLM_IMAGE_PREFIX)-$$agent:$(OLM_TTL_DURATION)|g'"; \
		done; \
		eval "$(OLM_KUSTOMIZE) build config/manifests $$agent_subs | \
			$(OLM_OPERATOR_SDK) generate bundle -q --manifests --metadata --overwrite \
			--version $(VERSION) --channels=$(OLM_CHANNEL) --default-channel=$(OLM_CHANNEL)"; \
	else \
		$(OLM_KUSTOMIZE) build config/manifests | \
			$(OLM_OPERATOR_SDK) generate bundle -q --manifests --metadata --overwrite \
			--version $(VERSION) --channels=$(OLM_CHANNEL) --default-channel=$(OLM_CHANNEL); \
	fi
	@echo "Building $(OLM_BUNDLE_IMAGE)"
	$(OLM_CONTAINER_TOOL) build --platform=$(OLM_PLATFORM) -f bundle.Dockerfile -t $(OLM_BUNDLE_IMAGE) .
	@echo "Pushing source images to ttl.sh"
	$(OLM_CONTAINER_TOOL) push $(OLM_OPERATOR_IMAGE)
	$(foreach agent,$(OLM_AGENT_IMAGES), \
		$(OLM_CONTAINER_TOOL) push $(OLM_IMAGE_PREFIX)-$(agent):$(OLM_TTL_DURATION) ;)
	$(OLM_CONTAINER_TOOL) push $(OLM_BUNDLE_IMAGE)

.PHONY: deploy-olm
deploy-olm: versions ## Display versions, then build source, push temporary images to ttl.sh, and install the operator with operator-sdk.
	@set -euo pipefail; \
	command -v "$(OLM_OC)" >/dev/null 2>&1 || { echo "OpenShift/Kubernetes CLI '$(OLM_OC)' is required" >&2; exit 1; }; \
	if ! identity="$$($(OLM_OC) whoami 2>&1)"; then \
		server="$$($(OLM_OC) whoami --show-server 2>/dev/null || true)"; \
		echo "Unable to reach or authenticate to OpenShift$${server:+ at $$server}." >&2; \
		echo "$$identity" >&2; \
		exit 1; \
	fi; \
	if ! $(OLM_OC) get deployment -n olm olm-operator >/dev/null 2>&1 && \
	   ! $(OLM_OC) get deployment -n openshift-operator-lifecycle-manager olm-operator >/dev/null 2>&1; then \
		echo "Error: OLM is not installed in this cluster. Run 'operator-sdk olm install' or use a cluster with OLM." >&2; \
		exit 1; \
	fi; \
	work_dir="$$(mktemp -d)"; \
	cleanup_work_dir() { chmod -R 777 "$$work_dir" 2>/dev/null || true; rm -rf "$$work_dir"; }; \
	trap cleanup_work_dir EXIT; \
	$(MAKE) olm-build-push || exit 1; \
	$(OLM_OC) get namespace "$(OLM_OPERATOR_NAMESPACE)" >/dev/null 2>&1 || \
		$(OLM_OC) create namespace "$(OLM_OPERATOR_NAMESPACE)"; \
	echo "Installing $(OLM_BUNDLE_IMAGE) into $(OLM_OPERATOR_NAMESPACE)"; \
	$(OLM_OPERATOR_SDK) run bundle "$(OLM_BUNDLE_IMAGE)" \
		--namespace "$(OLM_OPERATOR_NAMESPACE)" \
		--install-mode "$(OLM_INSTALL_MODE)" \
		--operator-group "$(OLM_OPERATOR_GROUP_NAME)" \
		--security-context-config "$(OLM_SECURITY_CONTEXT_CONFIG)"; \
	$(OLM_OC) get csv -n "$(OLM_OPERATOR_NAMESPACE)"

.PHONY: undeploy-olm
undeploy-olm: olm-operator-sdk ## Remove the source operator installed by deploy-olm.
	@set -euo pipefail; \
	command -v "$(OLM_OC)" >/dev/null 2>&1 || { echo "OpenShift/Kubernetes CLI '$(OLM_OC)' is required" >&2; exit 1; }; \
	if ! identity="$$($(OLM_OC) whoami 2>&1)"; then \
		server="$$($(OLM_OC) whoami --show-server 2>/dev/null || true)"; \
		echo "Unable to reach or authenticate to OpenShift$${server:+ at $$server}." >&2; \
		echo "$$identity" >&2; \
		exit 1; \
	fi; \
	if ! $(OLM_OC) get namespace "$(OLM_OPERATOR_NAMESPACE)" >/dev/null 2>&1; then \
		echo "Namespace $(OLM_OPERATOR_NAMESPACE) does not exist; nothing to clean up."; \
		exit 0; \
	fi; \
	bundle_name="$$(basename "$(OLM_BUNDLE_IMAGE)" | sed 's/:.*$$//')"; \
	$(OLM_OPERATOR_SDK) cleanup "$(OLM_PACKAGE_NAME)" \
		--namespace "$(OLM_OPERATOR_NAMESPACE)"; \
	$(OLM_OC) delete catalogsource "$(OLM_CATALOG_SOURCE_NAME)" \
		-n "$(OLM_CATALOG_SOURCE_NAMESPACE)" --ignore-not-found=true; \
	echo "Undeployed $(OLM_PACKAGE_NAME) from $(OLM_OPERATOR_NAMESPACE)"

.PHONY: olm-help
olm-help: ## Show OLM deployment targets.
	@echo "OLM Deployment Targets:"
	@echo "  make deploy-olm          Build, push to ttl.sh, and install via OLM"
	@echo "  make undeploy-olm        Remove operator installed by deploy-olm"
	@echo "  make versions            Show tool and project versions"
	@echo "  make olm-build-push      Build and push images (without installing)"
	@echo ""
	@echo "Variables:"
	@echo "  OLM_OPERATOR_NAME        Operator name (default: $(OLM_OPERATOR_NAME))"
	@echo "  OLM_OPERATOR_NAMESPACE   Namespace (default: $(OLM_OPERATOR_NAMESPACE))"
	@echo "  TTL_DURATION             Image expiry (default: $(TTL_DURATION))"
	@echo "  OLM_AGENT_IMAGES         Space-separated agent names (default: $(OLM_AGENT_IMAGES))"
	@echo ""
	@echo "Agent images:"
	@if [ -n "$(OLM_AGENT_IMAGES)" ]; then \
		echo "  Configured: $(OLM_AGENT_IMAGES)"; \
		for agent in $(OLM_AGENT_IMAGES); do \
			echo "    - $$agent: cmd/$$agent/Dockerfile → $(OLM_IMAGE_PREFIX)-$$agent:$(OLM_TTL_DURATION)"; \
		done; \
	else \
		echo "  None (operator-only deployment)"; \
	fi
