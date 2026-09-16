# base.mk — Shared CI targets for Medik8s operators
#
# Provides standardized build, test, deployment, bundle, catalog, and tool
# installation targets for consistent Prow CI behavior across all operators.
#
# Usage:
#   Set required variables, then include this file:
#
#     OPERATOR_NAME ?= node-healthcheck-operator
#     -include $(TOOLS_DIR)/build/base.mk
#
# Configuration:
#   OPERATOR_NAME           Required. e.g. "fence-agents-remediation"
#   OPERATOR_NAMESPACE      Namespace for bundle-run (default: openshift-workload-availability)
#   VERSION                 Operator version (default: 0.0.1)
#   IMG                     Container image (default: $(IMAGE_TAG_BASE)-operator:$(IMAGE_TAG))
#   BUNDLE_IMG              Bundle image (default: $(IMAGE_TAG_BASE)-operator-bundle:$(IMAGE_TAG))
#   CATALOG_IMG             Catalog image (default: $(IMAGE_TAG_BASE)-operator-catalog:$(IMAGE_TAG))
#   IMAGE_REGISTRY          Registry/group (default: quay.io/medik8s)
#   CHANNELS                Bundle channels (default: stable)
#   DEFAULT_CHANNEL         Default bundle channel (default: stable)
#   BASE_AGENT_PATHS        Space-separated agent cmd paths (default: empty)
#   BASE_BUILD_SCRIPT       Custom build script (default: hack/build.sh if exists, else go build)
#   BASE_TEST_PATHS         Paths to test (default: auto-detect, excluding /e2e and /test)
#   BASE_FMT_PATHS          Paths to fmt (default: ./...)
#   BLUE_ICON_PATH          Path to operator icon (default: ./config/assets/medik8s_blue_icon.png)

ifndef OPERATOR_NAME
$(error OPERATOR_NAME must be set before including base.mk)
endif

# ──────────────────────────────────────────────────────────────────────────────
# Tool versions — pinned centrally to prevent cross-repo drift
# ──────────────────────────────────────────────────────────────────────────────

KUSTOMIZE_VERSION      ?= v5@v5.8.1
CONTROLLER_GEN_VERSION ?= v0.21.0
ENVTEST_VERSION        ?= v0.24.1
GINKGO_VERSION         ?= v2.32.1
GOIMPORTS_VERSION      ?= v0.49.0
SORT_IMPORTS_VERSION   ?= v0.3.0
OPM_VERSION            ?= v1.73.0
OPERATOR_SDK_VERSION   ?= v1.42.3
ENVTEST_K8S_VERSION    ?= 1.36
YQ_API_VERSION         ?= v4
YQ_VERSION             ?= v4.53.3

# ──────────────────────────────────────────────────────────────────────────────
# Image / version configuration
# ──────────────────────────────────────────────────────────────────────────────

IMAGE_REGISTRY  ?= quay.io/medik8s
export IMAGE_REGISTRY

DEFAULT_VERSION := 0.0.1
VERSION         ?= $(DEFAULT_VERSION)
PREVIOUS_VERSION ?= $(DEFAULT_VERSION)
SKIP_RANGE_LOWER ?=
export VERSION

ifeq ($(VERSION), $(DEFAULT_VERSION))
  IMAGE_TAG = latest
else
  IMAGE_TAG = v$(VERSION)
endif
export IMAGE_TAG

CHANNELS        ?= stable
DEFAULT_CHANNEL ?= stable
export CHANNELS DEFAULT_CHANNEL

comma := ,
ifneq (,$(DEFAULT_CHANNEL))
  ifeq (,$(filter $(DEFAULT_CHANNEL),$(subst $(comma), ,$(CHANNELS))))
    $(error DEFAULT_CHANNEL "$(DEFAULT_CHANNEL)" must be present in CHANNELS "$(CHANNELS)")
  endif
endif

ifneq ($(origin CHANNELS), undefined)
  BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif
ifneq ($(origin DEFAULT_CHANNEL), undefined)
  BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

OPERATOR_NAMESPACE ?= openshift-workload-availability
IMAGE_TAG_BASE     ?= $(IMAGE_REGISTRY)/$(OPERATOR_NAME)
BUNDLE_IMG         ?= $(IMAGE_TAG_BASE)-operator-bundle:$(IMAGE_TAG)
CATALOG_IMG        ?= $(IMAGE_TAG_BASE)-operator-catalog:$(IMAGE_TAG)
IMG                ?= $(IMAGE_TAG_BASE)-operator:$(IMAGE_TAG)
BUNDLE_GEN_FLAGS   ?= -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)

USE_IMAGE_DIGESTS ?= false
ifeq ($(USE_IMAGE_DIGESTS), true)
  BUNDLE_GEN_FLAGS += --use-image-digests
endif

BLUE_ICON_PATH ?= ./config/assets/medik8s_blue_icon.png

REPEAT_TIMES ?= 1

# ──────────────────────────────────────────────────────────────────────────────
# Build helpers
# ──────────────────────────────────────────────────────────────────────────────

ifeq (,$(shell go env GOBIN))
  GOBIN=$(shell go env GOPATH)/bin
else
  GOBIN=$(shell go env GOBIN)
endif

KUBECTL = kubectl
ifeq (,$(shell which kubectl 2>/dev/null))
  KUBECTL = oc
endif

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# Container tool
BASE_CONTAINER_TOOL ?= $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null || echo docker)

# Auto-detect main.go location
ifeq ($(BASE_MAIN_PATH),)
  ifneq ($(wildcard cmd/main.go),)
    BASE_MAIN_PATH := cmd/main.go
  else
    BASE_MAIN_PATH := main.go
  endif
endif

# Auto-detect build script
ifeq ($(BASE_BUILD_SCRIPT),)
  ifneq ($(wildcard hack/build.sh),)
    BASE_BUILD_SCRIPT := ./hack/build.sh
  endif
endif

# Default fmt paths (override per-operator if needed)
BASE_FMT_PATHS ?= .

ifndef ignore-not-found
  ignore-not-found = false
endif

export CSV ?= ./bundle/manifests/$(OPERATOR_NAME).clusterserviceversion.yaml
DEFAULT_ICON_BASE64 := $(shell [ -f $(BLUE_ICON_PATH) ] && base64 --wrap=0 $(BLUE_ICON_PATH) 2>/dev/null || echo "")
export ICON_BASE64 ?= $(DEFAULT_ICON_BASE64)

OCP_VERSION ?= 4.23

.PHONY: all
all: build

# ──────────────────────────────────────────────────────────────────────────────
# Local bin directory & tool paths
# ──────────────────────────────────────────────────────────────────────────────

LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

KUSTOMIZE_DIR      ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN_DIR ?= $(LOCALBIN)/controller-gen
ENVTEST_DIR        ?= $(LOCALBIN)/setup-envtest
GINKGO_DIR         ?= $(LOCALBIN)/ginkgo
GOIMPORTS_DIR      ?= $(LOCALBIN)/goimports
SORT_IMPORTS_DIR   ?= $(LOCALBIN)/sort-imports
OPM_DIR            ?= $(LOCALBIN)/opm
OPERATOR_SDK_DIR   ?= $(LOCALBIN)/operator-sdk
YQ_DIR             ?= $(LOCALBIN)/yq

KUSTOMIZE    = $(KUSTOMIZE_DIR)/$(KUSTOMIZE_VERSION)/kustomize
CONTROLLER_GEN = $(CONTROLLER_GEN_DIR)/$(CONTROLLER_GEN_VERSION)/controller-gen
ENVTEST      = $(ENVTEST_DIR)/$(ENVTEST_VERSION)/setup-envtest
GINKGO       = $(GINKGO_DIR)/$(GINKGO_VERSION)/ginkgo
GOIMPORTS    = $(GOIMPORTS_DIR)/$(GOIMPORTS_VERSION)/goimports
SORT_IMPORTS = $(SORT_IMPORTS_DIR)/$(SORT_IMPORTS_VERSION)/sort-imports
OPM          = $(OPM_DIR)/$(OPM_VERSION)/opm
OPERATOR_SDK = $(OPERATOR_SDK_DIR)/$(OPERATOR_SDK_VERSION)/operator-sdk
YQ           = $(YQ_DIR)/$(YQ_API_VERSION)-$(YQ_VERSION)/yq

# ──────────────────────────────────────────────────────────────────────────────
# go-install-tool / url-install-tool macros
# ──────────────────────────────────────────────────────────────────────────────

define go-install-tool
@[ -f $(1) ] || { \
	set -e; \
	rm -rf $(2); \
	TMP_DIR=$$(mktemp -d); \
	cd $$TMP_DIR; \
	go mod init tmp; \
	BIN_DIR=$$(dirname $(1)); \
	mkdir -p $$BIN_DIR; \
	echo "Downloading $(3)"; \
	GOBIN=$$BIN_DIR GOFLAGS='' go install $(3); \
	rm -rf $$TMP_DIR; \
}
endef

define url-install-tool
@[ -f $(1) ] || { \
	set -e; \
	rm -rf $(2); \
	mkdir -p $(dir $(1)); \
	OS=$(shell go env GOOS) && ARCH=$(shell go env GOARCH) && \
	curl -sSLo $(1) $(3); \
	chmod +x $(1); \
}
endef

# ══════════════════════════════════════════════════════════════════════════════
##@ Development
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate DeepCopy, DeepCopyInto, and DeepCopyObject implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: goimports ## Run goimports (superset of go fmt).
	$(GOIMPORTS) -w $(BASE_FMT_PATHS)

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: go-tidy
go-tidy: ## Run go mod tidy.
	go mod tidy

.PHONY: go-vendor
go-vendor: ## Run go mod vendor.
	go mod vendor

.PHONY: go-verify
go-verify: go-tidy go-vendor ## Tidy, vendor, then verify module checksums.
	go mod verify

.PHONY: test-imports
test-imports: sort-imports ## Check import ordering (non-destructive).
	$(SORT_IMPORTS) .

.PHONY: fix-imports
fix-imports: sort-imports ## Fix import ordering.
	$(SORT_IMPORTS) -w .

.PHONY: verify-unchanged
verify-unchanged: ## Verify no un-committed changes.
	./hack/verify-unchanged.sh

# ══════════════════════════════════════════════════════════════════════════════
##@ Test
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: test
test: test-no-verify ## Run tests then verify no uncommitted changes.
	$(MAKE) bundle-reset verify-unchanged

.PHONY: test-no-verify
test-no-verify: go-verify manifests generate fmt vet fix-imports envtest ginkgo ## Run tests without verification.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(ENVTEST_DIR)/$(ENVTEST_VERSION) -p path)" \
	$(GINKGO) -r --keep-going --randomize-all --require-suite --vv --coverprofile cover.out --repeat=$(REPEAT_TIMES) \
	$$(go list ./... | grep -Ev '/e2e|/test')

# ══════════════════════════════════════════════════════════════════════════════
##@ Build
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: build
build: ## Build manager binary.
ifdef BASE_BUILD_SCRIPT
	$(BASE_BUILD_SCRIPT)
else
	go build -o bin/manager $(BASE_MAIN_PATH)
endif
ifneq ($(BASE_AGENT_PATHS),)
	@for agent_path in $(BASE_AGENT_PATHS); do \
		agent_name=$$(basename $$agent_path); \
		echo "Building $$agent_name..."; \
		go build -o bin/$$agent_name $$agent_path; \
	done
endif

.PHONY: run
run: manifests generate fmt vet ## Run controller from your host.
	go run ./$(BASE_MAIN_PATH)

.PHONY: docker-build
docker-build: test-no-verify ## Build container image.
	$(BASE_CONTAINER_TOOL) build -t $(IMG) .

.PHONY: docker-push
docker-push: ## Push container image.
	$(BASE_CONTAINER_TOOL) push $(IMG)

# ══════════════════════════════════════════════════════════════════════════════
##@ Deployment
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: install
install: manifests kustomize ## Install CRDs into cluster.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) apply -f -

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from cluster.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to cluster.
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from cluster.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: create-ns
create-ns: ## Create operator namespace.
	$(KUBECTL) get ns $(OPERATOR_NAMESPACE) 2>&1>/dev/null || $(KUBECTL) create ns $(OPERATOR_NAMESPACE)

# ══════════════════════════════════════════════════════════════════════════════
##@ Bundle
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: bundle
bundle: manifests operator-sdk kustomize ## Generate bundle manifests and metadata.
	$(OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle $(BUNDLE_GEN_FLAGS)
	$(MAKE) bundle-reset-date bundle-validate

.PHONY: bundle-validate
bundle-validate: operator-sdk ## Validate bundle directory.
	$(OPERATOR_SDK) bundle validate ./bundle --select-optional suite=operatorframework

.PHONY: bundle-build
bundle-build: bundle bundle-update ## Build bundle image.
	$(BASE_CONTAINER_TOOL) build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: bundle-run
bundle-run: operator-sdk create-ns ## Deploy operator via OLM bundle.
	$(OPERATOR_SDK) -n $(OPERATOR_NAMESPACE) run bundle $(BUNDLE_IMG)

.PHONY: bundle-run-update
bundle-run-update: operator-sdk ## Upgrade operator via OLM bundle.
	$(OPERATOR_SDK) -n $(OPERATOR_NAMESPACE) run bundle-upgrade $(BUNDLE_IMG)

.PHONY: bundle-cleanup
bundle-cleanup: operator-sdk ## Remove operator installed via bundle-run.
	$(OPERATOR_SDK) -n $(OPERATOR_NAMESPACE) cleanup $(OPERATOR_NAME)

.PHONY: bundle-update
bundle-update: ## Update CSV container image, creation date, and icon.
	sed -r -i "s|containerImage: .*|containerImage: $(IMG)|;" $(CSV)
	sed -r -i "s|createdAt: .*|createdAt: `date '+%Y-%m-%d %T'`|;" $(CSV)
	@if [ -n "$(ICON_BASE64)" ]; then \
		sed -r -i "s|base64data:.*|base64data: $(ICON_BASE64)|;" $(CSV); \
	fi
	$(MAKE) bundle-validate

.PHONY: bundle-reset
bundle-reset: ## Revert bundle to development version.
	VERSION=$(DEFAULT_VERSION) $(MAKE) manifests bundle

.PHONY: bundle-reset-date
bundle-reset-date: ## Reset bundle createdAt field.
	sed -r -i 's|createdAt: .*|createdAt: ""|;' $(CSV)

.PHONY: add-replaces-field
add-replaces-field: ## Add replaces field to CSV for versioned builds.
	@if [ $(VERSION) != $(DEFAULT_VERSION) ]; then \
		if [ $(PREVIOUS_VERSION) == $(DEFAULT_VERSION) ]; then \
			echo "Error: PREVIOUS_VERSION must be set for versioned builds"; \
			exit 1; \
		elif [ $$(./hack/semver_cmp.sh $(VERSION) $(PREVIOUS_VERSION)) != 1 ]; then \
			echo "Error: VERSION ($(VERSION)) must be greater than PREVIOUS_VERSION ($(PREVIOUS_VERSION))"; \
			exit 1; \
		else \
			sed -r -i "/  version: $(VERSION)/ a\  replaces: $(OPERATOR_NAME).v$(PREVIOUS_VERSION)" $(CSV); \
		fi \
	fi

.PHONY: add-ocp-annotations
add-ocp-annotations: yq ## Add OCP-specific annotations to CSV.
	$(YQ) -i '.metadata.annotations."operators.openshift.io/valid-subscription" = "[\"OpenShift Kubernetes Engine\", \"OpenShift Container Platform\", \"OpenShift Platform Plus\"]"' $(CSV)
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/disconnected" = "true"' $(CSV)
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/fips-compliant" = "false"' $(CSV)
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/proxy-aware" = "false"' $(CSV)
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/tls-profiles" = "true"' $(CSV)
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/token-auth-aws" = "false"' $(CSV)
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/token-auth-azure" = "false"' $(CSV)
	$(YQ) -i '.metadata.annotations."features.operators.openshift.io/token-auth-gcp" = "false"' $(CSV)

.PHONY: bundle-community
bundle-community: bundle ## Generate community bundle with updated display name.
	sed -r -i "s|displayName: .*Operator|displayName: $(OPERATOR_NAME) - Community Edition|;" $(CSV)
	$(MAKE) bundle-update

.PHONY: bundle-community-k8s
bundle-community-k8s: bundle-community ## Community bundle for K8s.

.PHONY: bundle-community-okd
bundle-community-okd: bundle-community ## Community bundle for OKD with OCP annotations.
	$(MAKE) add-replaces-field
	$(MAKE) add-ocp-annotations
	echo -e "\n  # Annotations for OCP\n  com.redhat.openshift.versions: \"v$(OCP_VERSION)\"" >> bundle/metadata/annotations.yaml

# ══════════════════════════════════════════════════════════════════════════════
##@ Catalog
# ══════════════════════════════════════════════════════════════════════════════

CATALOG_DIR        := catalog
CATALOG_DOCKERFILE := $(CATALOG_DIR).Dockerfile
CATALOG_INDEX      := $(CATALOG_DIR)/index.yaml

.PHONY: add_channel_entry_for_the_bundle
add_channel_entry_for_the_bundle:
	@for channel in $$(echo $(CHANNELS) | tr ',' ' '); do \
		echo "---" >> $(CATALOG_INDEX); \
		echo "schema: olm.channel" >> $(CATALOG_INDEX); \
		echo "package: $(OPERATOR_NAME)" >> $(CATALOG_INDEX); \
		echo "name: $$channel" >> $(CATALOG_INDEX); \
		echo "entries:" >> $(CATALOG_INDEX); \
		echo "  - name: $(OPERATOR_NAME).v$(VERSION)" >> $(CATALOG_INDEX); \
		if [ -n "$(PREVIOUS_VERSION)" ] && [ "$(VERSION)" != "$(DEFAULT_VERSION)" ] && [ "$(PREVIOUS_VERSION)" != "$(DEFAULT_VERSION)" ]; then \
			echo "    replaces: $(OPERATOR_NAME).v$(PREVIOUS_VERSION)" >> $(CATALOG_INDEX); \
		fi; \
		if [ -n "$(SKIP_RANGE_LOWER)" ] && [ "$(VERSION)" != "$(DEFAULT_VERSION)" ] && [ "$(VERSION)" != "$(SKIP_RANGE_LOWER)" ]; then \
			if ! printf '%s\n' "$(SKIP_RANGE_LOWER)" "$(VERSION)" | sort -V -C 2>/dev/null; then \
				echo "Error: VERSION ($(VERSION)) must be greater than SKIP_RANGE_LOWER ($(SKIP_RANGE_LOWER))"; \
				exit 1; \
			fi; \
			echo "    skipRange: '>=$(SKIP_RANGE_LOWER) <$(VERSION)'" >> $(CATALOG_INDEX); \
		fi; \
	done

.PHONY: catalog-build
catalog-build: opm ## Build file-based catalog image.
	-rm -r $(CATALOG_DIR) $(CATALOG_DOCKERFILE) 2>/dev/null
	@mkdir -p $(CATALOG_DIR)
	$(OPM) generate dockerfile $(CATALOG_DIR)
	$(OPM) init $(OPERATOR_NAME) \
		--default-channel=$(DEFAULT_CHANNEL) \
		--description=./README.md \
		--icon=$(BLUE_ICON_PATH) \
		--output yaml \
		> $(CATALOG_INDEX)
	$(OPM) render $(BUNDLE_IMG) --output yaml >> $(CATALOG_INDEX)
	$(MAKE) add_channel_entry_for_the_bundle
	$(OPM) validate $(CATALOG_DIR)
	$(BASE_CONTAINER_TOOL) build . -f $(CATALOG_DOCKERFILE) -t $(CATALOG_IMG)
	rm -r $(CATALOG_DIR) $(CATALOG_DOCKERFILE)

.PHONY: catalog-push
catalog-push: ## Push catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

# ══════════════════════════════════════════════════════════════════════════════
##@ CI Composite Targets
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: container-build
container-build: docker-build bundle-build ## Build operator and bundle images.

.PHONY: container-push
container-push: docker-push bundle-push catalog-build catalog-push ## Push all images (operator, bundle, catalog).

.PHONY: full-gen
full-gen: go-verify manifests generate fmt bundle fix-imports bundle-reset ## Regenerate all auto-generated content.

# ══════════════════════════════════════════════════════════════════════════════
##@ Tool Installation
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: kustomize
kustomize: ## Install kustomize.
	$(call go-install-tool,$(KUSTOMIZE),$(KUSTOMIZE_DIR),sigs.k8s.io/kustomize/kustomize/$(KUSTOMIZE_VERSION))

.PHONY: controller-gen
controller-gen: ## Install controller-gen.
	$(call go-install-tool,$(CONTROLLER_GEN),$(CONTROLLER_GEN_DIR),sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_GEN_VERSION))

.PHONY: envtest
envtest: ## Install setup-envtest.
ifneq ($(wildcard $(ENVTEST_DIR)),)
	chmod -R +w $(ENVTEST_DIR)
endif
	$(call go-install-tool,$(ENVTEST),$(ENVTEST_DIR),sigs.k8s.io/controller-runtime/tools/setup-envtest@$(ENVTEST_VERSION))

.PHONY: ginkgo
ginkgo: ## Install ginkgo test runner.
	$(call go-install-tool,$(GINKGO),$(GINKGO_DIR),github.com/onsi/ginkgo/v2/ginkgo@$(GINKGO_VERSION))

.PHONY: goimports
goimports: ## Install goimports.
	$(call go-install-tool,$(GOIMPORTS),$(GOIMPORTS_DIR),golang.org/x/tools/cmd/goimports@$(GOIMPORTS_VERSION))

.PHONY: sort-imports
sort-imports: ## Install sort-imports.
	$(call go-install-tool,$(SORT_IMPORTS),$(SORT_IMPORTS_DIR),github.com/slintes/sort-imports@$(SORT_IMPORTS_VERSION))

.PHONY: operator-sdk
operator-sdk: ## Install operator-sdk.
	$(call url-install-tool,$(OPERATOR_SDK),$(OPERATOR_SDK_DIR),github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$${OS}_$${ARCH})

.PHONY: opm
opm: ## Install opm.
	$(call url-install-tool,$(OPM),$(OPM_DIR),github.com/operator-framework/operator-registry/releases/download/$(OPM_VERSION)/$${OS}-$${ARCH}-opm)

.PHONY: yq
yq: ## Install yq.
	$(call go-install-tool,$(YQ),$(YQ_DIR),github.com/mikefarah/yq/$(YQ_API_VERSION)@$(YQ_VERSION))

.PHONY: build-tools
build-tools: kustomize controller-gen envtest ginkgo goimports sort-imports opm operator-sdk yq ## Install all tools.

# ══════════════════════════════════════════════════════════════════════════════
##@ Help
# ══════════════════════════════════════════════════════════════════════════════

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
