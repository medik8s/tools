# base.mk
#
# Shared CI targets for Medik8s operators
#
# Provides standardized build, test, and docker-build targets for consistent
# Prow CI behavior across all operators.
#
# Usage:
#   Include this file in your operator's Makefile and set required variables:
#
#   BASE_OPERATOR_NAME ?= node-healthcheck-operator
#   -include $(TOOLS_DIR)/build/base.mk
#
# Available targets:
#   make build           Build operator binary
#   make test            Run unit tests with verification
#   make docker-build    Build container image
#   make deploy          Deploy operator to cluster
#   make undeploy        Remove operator from cluster
#
# Configuration variables:
#   BASE_OPERATOR_NAME    Operator name (required, e.g., "node-healthcheck-operator")
#   BASE_MAIN_PATH        Path to main.go (default: main.go, or cmd/main.go if exists)
#   BASE_AGENT_PATHS      Space-separated agent paths (default: empty, e.g., "cmd/sbr-agent")
#   IMG                   Container image name (default: ttl.sh/BASE_OPERATOR_NAME:1h)
#   VERSION               Operator version (default: 0.0.1)
#   PLATFORMS             Build platforms (default: linux/amd64)
#

# Verify BASE_OPERATOR_NAME is set
ifndef BASE_OPERATOR_NAME
$(error BASE_OPERATOR_NAME must be set before including base.mk. Example: BASE_OPERATOR_NAME ?= node-healthcheck-operator)
endif

# Build configuration
BASE_GOOS   ?= $(shell go env GOOS)
BASE_GOARCH ?= $(shell go env GOARCH)
BASE_PLATFORMS ?= linux/amd64,linux/arm64

# Auto-detect main.go location
ifeq ($(BASE_MAIN_PATH),)
  ifneq ($(wildcard cmd/main.go),)
    BASE_MAIN_PATH := cmd/main.go
  else
    BASE_MAIN_PATH := main.go
  endif
endif

# Image configuration
IMG ?= ttl.sh/$(BASE_OPERATOR_NAME):1h
VERSION ?= 0.0.1

# Container tool (docker or podman)
BASE_CONTAINER_TOOL ?= $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null || echo docker)

# Kustomize configuration
BASE_KUSTOMIZE_VERSION ?= v5.8.1
BASE_KUSTOMIZE ?= $(LOCALBIN)/kustomize-base
BASE_ENVTEST_VERSION ?= release-0.19
BASE_CONTROLLER_GEN_VERSION ?= v0.17.0

# Local bin directory
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

##@ Build

.PHONY: build
build: generate fmt vet ## Build manager binary.
	@echo "Building $(BASE_OPERATOR_NAME) manager..."
	@go build -o bin/manager $(BASE_MAIN_PATH)
ifneq ($(BASE_AGENT_PATHS),)
	@for agent_path in $(BASE_AGENT_PATHS); do \
		agent_name=$$(basename $$agent_path); \
		echo "Building $$agent_name..."; \
		go build -o bin/$$agent_name $$agent_path; \
	done
endif

.PHONY: test
test: generate fmt vet envtest ## Run unit tests with code generation and verification.
	KUBEBUILDER_ASSETS="$(shell $(BASE_ENVTEST) use $(BASE_ENVTEST_VERSION) --bin-dir $(LOCALBIN) -p path)" go test $$(go list ./... | grep -v /e2e) -coverprofile cover.out

.PHONY: test-no-verify
test-no-verify: envtest ## Run unit tests without verification (for CI).
	KUBEBUILDER_ASSETS="$(shell $(BASE_ENVTEST) use $(BASE_ENVTEST_VERSION) --bin-dir $(LOCALBIN) -p path)" go test $$(go list ./... | grep -v /e2e) -coverprofile cover.out

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(BASE_CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(BASE_CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: fix-imports
fix-imports: ## Fix import order
	@command -v goimports >/dev/null 2>&1 || go install golang.org/x/tools/cmd/goimports@latest
	goimports -w -local github.com/medik8s .

##@ Container

.PHONY: docker-build
docker-build: ## Build docker image.
	$(BASE_CONTAINER_TOOL) build --platform=$(BASE_PLATFORMS) -t $(IMG) .

.PHONY: docker-push
docker-push: ## Push docker image.
	$(BASE_CONTAINER_TOOL) push $(IMG)

.PHONY: docker-buildx
docker-buildx: ## Build and push multi-platform docker image.
	docker buildx create --name $(BASE_OPERATOR_NAME)-builder --use || true
	docker buildx build --platform=$(BASE_PLATFORMS) --push -t $(IMG) .

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(BASE_KUSTOMIZE) edit set image controller=$(IMG)
	$(BASE_KUSTOMIZE) build config/default | kubectl apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	$(BASE_KUSTOMIZE) build config/default | kubectl delete --ignore-not-found=$(ignore-not-found) -f -

##@ Tools

.PHONY: kustomize
kustomize: $(BASE_KUSTOMIZE) ## Install kustomize locally if necessary.
$(BASE_KUSTOMIZE): $(LOCALBIN)
	@if [ ! -f $(BASE_KUSTOMIZE) ] || [ "$$($(BASE_KUSTOMIZE) version 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+')" != "$(BASE_KUSTOMIZE_VERSION)" ]; then \
		echo "Installing kustomize $(BASE_KUSTOMIZE_VERSION)..."; \
		GOBIN=$(LOCALBIN) go install sigs.k8s.io/kustomize/kustomize/v5@$(if $(filter v%,$(BASE_KUSTOMIZE_VERSION)),$(BASE_KUSTOMIZE_VERSION),v$(BASE_KUSTOMIZE_VERSION)); \
		mv $(LOCALBIN)/kustomize $(BASE_KUSTOMIZE); \
	fi

.PHONY: controller-gen
controller-gen: $(BASE_CONTROLLER_GEN) ## Install controller-gen locally if necessary.
$(BASE_CONTROLLER_GEN): $(LOCALBIN)
	@if [ ! -f $(BASE_CONTROLLER_GEN) ] || [ "$$($(BASE_CONTROLLER_GEN) --version 2>/dev/null | awk '{print $$2}')" != "$(BASE_CONTROLLER_GEN_VERSION)" ]; then \
		echo "Installing controller-gen $(BASE_CONTROLLER_GEN_VERSION)..."; \
		GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(BASE_CONTROLLER_GEN_VERSION); \
		mv $(LOCALBIN)/controller-gen $(BASE_CONTROLLER_GEN); \
	fi

.PHONY: envtest
envtest: $(BASE_ENVTEST) ## Install setup-envtest locally if necessary.
$(BASE_ENVTEST): $(LOCALBIN)
	@if [ ! -f $(BASE_ENVTEST) ]; then \
		echo "Installing setup-envtest..."; \
		GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest; \
		mv $(LOCALBIN)/setup-envtest $(BASE_ENVTEST); \
	fi

# Tool variables for make targets
BASE_CONTROLLER_GEN = $(LOCALBIN)/controller-gen-base
BASE_ENVTEST = $(LOCALBIN)/setup-envtest-base

##@ Help

.PHONY: base-help
base-help: ## Show base.mk targets and configuration.
	@echo "Base CI Targets (from medik8s/tools/build/base.mk):"
	@echo "  make build           Build operator binary"
	@echo "  make test            Run unit tests with verification"
	@echo "  make test-no-verify  Run unit tests without verification"
	@echo "  make docker-build    Build container image"
	@echo "  make docker-push     Push container image"
	@echo "  make deploy          Deploy operator to cluster"
	@echo "  make undeploy        Remove operator from cluster"
	@echo ""
	@echo "Configuration:"
	@echo "  BASE_OPERATOR_NAME   $(BASE_OPERATOR_NAME)"
	@echo "  BASE_MAIN_PATH       $(BASE_MAIN_PATH)"
	@echo "  BASE_AGENT_PATHS     $(if $(BASE_AGENT_PATHS),$(BASE_AGENT_PATHS),(none))"
	@echo "  IMG                  $(IMG)"
	@echo "  VERSION              $(VERSION)"
	@echo "  PLATFORMS            $(BASE_PLATFORMS)"
