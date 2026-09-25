# dev.mk — Shared Makefile targets for medik8s local development
#
# Include this from any operator's Makefile:
#   TOOLS_DIR ?= $(shell cd .. && pwd)/tools
#   -include $(TOOLS_DIR)/dev/dev.mk
#
# All targets are prefixed with 'dev-' to avoid collisions.

# Dev environment configuration
MEDIK8S_CLUSTER_NAME ?= medik8s-dev
MEDIK8S_NAMESPACE ?= medik8s-system
TOOLS_DIR ?= $(shell cd .. && pwd)/tools
DEV_DIR := $(TOOLS_DIR)/dev

# CONTAINER_TOOL for dev targets: auto-detect docker/podman if not set.
# Honors CONTAINER_TOOL from environment or make command line (e.g. CI uses
# CONTAINER_TOOL=docker to avoid rootless podman issues on GitHub Actions).
# The operator's Makefile may also set CONTAINER_TOOL; we respect that.
# Must be defined before DEV_CLUSTER_TYPE which uses it for KIND_EXPERIMENTAL_PROVIDER.
ifndef CONTAINER_TOOL
  CONTAINER_TOOL := $(shell \
    if command -v podman >/dev/null 2>&1; then echo podman; \
    elif command -v docker >/dev/null 2>&1; then echo docker; \
    else echo ""; \
    fi \
  )
endif
ifeq ($(CONTAINER_TOOL),)
  $(error No container tool found. Please install docker or podman.)
endif

# Detect cluster type: "kind" if a Kind cluster exists, "external" otherwise.
# Uses CONTAINER_TOOL to set KIND_EXPERIMENTAL_PROVIDER (needed for podman).
# When SKIP_KIND=true, force external mode (the user explicitly opted out of Kind).
# Override with DEV_CLUSTER_TYPE=external to force external mode in other cases.
ifeq ($(SKIP_KIND),true)
  DEV_CLUSTER_TYPE ?= external
else
  DEV_CLUSTER_TYPE ?= $(shell \
    if KIND_EXPERIMENTAL_PROVIDER=$(CONTAINER_TOOL) kind get clusters 2>/dev/null | grep -q '^$(MEDIK8S_CLUSTER_NAME)$$'; then echo kind; \
    elif $(KUBECTL) cluster-info --context 'kind-$(MEDIK8S_CLUSTER_NAME)' >/dev/null 2>&1; then echo kind; \
    else echo external; \
    fi \
  )
endif

# Image delivery:
#   registry: pushed to local Kind registry (default for Kind clusters)
#             Required for OLM bundle deployment. Registry is created by dev-setup.
#   local:    loaded directly into Kind nodes via kind load (no registry, no OLM bundle support)
#   ttl.sh:   pushed to ttl.sh (anonymous, ephemeral, no auth required, for external clusters)
#
# Defaults to "registry" for Kind clusters, "ttl.sh" for external.
# Override with DEV_REGISTRY=local to use direct Kind image loading (no OLM bundle support).
MEDIK8S_REGISTRY_NAME ?= kind-registry
MEDIK8S_REGISTRY_PORT ?= 5000
DEV_REGISTRY ?= $(if $(filter kind,$(DEV_CLUSTER_TYPE)),registry,ttl.sh)
ifneq ($(filter $(DEV_REGISTRY),registry local ttl.sh),$(DEV_REGISTRY))
  $(error Unsupported DEV_REGISTRY "$(DEV_REGISTRY)". Expected registry, local, or ttl.sh.)
endif

# Target platform for images to build
DEV_PLATFORM ?= linux/amd64
DEV_PLATFORM_FLAG := $(if $(DEV_PLATFORM),--platform=$(DEV_PLATFORM))
TTL_SH_TTL ?= 2h
ifeq ($(DEV_REGISTRY),registry)
  DEV_IMG ?= $(MEDIK8S_REGISTRY_NAME):$(MEDIK8S_REGISTRY_PORT)/medik8s/$(OPERATOR_NAME):dev
  # For pushing from host, use localhost since the registry is port-forwarded
  DEV_IMG_PUSH ?= localhost:$(MEDIK8S_REGISTRY_PORT)/medik8s/$(OPERATOR_NAME):dev
else ifeq ($(DEV_REGISTRY),local)
  DEV_IMG ?= localhost:5000/medik8s/$(OPERATOR_NAME):dev
  DEV_IMG_PUSH ?= $(DEV_IMG)
else
  TTL_SH_SUFFIX := $(shell head -c 32 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 8)
  DEV_IMG ?= ttl.sh/medik8s-$(OPERATOR_NAME)-$(TTL_SH_SUFFIX):$(TTL_SH_TTL)
  DEV_IMG_PUSH ?= $(DEV_IMG)
endif

# Detect kubectl or oc
KUBECTL ?= $(shell \
  if command -v kubectl >/dev/null 2>&1; then echo kubectl; \
  elif command -v oc >/dev/null 2>&1; then echo oc; \
  else echo ""; \
  fi \
)
ifeq ($(KUBECTL),)
  $(error No kubectl or oc found. Please install kubectl or oc.)
endif

# Verify Go is available
ifeq ($(shell command -v go 2>/dev/null),)
  $(error Go not found. Please install Go from https://go.dev/doc/install or add it to your PATH.)
endif

# Warn early if OPERATOR_NAME is not set — dev-build and dev-deploy will fail without it.
ifndef OPERATOR_NAME
  $(warning OPERATOR_NAME is not set. Targets dev-build, dev-deploy, dev-redeploy will not work.)
endif

export MEDIK8S_CLUSTER_NAME
export MEDIK8S_NAMESPACE
export KIND_BLOCK_STORAGE
export KIND_BLOCK_STATE_DIR

# Helper to find the namespace for this operator's deployment.
# First tries the kustomization namespace (works even when OPERATOR_NAME != namespace prefix,
# e.g. SBR uses "sbr-operator-system" but OPERATOR_NAME is "storage-based-remediation").
# Falls back to label-based cluster queries filtered by operator name.
_dev_find_ns = $(shell \
  NS=$$({ grep -rh '^namespace:' config/default/kustomization.yaml config/patches/*/kustomization.yaml config/components/*/kustomization.yaml 2>/dev/null || true; } | head -1 | awk '{print $$2}'); \
  if [ -n "$$NS" ] && $(KUBECTL) get namespace "$$NS" >/dev/null 2>&1; then echo "$$NS"; exit 0; fi; \
  NS=$$($(KUBECTL) get deployment -A -l control-plane=controller-manager --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | grep -i '$(OPERATOR_NAME)\|$(subst -,.,$(OPERATOR_NAME))' | head -1); \
  if [ -z "$$NS" ]; then \
    NS=$$($(KUBECTL) get deployment -A -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | grep -i '$(OPERATOR_NAME)\|$(subst -,.,$(OPERATOR_NAME))' | head -1); \
  fi; \
  if [ -z "$$NS" ]; then \
    NS=$$($(KUBECTL) get deployment -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | grep '$(OPERATOR_NAME)' | awk '{print $$1}' | head -1); \
  fi; \
  echo "$$NS" \
)

##@ Dev Environment

.PHONY: dev-cluster-info
dev-cluster-info: ## Show cluster version, connection info, and node status
	@$(KUBECTL) version -o=yaml 2>/dev/null || $(KUBECTL) version
	@echo ""
	@$(KUBECTL) cluster-info
	@echo ""
	@$(KUBECTL) get nodes -o=wide

.PHONY: dev-setup
dev-setup: ## Create Kind cluster and configure dependencies (SKIP_KIND=true for existing clusters, KIND_HA=true for 3 CP)
	@$(DEV_DIR)/setup.sh $(if $(filter true,$(SKIP_KIND)),--skip-kind) $(if $(filter true,$(KIND_HA)),--ha)

.PHONY: dev-teardown
dev-teardown: ## Destroy the Kind dev cluster
ifeq ($(SKIP_KIND),true)
	@echo "External cluster — nothing to tear down. Use 'make dev-undeploy' to remove operators."
else
	@$(DEV_DIR)/teardown.sh
endif

.PHONY: dev-build
dev-build: ## Build operator image and load into Kind or push to registry/ttl.sh
	@# For local: patch imagePullPolicy to IfNotPresent (no registry, images loaded directly).
	@# For registry/ttl.sh: keep imagePullPolicy as Always (image pulled from registry).
	@# The SNR controller reconciles DaemonSets from templates baked into the image,
	@# so this must be done before the container build, not after.
	@# Files are restored after build (even on failure) via trap.
ifeq ($(DEV_REGISTRY),local)
	@patched=""; \
	for f in $$(find install/ -name '*.yaml' 2>/dev/null); do \
		if grep -q 'imagePullPolicy: Always' "$$f"; then \
			sed -i.bak 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' "$$f" && rm -f "$$f.bak"; \
			patched="$$patched $$f"; \
			echo "  Patched $$f imagePullPolicy for dev build."; \
		fi; \
	done; \
	restore() { for f in $$patched; do sed -i.bak 's/imagePullPolicy: IfNotPresent/imagePullPolicy: Always/' "$$f" && rm -f "$$f.bak"; done; }; \
	TMP_IMAGE_DIR=$$(mktemp -d "$${TMPDIR:-/tmp}/dev-image.XXXXXX"); \
	TMPTAR="$$TMP_IMAGE_DIR/image.tar"; \
	cleanup() { rm -rf "$$TMP_IMAGE_DIR"; restore; }; \
	trap cleanup EXIT; \
	$(CONTAINER_TOOL) build -t $(DEV_IMG) . && \
	$(CONTAINER_TOOL) save -o "$$TMPTAR" $(DEV_IMG) && \
	KIND_EXPERIMENTAL_PROVIDER=$(if $(filter podman,$(CONTAINER_TOOL)),podman,docker) \
		kind load image-archive "$$TMPTAR" --name $(MEDIK8S_CLUSTER_NAME)
else ifeq ($(DEV_REGISTRY),registry)
	$(CONTAINER_TOOL) build -t $(DEV_IMG) .
	@# Tag for localhost push (registry is port-forwarded to 127.0.0.1)
	$(CONTAINER_TOOL) tag $(DEV_IMG) $(DEV_IMG_PUSH)
	$(CONTAINER_TOOL) push $(DEV_IMG_PUSH)
	@echo ""
	@echo "  Image pushed to local registry: $(DEV_IMG)"
else
	$(CONTAINER_TOOL) build $(DEV_PLATFORM_FLAG) -t $(DEV_IMG) .
	$(CONTAINER_TOOL) push $(DEV_IMG)
	@echo ""
	@echo "  Image pushed to $(DEV_IMG) ($(if $(DEV_PLATFORM),$(DEV_PLATFORM),native))"
	@echo "  Image will expire after $(TTL_SH_TTL)."
endif

.PHONY: dev-deploy
dev-deploy: dev-build install $(if $(ENVSUBST),envsubst) ## Build, load image, install CRDs, and deploy operator
	@# Backup kustomization.yaml, set dev image, build+apply, then restore (even on failure).
	@cp config/manager/kustomization.yaml config/manager/kustomization.yaml.dev-bak; \
	trap 'mv config/manager/kustomization.yaml.dev-bak config/manager/kustomization.yaml' EXIT; \
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(DEV_IMG) && cd ../.. && \
	ENVSUBST_BIN="$(ENVSUBST)"; \
	if [ -n "$$ENVSUBST_BIN" ] && [ -x "$$ENVSUBST_BIN" ]; then \
		export IMG=$(DEV_IMG) && $(KUSTOMIZE) build config/default 2> >(grep -v "Warning: 'commonLabels'" >&2) | $$ENVSUBST_BIN | $(KUBECTL) apply -f -; \
	else \
		$(KUSTOMIZE) build config/default 2> >(grep -v "Warning: 'commonLabels'" >&2) | $(KUBECTL) apply -f -; \
	fi
	@# Detect the operator namespace from kustomization files (reliable, no cluster query needed).
	@# The namespace may be in config/default/ or in a component/patch kustomization.yaml.
	@NS=$$({ grep -rh '^namespace:' config/default/kustomization.yaml config/patches/*/kustomization.yaml config/components/*/kustomization.yaml 2>/dev/null || true; } | head -1 | awk '{print $$2}'); \
	if [ -z "$$NS" ]; then \
		NS=$$($(KUBECTL) get deployment -A -l control-plane=controller-manager --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | grep -i '$(OPERATOR_NAME)' | head -1); \
	fi; \
	if [ -n "$$NS" ]; then \
		if [ -d config/webhook ]; then \
			SVC_RAW=$$(grep -h '^  name:' config/webhook/service.yaml 2>/dev/null | head -1 | awk '{print $$2}'); \
			PREFIX=$$({ grep -rh '^namePrefix:' config/default/kustomization.yaml config/patches/*/kustomization.yaml config/components/*/kustomization.yaml 2>/dev/null || true; } | head -1 | awk '{print $$2}'); \
			SVC="$${PREFIX}$${SVC_RAW}"; \
			DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l control-plane=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
			if [ -z "$$DEPLOY" ]; then \
				DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
			fi; \
			if [ -n "$$DEPLOY" ] && [ -n "$$SVC" ]; then \
				$(DEV_DIR)/enable-certmanager.sh $$NS $$DEPLOY $$SVC; \
			else \
				echo "  Warning: config/webhook/ exists but could not determine deployment ($$DEPLOY) or service ($$SVC)."; \
			fi; \
		else \
			echo "  Skipping cert-manager setup (no config/webhook/ directory)."; \
		fi; \
		DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l control-plane=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		if [ -z "$$DEPLOY" ]; then \
			DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		fi; \
		if [ -n "$$DEPLOY" ]; then \
			echo "=== Waiting for operator deployment to be ready ==="; \
			$(KUBECTL) wait --for=condition=Available deployment/$$DEPLOY -n $$NS --timeout=300s || \
				{ echo "Error: deployment $$DEPLOY is not ready. Check logs with 'make dev-logs'."; exit 1; }; \
			echo "=== Waiting 15s for operator webhooks to stabilize ==="; \
			sleep 15; \
		fi; \
	else \
		echo "  Warning: could not detect operator namespace. Skipping cert-manager setup."; \
	fi
	@# Create NHC CR after webhooks are ready (cert-manager must be configured first).
	@# Auto-detects any deployed remediator template (SNR, FAR, MDR, SBR).
	@if $(KUBECTL) get crd nodehealthchecks.remediation.medik8s.io &>/dev/null && \
	    ($(KUBECTL) get selfnoderemediationtemplate -A --no-headers 2>/dev/null | grep -q . || \
	     $(KUBECTL) get fenceagentsremediationtemplate -A --no-headers 2>/dev/null | grep -q . || \
	     $(KUBECTL) get machinedeletionremediationtemplate -A --no-headers 2>/dev/null | grep -q . || \
	     $(KUBECTL) get storagebasedremediationtemplate -A --no-headers 2>/dev/null | grep -q .); then \
		$(DEV_DIR)/create-nhc.sh; \
	fi
	@# SBR-specific: create a StorageBasedRemediationConfig CR so the operator
	@# provisions its DaemonSet and PVC.  Only runs when deploying SBR itself.
ifeq ($(OPERATOR_NAME),storage-based-remediation)
	@if $(KUBECTL) get crd storagebasedremediationconfigs.storage-based-remediation.medik8s.io &>/dev/null; then \
		NS=$$({ grep -rh '^namespace:' config/default/kustomization.yaml config/patches/*/kustomization.yaml config/components/*/kustomization.yaml 2>/dev/null || true; } | head -1 | awk '{print $$2}'); \
		if [ -z "$$NS" ]; then NS=sbr-operator-system; fi; \
		if ! $(KUBECTL) get storagebasedremediationconfig -n $$NS --no-headers 2>/dev/null | grep -q .; then \
			echo "=== Creating StorageBasedRemediationConfig CR ==="; \
			$(KUBECTL) apply -n $$NS -f config/samples/storage-based-remediation_v1alpha1_storagebasedremediationconfig.yaml; \
		else \
			echo "  StorageBasedRemediationConfig already exists in $$NS — skipping."; \
		fi; \
	fi
endif

.PHONY: dev-undeploy
dev-undeploy: ## Remove operator from dev cluster
	@if [ -n "$(KUSTOMIZE)" ] && [ -f config/default/kustomization.yaml ]; then \
		$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found -f -; \
	else \
		NS="$(_dev_find_ns)"; \
		if [ -n "$$NS" ]; then \
			echo "Deleting namespace $$NS..."; \
			$(KUBECTL) delete namespace "$$NS" --ignore-not-found; \
		else \
			echo "No operator deployment found to undeploy."; \
		fi; \
	fi

.PHONY: dev-bundle-run
dev-bundle-run: dev-build ## Deploy operator via OLM bundle (requires OLM + operator-sdk + local registry)
	@if ! command -v operator-sdk >/dev/null 2>&1; then \
		echo "Error: operator-sdk is required for bundle-run. Install from: https://sdk.operatorframework.io/docs/installation/"; \
		exit 1; \
	fi
ifeq ($(DEV_REGISTRY),local)
	@echo "Error: dev-bundle-run requires a registry (OLM pulls images from a registry)."
	@echo "  Use DEV_REGISTRY=registry (default) or DEV_REGISTRY=ttl.sh."
	@echo "  Or use 'make dev-deploy' for direct deployment without OLM."
	@exit 1
else ifeq ($(DEV_REGISTRY),registry)
	$(MAKE) bundle bundle-build bundle-push bundle-run \
		IMG=$(DEV_IMG) BUNDLE_IMG=$(DEV_IMG)-bundle \
		IMAGE_REGISTRY=$(MEDIK8S_REGISTRY_NAME):$(MEDIK8S_REGISTRY_PORT)
else
	$(MAKE) bundle bundle-build bundle-push bundle-run IMG=$(DEV_IMG) BUNDLE_IMG=$(DEV_IMG)-bundle
endif

# Source-to-OLM images for CI and external-cluster upgrade testing.
#
# Most callers only need to set VERSION, PREVIOUS_VERSION, and DEV_IMG. The
# DEV_OLM_* variables below are override points for differences between the
# operator repositories; product-specific bundle generation stays in each
# operator Makefile.

# Bundle identity and OLM installation settings.
DEV_OLM_VERSION ?= $(if $(VERSION),$(VERSION),$(DEFAULT_VERSION))
DEV_OLM_PACKAGE_NAME ?= $(OPERATOR_NAME)
DEV_OLM_OPERATOR_NAMESPACE ?= $(if $(OPERATOR_NAMESPACE),$(OPERATOR_NAMESPACE),openshift-workload-availability)
DEV_OLM_CHANNEL ?= stable
DEV_OLM_CHANNELS ?= $(if $(CHANNELS),$(CHANNELS),$(DEV_OLM_CHANNEL))
DEV_OLM_INSTALL_MODE ?= AllNamespaces
DEV_OLM_SECURITY_CONTEXT_CONFIG ?= restricted

# Image names derived from DEV_IMG.
#
# Preserve the registry port while moving the suffix before the image tag.
# Example: ttl.sh/operator-run:2h -> ttl.sh/operator-run-bundle:2h.
DEV_OLM_IMAGE_REPOSITORY := $(shell printf '%s' '$(DEV_IMG)' | sed 's/:[^:]*$$//')
DEV_OLM_IMAGE_TAG := $(shell printf '%s' '$(DEV_IMG)' | sed 's/^.*://')
DEV_OLM_BUNDLE_IMAGE ?= $(DEV_OLM_IMAGE_REPOSITORY)-bundle:$(DEV_OLM_IMAGE_TAG)
DEV_OLM_CATALOG_IMAGE ?= $(DEV_OLM_IMAGE_REPOSITORY)-catalog:$(DEV_OLM_IMAGE_TAG)

# Operator-specific build hooks.
#
# SBR is detected through cmd/*agent*/Dockerfile and gets a separate operand
# image. NHC is detected through config/manifests/ocp and uses its OCP bundle
# target. Other repositories use their normal bundle-build target.
DEV_OLM_AGENT_DOCKERFILE ?= $(firstword $(wildcard cmd/*agent*/Dockerfile))
DEV_OLM_AGENT_IMAGE ?= $(if $(DEV_OLM_AGENT_DOCKERFILE),$(DEV_OLM_IMAGE_REPOSITORY)-agent:$(DEV_OLM_IMAGE_TAG),)
DEV_OLM_BUNDLE_BUILD_TARGET ?= $(if $(wildcard config/manifests/ocp),bundle-build-ocp,bundle-build)
DEV_OLM_EXTRA_BUILD_TARGETS ?=

# FBC workspace and optional upgrade source.
# PREVIOUS_VERSION selects the released bundle that the candidate replaces.
DEV_OLM_CATALOG_DIR ?= .dev-catalog
DEV_OLM_CATALOG_DOCKERFILE ?= $(DEV_OLM_CATALOG_DIR).Dockerfile
DEV_OLM_RELEASED_BUNDLE_NAME = $(if $(filter %-operator,$(OPERATOR_NAME)),$(OPERATOR_NAME)-bundle,$(OPERATOR_NAME)-operator-bundle)
DEV_OLM_RELEASED_BUNDLE_REPOSITORY ?= registry.redhat.io/workload-availability/$(DEV_OLM_RELEASED_BUNDLE_NAME)
DEV_OLM_PREVIOUS_BUNDLE_IMAGE ?= $(if $(PREVIOUS_VERSION),$(DEV_OLM_RELEASED_BUNDLE_REPOSITORY):v$(PREVIOUS_VERSION),)

# Pinned tools used directly by the shared targets. Operator Makefiles retain
# ownership of their controller-gen and kustomize versions.
DEV_OLM_OPERATOR_SDK_VERSION ?= $(if $(OPERATOR_SDK_VERSION),$(OPERATOR_SDK_VERSION),v1.42.3)
DEV_OLM_OPM_VERSION ?= v1.42.0
DEV_OLM_CURL ?= curl
DEV_OLM_GOOS ?= $(shell go env GOOS 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]')
DEV_OLM_GOARCH ?= $(shell go env GOARCH 2>/dev/null || uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
DEV_OLM_LOCALBIN ?= $(CURDIR)/bin/dev-olm
DEV_OLM_OPERATOR_SDK ?= $(DEV_OLM_LOCALBIN)/operator-sdk-$(DEV_OLM_OPERATOR_SDK_VERSION)
DEV_OLM_OPM ?= $(DEV_OLM_LOCALBIN)/opm-$(DEV_OLM_OPM_VERSION)
DEV_OLM_OPERATOR_SDK_ASSET = operator-sdk_$(DEV_OLM_GOOS)_$(DEV_OLM_GOARCH)
DEV_OLM_OPM_ASSET = $(DEV_OLM_GOOS)-$(DEV_OLM_GOARCH)-opm
DEV_OLM_OPERATOR_SDK_RELEASE_URL = https://github.com/operator-framework/operator-sdk/releases/download/$(DEV_OLM_OPERATOR_SDK_VERSION)
DEV_OLM_OPM_RELEASE_URL = https://github.com/operator-framework/operator-registry/releases/download/$(DEV_OLM_OPM_VERSION)

# Verify downloads against the checksums published with each upstream release.
# sha256sum is normally available on Linux; shasum is the macOS fallback.
define DEV_OLM_VERIFY_SHA256
expected_checksum="$$($(DEV_OLM_CURL) --fail --retry 5 -sSL "$(3)/checksums.txt" | \
	awk -v asset="$(2)" '$$2 == asset { print $$1; exit }')"; \
test -n "$$expected_checksum" || { echo "Error: checksum not found for $(2)." >&2; exit 1; }; \
if command -v sha256sum >/dev/null 2>&1; then \
	actual_checksum="$$(sha256sum "$(1)" | awk '{ print $$1 }')"; \
elif command -v shasum >/dev/null 2>&1; then \
	actual_checksum="$$(shasum -a 256 "$(1)" | awk '{ print $$1 }')"; \
else \
	echo "Error: sha256sum or shasum is required." >&2; exit 1; \
fi; \
test "$$actual_checksum" = "$$expected_checksum" || \
	{ echo "Error: checksum verification failed for $(2)." >&2; exit 1; }
endef

.PHONY: dev-olm-operator-sdk dev-olm-opm dev-olm-tools
dev-olm-operator-sdk:
	@if [ ! -x "$(DEV_OLM_OPERATOR_SDK)" ]; then \
		command -v $(DEV_OLM_CURL) >/dev/null 2>&1 || { echo "Error: $(DEV_OLM_CURL) is required." >&2; exit 1; }; \
		mkdir -p "$(dir $(DEV_OLM_OPERATOR_SDK))"; \
		$(DEV_OLM_CURL) --fail --retry 5 -sSLo "$(DEV_OLM_OPERATOR_SDK).tmp" \
			"$(DEV_OLM_OPERATOR_SDK_RELEASE_URL)/$(DEV_OLM_OPERATOR_SDK_ASSET)"; \
		$(call DEV_OLM_VERIFY_SHA256,$(DEV_OLM_OPERATOR_SDK).tmp,$(DEV_OLM_OPERATOR_SDK_ASSET),$(DEV_OLM_OPERATOR_SDK_RELEASE_URL)); \
		chmod +x "$(DEV_OLM_OPERATOR_SDK).tmp"; \
		mv "$(DEV_OLM_OPERATOR_SDK).tmp" "$(DEV_OLM_OPERATOR_SDK)"; \
	fi

dev-olm-opm:
	@if [ ! -x "$(DEV_OLM_OPM)" ]; then \
		command -v $(DEV_OLM_CURL) >/dev/null 2>&1 || { echo "Error: $(DEV_OLM_CURL) is required." >&2; exit 1; }; \
		mkdir -p "$(dir $(DEV_OLM_OPM))"; \
		$(DEV_OLM_CURL) --fail --retry 5 -sSLo "$(DEV_OLM_OPM).tmp" \
			"$(DEV_OLM_OPM_RELEASE_URL)/$(DEV_OLM_OPM_ASSET)"; \
		$(call DEV_OLM_VERIFY_SHA256,$(DEV_OLM_OPM).tmp,$(DEV_OLM_OPM_ASSET),$(DEV_OLM_OPM_RELEASE_URL)); \
		chmod +x "$(DEV_OLM_OPM).tmp"; \
		mv "$(DEV_OLM_OPM).tmp" "$(DEV_OLM_OPM)"; \
	fi

dev-olm-tools: dev-olm-operator-sdk dev-olm-opm

.PHONY: dev-olm-validate-inputs
dev-olm-validate-inputs:
	@test -n "$(DEV_OLM_VERSION)" || { echo "Error: VERSION or DEV_OLM_VERSION is required." >&2; exit 1; }
	@if [ "$(OPERATOR_NAME)" = node-healthcheck-operator ]; then \
		case '$(origin CONSOLE_PLUGIN_IMAGE)' in 'command line'|'environment'|'environment override') ;; \
			*) echo "Error: NHC requires an explicit CONSOLE_PLUGIN_IMAGE digest pullspec." >&2; exit 1 ;; esac; \
		case '$(origin MUST_GATHER_IMAGE)' in 'command line'|'environment'|'environment override') ;; \
			*) echo "Error: NHC requires an explicit MUST_GATHER_IMAGE digest pullspec." >&2; exit 1 ;; esac; \
		for image in "$(CONSOLE_PLUGIN_IMAGE)" "$(MUST_GATHER_IMAGE)"; do \
			printf '%s\n' "$$image" | grep -Eq '@sha256:[0-9a-f]{64}$$' || \
				{ echo "Error: NHC related images must use digest pullspecs." >&2; exit 1; }; \
		done; \
	fi

.PHONY: dev-olm-build-push
dev-olm-build-push: dev-olm-validate-inputs dev-build dev-olm-operator-sdk ## Build and push source, operand, and OLM bundle images
ifeq ($(DEV_REGISTRY),local)
	@echo "Error: dev-olm-build-push requires a registry; use DEV_REGISTRY=ttl.sh for CI." >&2
	@exit 1
else
	@if [ -n "$(DEV_OLM_AGENT_DOCKERFILE)" ]; then \
		echo "=== Building operand image $(DEV_OLM_AGENT_IMAGE) ==="; \
		$(CONTAINER_TOOL) build $(DEV_PLATFORM_FLAG) -f "$(DEV_OLM_AGENT_DOCKERFILE)" -t "$(DEV_OLM_AGENT_IMAGE)" .; \
		$(CONTAINER_TOOL) push "$(DEV_OLM_AGENT_IMAGE)"; \
	fi
	@if [ -n "$(DEV_OLM_EXTRA_BUILD_TARGETS)" ]; then \
		$(MAKE) $(DEV_OLM_EXTRA_BUILD_TARGETS) \
			CONTAINER_TOOL="$(CONTAINER_TOOL)" \
			VERSION="$(DEV_OLM_VERSION)" \
			IMG="$(DEV_IMG)" \
			AGENT_IMG="$(DEV_OLM_AGENT_IMAGE)" \
			BUNDLE_IMG="$(DEV_OLM_BUNDLE_IMAGE)"; \
	fi
	# Forward conventional image and bundle variables to the operator-owned
	# bundle target. This keeps repository-specific manifest generation there.
	@echo "=== Generating bundle with $(DEV_OLM_BUNDLE_BUILD_TARGET) ==="
	$(MAKE) $(DEV_OLM_BUNDLE_BUILD_TARGET) \
		CONTAINER_TOOL="$(CONTAINER_TOOL)" \
		VERSION="$(DEV_OLM_VERSION)" \
		IMG="$(DEV_IMG)" \
		AGENT_IMG="$(DEV_OLM_AGENT_IMAGE)" \
		BUNDLE_IMG="$(DEV_OLM_BUNDLE_IMAGE)" \
		CHANNELS="$(DEV_OLM_CHANNELS)" \
		DEFAULT_CHANNEL="$(DEV_OLM_CHANNEL)" \
		PREVIOUS_VERSION="$(PREVIOUS_VERSION)"
	"$(DEV_OLM_OPERATOR_SDK)" bundle validate ./bundle --select-optional suite=operatorframework
	$(CONTAINER_TOOL) push "$(DEV_OLM_BUNDLE_IMAGE)"
endif

.PHONY: dev-olm-catalog-build
dev-olm-catalog-build: dev-olm-build-push dev-olm-opm ## Build an FBC image connecting a released bundle to the source bundle
	@rm -rf "$(DEV_OLM_CATALOG_DIR)" "$(DEV_OLM_CATALOG_DOCKERFILE)"
	@mkdir -p "$(DEV_OLM_CATALOG_DIR)"
	"$(DEV_OLM_OPM)" generate dockerfile "$(DEV_OLM_CATALOG_DIR)"
	"$(DEV_OLM_OPM)" init "$(DEV_OLM_PACKAGE_NAME)" \
		--default-channel="$(DEV_OLM_CHANNEL)" \
		--description=./README.md \
		--output yaml > "$(DEV_OLM_CATALOG_DIR)/index.yaml"
	@candidate="$$($(DEV_OLM_OPM) render "$(DEV_OLM_BUNDLE_IMAGE)" --output yaml)"; \
		printf '%s\n' "$$candidate" >> "$(DEV_OLM_CATALOG_DIR)/index.yaml"; \
		candidate_name="$$(printf '%s\n' "$$candidate" | awk '/^schema: olm.bundle$$|^image: /{bundle=1; next} bundle && /^name: /{print $$2; exit}')"; \
		test -n "$$candidate_name" || { echo "Error: unable to read candidate bundle name." >&2; exit 1; }; \
		previous_name=''; \
		if [ -n "$(DEV_OLM_PREVIOUS_BUNDLE_IMAGE)" ]; then \
			echo "=== Rendering previous bundle $(DEV_OLM_PREVIOUS_BUNDLE_IMAGE) ==="; \
			previous="$$($(DEV_OLM_OPM) render "$(DEV_OLM_PREVIOUS_BUNDLE_IMAGE)" --output yaml)"; \
			printf '%s\n' "$$previous" >> "$(DEV_OLM_CATALOG_DIR)/index.yaml"; \
			previous_name="$$(printf '%s\n' "$$previous" | awk '/^schema: olm.bundle$$|^image: /{bundle=1; next} bundle && /^name: /{print $$2; exit}')"; \
			test -n "$$previous_name" || { echo "Error: unable to read previous bundle name." >&2; exit 1; }; \
		fi; \
		for channel in $$(printf '%s' "$(DEV_OLM_CHANNELS)" | tr ',' ' '); do \
			printf '%s\n' '---' 'schema: olm.channel' "package: $(DEV_OLM_PACKAGE_NAME)" "name: $$channel" 'entries:' "  - name: $$candidate_name" >> "$(DEV_OLM_CATALOG_DIR)/index.yaml"; \
			if [ -n "$$previous_name" ] && [ "$$previous_name" != "$$candidate_name" ]; then \
				printf '%s\n' "    replaces: $$previous_name" "  - name: $$previous_name" >> "$(DEV_OLM_CATALOG_DIR)/index.yaml"; \
			fi; \
		done
	"$(DEV_OLM_OPM)" validate "$(DEV_OLM_CATALOG_DIR)"
	$(CONTAINER_TOOL) build $(DEV_PLATFORM_FLAG) \
		-f "$(DEV_OLM_CATALOG_DOCKERFILE)" \
		-t "$(DEV_OLM_CATALOG_IMAGE)" .
	@rm -rf "$(DEV_OLM_CATALOG_DIR)" "$(DEV_OLM_CATALOG_DOCKERFILE)"

.PHONY: dev-olm-catalog-push
dev-olm-catalog-push: dev-olm-catalog-build ## Build and push an FBC image for source upgrade testing
	$(CONTAINER_TOOL) push $(DEV_OLM_CATALOG_IMAGE)

.PHONY: dev-olm-print-released-bundle-repository
dev-olm-print-released-bundle-repository: ## Print the configured released bundle repository
	@echo "$(DEV_OLM_RELEASED_BUNDLE_REPOSITORY)"

.PHONY: dev-olm-deploy dev-olm-upgrade dev-olm-undeploy
dev-olm-deploy: dev-olm-build-push ## Install the source bundle with operator-sdk
	@$(KUBECTL) get namespace "$(DEV_OLM_OPERATOR_NAMESPACE)" >/dev/null 2>&1 || \
		$(KUBECTL) create namespace "$(DEV_OLM_OPERATOR_NAMESPACE)"
	@if [ "$(OPERATOR_NAME)" = self-node-remediation ]; then \
		$(KUBECTL) label --overwrite namespace "$(DEV_OLM_OPERATOR_NAMESPACE)" \
			pod-security.kubernetes.io/enforce=privileged \
			security.openshift.io/scc.podSecurityLabelSync=false; \
	fi
	"$(DEV_OLM_OPERATOR_SDK)" -n "$(DEV_OLM_OPERATOR_NAMESPACE)" cleanup "$(DEV_OLM_PACKAGE_NAME)" --delete-all >/dev/null 2>&1 || true
	"$(DEV_OLM_OPERATOR_SDK)" -n "$(DEV_OLM_OPERATOR_NAMESPACE)" run bundle "$(DEV_OLM_BUNDLE_IMAGE)" \
		--install-mode="$(DEV_OLM_INSTALL_MODE)" --security-context-config="$(DEV_OLM_SECURITY_CONTEXT_CONFIG)"

dev-olm-upgrade: dev-olm-build-push ## Upgrade an existing operator-sdk bundle installation
	"$(DEV_OLM_OPERATOR_SDK)" -n "$(DEV_OLM_OPERATOR_NAMESPACE)" run bundle-upgrade "$(DEV_OLM_BUNDLE_IMAGE)" \
		--security-context-config="$(DEV_OLM_SECURITY_CONTEXT_CONFIG)"

dev-olm-undeploy: dev-olm-operator-sdk ## Remove an operator-sdk bundle installation
	@if ! $(KUBECTL) get namespace "$(DEV_OLM_OPERATOR_NAMESPACE)" >/dev/null 2>&1; then \
		echo "Namespace $(DEV_OLM_OPERATOR_NAMESPACE) does not exist; nothing to remove."; \
	else \
		"$(DEV_OLM_OPERATOR_SDK)" -n "$(DEV_OLM_OPERATOR_NAMESPACE)" cleanup "$(DEV_OLM_PACKAGE_NAME)" --delete-all || \
			echo "Warning: operator-sdk cleanup reported an error; the development cluster can be discarded." >&2; \
	fi

.PHONY: dev-bundle-cleanup
dev-bundle-cleanup: ## Remove OLM bundle deployment
	@if ! command -v operator-sdk >/dev/null 2>&1; then \
		echo "Error: operator-sdk is required for bundle-cleanup."; \
		exit 1; \
	fi
	$(MAKE) bundle-cleanup BUNDLE_IMG=$(DEV_IMG)-bundle \
		$(if $(filter registry,$(DEV_REGISTRY)),IMAGE_REGISTRY=$(MEDIK8S_REGISTRY_NAME):$(MEDIK8S_REGISTRY_PORT))

.PHONY: dev-redeploy
dev-redeploy: dev-build ## Rebuild image and restart operator pods (deletes pods to pick up new image)
	@NS="$(_dev_find_ns)"; \
	if [ -n "$$NS" ]; then \
		echo "Deleting operator pods in $$NS to pick up new image..."; \
		$(KUBECTL) delete pods -n $$NS -l control-plane=controller-manager --force --grace-period=0 2>/dev/null || true; \
		$(KUBECTL) delete pods -n $$NS -l app.kubernetes.io/component=controller-manager --force --grace-period=0 2>/dev/null || true; \
		DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l control-plane=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		if [ -z "$$DEPLOY" ]; then \
			DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		fi; \
		if [ -n "$$DEPLOY" ]; then \
			$(KUBECTL) wait --for=condition=Available deployment/$$DEPLOY -n $$NS --timeout=300s || \
				echo "Warning: deployment is not ready. Check logs with 'make dev-logs'."; \
		fi; \
	else \
		echo "Could not find deployment to restart. Run 'make dev-deploy' first."; \
	fi

.PHONY: dev-logs
dev-logs: ## Tail operator controller-manager logs
	@NS="$(_dev_find_ns)"; \
	if [ -n "$$NS" ]; then \
		POD=$$($(KUBECTL) get pods -n $$NS -l control-plane=controller-manager -o name 2>/dev/null | head -1); \
		if [ -z "$$POD" ]; then \
			POD=$$($(KUBECTL) get pods -n $$NS -l app.kubernetes.io/component=controller-manager -o name 2>/dev/null | head -1); \
		fi; \
		if [ -n "$$POD" ]; then \
			$(KUBECTL) logs -f -n $$NS $$POD --all-containers --tail=50; \
		else \
			echo "No controller-manager pod found in $$NS. Is the operator running?"; \
		fi; \
	else \
		echo "No controller-manager pod found. Run 'make dev-deploy' first."; \
	fi

.PHONY: dev-wait
dev-wait: ## Wait for all medik8s operator pods to be ready
	@echo "=== Waiting for operator deployments to be ready ==="
	@FOUND=false; \
	for label in control-plane=controller-manager app.kubernetes.io/component=controller-manager; do \
		for ns in $$($(KUBECTL) get deployment -A -l $$label --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | sort -u); do \
			for deploy in $$($(KUBECTL) get deployment -n $$ns -l $$label --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do \
				FOUND=true; \
				echo "  Waiting for $$ns/$$deploy..."; \
				$(KUBECTL) wait --for=condition=Available deployment/$$deploy -n $$ns --timeout=300s || \
					echo "  Warning: $$ns/$$deploy is not ready."; \
			done; \
		done; \
	done; \
	if [ "$$FOUND" = false ]; then \
		echo "  No operator deployments found. Run 'make dev-deploy' first."; \
		exit 1; \
	fi
	@echo "=== Waiting for operator daemonsets to be ready ==="
	@for ns in $$($(KUBECTL) get daemonset -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | sort -u); do \
		for ds in $$($(KUBECTL) get daemonset -n $$ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -E 'remediation|maintenance|fence'); do \
			echo "  Waiting for $$ns/$$ds..."; \
			$(KUBECTL) rollout status daemonset/$$ds -n $$ns --timeout=300s || \
				echo "  Warning: $$ns/$$ds is not ready."; \
		done; \
	done
	@echo "=== Waiting for webhook endpoints to be ready ==="
	@for ns in $$($(KUBECTL) get endpoints -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | grep webhook | awk '{print $$1}' | sort -u); do \
		for ep in $$($(KUBECTL) get endpoints -n $$ns --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep webhook); do \
			echo "  Waiting for $$ns/$$ep..."; \
			for i in $$(seq 1 30); do \
				ADDRS=$$($(KUBECTL) get endpoints/$$ep -n $$ns -o jsonpath='{.subsets[0].addresses}' 2>/dev/null); \
				if [ -n "$$ADDRS" ]; then \
					echo "  $$ns/$$ep ready."; \
					break; \
				fi; \
				sleep 2; \
			done; \
			if [ -z "$$ADDRS" ]; then \
				echo "  Warning: $$ns/$$ep has no ready addresses after 60s."; \
			fi; \
		done; \
	done
	@echo "=== Cleaning up duplicate OLM webhook configurations ==="
	@# When multiple operators are deployed in the same namespace via OLM,
	@# OLM copies CSVs and creates duplicate webhook configurations that
	@# point webhook paths to wrong services. For each operator, delete
	@# webhook configs owned by other operators' CSVs.
	@# SNR webhooks should only be owned by SNR CSV
	@for owner in $$($(KUBECTL) get csv -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | sort -u); do \
		if echo "$$owner" | grep -q 'self-node-remediation'; then continue; fi; \
		for wh in $$($(KUBECTL) get mutatingwebhookconfigurations -l olm.owner=$$owner -o name 2>/dev/null | grep selfnoderemediation); do \
			echo "  Deleting duplicate: $$wh (owner: $$owner)"; \
			$(KUBECTL) delete "$$wh" 2>/dev/null || true; \
		done; \
		for wh in $$($(KUBECTL) get validatingwebhookconfigurations -l olm.owner=$$owner -o name 2>/dev/null | grep selfnoderemediation); do \
			echo "  Deleting duplicate: $$wh (owner: $$owner)"; \
			$(KUBECTL) delete "$$wh" 2>/dev/null || true; \
		done; \
	done
	@# NHC webhooks should only be owned by NHC CSV
	@for owner in $$($(KUBECTL) get csv -A --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | sort -u); do \
		if echo "$$owner" | grep -q 'node-healthcheck'; then continue; fi; \
		for wh in $$($(KUBECTL) get mutatingwebhookconfigurations -l olm.owner=$$owner -o name 2>/dev/null | grep nodehealthcheck); do \
			echo "  Deleting duplicate: $$wh (owner: $$owner)"; \
			$(KUBECTL) delete "$$wh" 2>/dev/null || true; \
		done; \
		for wh in $$($(KUBECTL) get validatingwebhookconfigurations -l olm.owner=$$owner -o name 2>/dev/null | grep nodehealthcheck); do \
			echo "  Deleting duplicate: $$wh (owner: $$owner)"; \
			$(KUBECTL) delete "$$wh" 2>/dev/null || true; \
		done; \
	done

.PHONY: dev-events
dev-events: ## Show recent events related to medik8s resources
	@echo "=== Recent Events (last 10 minutes) ==="
	@$(KUBECTL) get events -A --sort-by=.lastTimestamp --field-selector reason!=Pulling,reason!=Pulled 2>/dev/null | \
		grep -iE 'remediat|healthcheck|maintenance|fence|unhealthy|notready|taint' || \
		echo "  No remediation-related events found."
	@echo ""
	@echo "=== All Recent Events ==="
	@$(KUBECTL) get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -20

.PHONY: dev-summary
dev-summary: ## Show remediation flow timeline (what happened during simulate/recover)
	@$(DEV_DIR)/summary.sh

.PHONY: dev-describe
dev-describe: ## Full summary of all medik8s resources (nodes, pods, CRs, leases, events)
	@$(DEV_DIR)/describe.sh

.PHONY: dev-shell
dev-shell: ## Open a shell on a Kind node (use NODE=<name>, default: first worker)
	@NODES=$$(KIND_EXPERIMENTAL_PROVIDER=$(CONTAINER_TOOL) kind get nodes --name $(MEDIK8S_CLUSTER_NAME) 2>/dev/null); \
	if [ -z "$$NODES" ]; then \
		NODES=$$($(KUBECTL) get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); \
	fi; \
	if [ -z "$$NODES" ]; then \
		echo "No nodes found. Is the cluster running?"; \
		exit 1; \
	fi; \
	TARGET="$(NODE)"; \
	if [ -z "$$TARGET" ]; then \
		TARGET=$$(echo "$$NODES" | grep worker | head -1); \
	fi; \
	if [ -z "$$TARGET" ]; then \
		TARGET=$$(echo "$$NODES" | head -1); \
	fi; \
	if ! echo "$$NODES" | grep -qx "$$TARGET"; then \
		echo "Error: '$$TARGET' is not a node in the cluster. Available: $$(echo $$NODES | tr '\n' ' ')"; \
		exit 1; \
	fi; \
	echo "Opening shell on $$TARGET..."; \
	echo "  (type 'exit' to return)"; \
	$(CONTAINER_TOOL) exec -it "$$TARGET" bash

.PHONY: dev-create-nhc
dev-create-nhc: ## Create a NodeHealthCheck CR that triggers SNR remediation
	@$(DEV_DIR)/create-nhc.sh

.PHONY: dev-reboot-watcher
dev-reboot-watcher: ## Start background watcher that simulates node reboot on Kind (restarts container when kubelet stops)
	@$(DEV_DIR)/kind-reboot-watcher.sh &
	@echo "Reboot watcher started in background (PID $$!)."
	@echo "  It will restart Kind node containers when kubelet stops."
	@echo "  Use 'kill $$!' or 'make dev-reboot-watcher-stop' to stop."

.PHONY: dev-reboot-watcher-stop
dev-reboot-watcher-stop: ## Stop the background Kind reboot watcher
	@pkill -f 'kind-reboot-watcher.sh' 2>/dev/null && echo "Reboot watcher stopped." || echo "No reboot watcher running."

.PHONY: dev-simulate-failure
dev-simulate-failure: ## Stop kubelet on a worker to trigger remediation (use SCENARIO= for other scenarios)
	@$(DEV_DIR)/simulate-failure.sh $(or $(SCENARIO),kubelet-stop)

.PHONY: dev-simulate-storm
dev-simulate-storm: ## Simulate storm: stop kubelet on 2 workers (requires 3 workers, the default)
	@$(DEV_DIR)/simulate-failure.sh storm

.PHONY: dev-simulate-network
dev-simulate-network: ## Block API server from a worker to test SNR peer health
	@$(DEV_DIR)/simulate-failure.sh network-partition

.PHONY: dev-recover
dev-recover: ## Recover all workers (restart kubelet, restore network, clean CRs)
	@$(DEV_DIR)/simulate-failure.sh recover

.PHONY: dev-ci-debug
dev-ci-debug: ## Print debug info for CI failures (OLM status, deployments, pods, logs, events)
	@echo "=== OLM Status ==="
	@$(KUBECTL) get -A OperatorGroup -o wide 2>/dev/null || true
	@$(KUBECTL) get -A CatalogSource -o wide 2>/dev/null || true
	@$(KUBECTL) get -A Subscription -o wide 2>/dev/null || true
	@$(KUBECTL) get -A ClusterServiceVersion -o wide 2>/dev/null || true
	@$(KUBECTL) get -A InstallPlan -o wide 2>/dev/null || true
	@echo ""
	@echo "=== Deployments and Pods ==="
	@for ns in $$($(KUBECTL) get namespaces --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -vE '^(kube-|default|local-path)'); do \
		RESOURCES=$$($(KUBECTL) get deployments,daemonsets,pods -n $$ns --no-headers 2>/dev/null); \
		if [ -n "$$RESOURCES" ]; then \
			echo "--- Namespace: $$ns ---"; \
			$(KUBECTL) get deployments,daemonsets,pods -n $$ns -o wide 2>/dev/null; \
			echo ""; \
		fi; \
	done
	@echo "=== Controller Logs ==="
	@for label in control-plane=controller-manager app.kubernetes.io/component=controller-manager; do \
		for ns in $$($(KUBECTL) get pods -A -l $$label --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | sort -u); do \
			for pod in $$($(KUBECTL) get pods -n $$ns -l $$label --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do \
				echo "--- $$ns/$$pod ---"; \
				$(KUBECTL) logs -n $$ns $$pod --all-containers --tail=200 2>/dev/null || true; \
				echo ""; \
			done; \
		done; \
	done
	@echo "=== Recent Events ==="
	@$(KUBECTL) get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -30

.PHONY: dev-help
dev-help: ## Show dev environment help
	@echo "Medik8s Development Environment"
	@echo ""
	@echo "Lifecycle:"
	@echo "  make dev-setup              Create Kind cluster (1 CP + 3 workers) + local registry"
	@echo "  make dev-teardown           Destroy cluster"
	@echo ""
	@echo "Build & Deploy:"
	@echo "  make dev-build              Build image and push to local registry"
	@echo "  make dev-deploy             Build + install CRDs + deploy operator"
	@echo "  make dev-redeploy           Rebuild and restart (fast iteration)"
	@echo "  make dev-undeploy           Remove operator from cluster"
	@echo "  make dev-bundle-run         Deploy via OLM bundle (requires operator-sdk)"
	@echo "  make dev-bundle-cleanup     Remove OLM bundle deployment"
	@echo "  make dev-create-nhc         Create NodeHealthCheck CR (auto-detects remediator)"
	@echo ""
	@echo "Observe:"
	@echo "  make dev-cluster-info       Show cluster version, connection, and nodes"
	@echo "  make dev-logs               Tail operator logs"
	@echo "  make dev-describe           Full summary (nodes, pods, CRs, leases, events)"
	@echo "  make dev-summary            Remediation flow timeline"
	@echo "  make dev-events             Show recent remediation-related events"
	@echo "  make dev-wait               Wait for all operator pods to be ready"
	@echo "  make dev-shell              Open shell on a Kind node (NODE=<name>)"
	@echo ""
	@echo "Simulate Failures:"
	@echo "  make dev-simulate-failure   Stop kubelet on a worker"
	@echo "  make dev-simulate-storm     Stop kubelet on 2 workers (storm test)"
	@echo "  make dev-simulate-network   Block API server from a worker"
	@echo "  make dev-recover            Recover all workers"
	@echo "  make dev-reboot-watcher     Start background watcher (simulates reboot on Kind)"
	@echo "  make dev-reboot-watcher-stop  Stop the reboot watcher"
	@echo ""
	@echo "CI:"
	@echo "  make dev-ci-debug           Print debug info for CI failures"
	@echo ""
	@echo "Configuration (environment variables):"
	@echo "  DEV_REGISTRY=registry       Push to local Kind registry (default for Kind)"
	@echo "  DEV_REGISTRY=local          Load directly into Kind nodes (no OLM bundle support)"
	@echo "  DEV_REGISTRY=ttl.sh         Push to ttl.sh (default for external clusters)"
	@echo "  SKIP_KIND=true              Use existing cluster instead of creating Kind"
	@echo "  KIND_BLOCK_STORAGE=true     Share a disposable raw block device across 2 workers (Linux/Docker or Podman)"
	@echo "  KIND_BLOCK_STATE_DIR=/path  Block state and isolated kubeconfig (use same path for teardown)"
	@echo "  SKIP_REGISTRY=true          Skip local registry creation in dev-setup"
	@echo "  KIND_HA=true                HA config (3 CP + 3 workers)"
	@echo "  MEDIK8S_CLUSTER_NAME=name   Kind cluster name (default: medik8s-dev)"
	@echo "  MEDIK8S_REGISTRY_NAME=name  Registry container name (default: kind-registry)"
	@echo "  MEDIK8S_REGISTRY_PORT=port  Registry port (default: 5000)"
	@echo "  TTL_SH_TTL=2h              Image expiry on ttl.sh (default: 2h)"
