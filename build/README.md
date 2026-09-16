# Medik8s CI Build Targets

Shared build, test, deployment, bundle, catalog, and tool installation targets for consistent Prow CI across all Medik8s operators.

## Quick Start

Add to end of operator Makefile:

```makefile
# Shared CI targets from medik8s/tools
OPERATOR_NAME ?= node-healthcheck-operator
TOOLS_DIR ?= $(shell cd .. && pwd)/tools
BASE_MK := $(TOOLS_DIR)/build/base.mk
ifeq ($(wildcard $(BASE_MK)),)
  TOOLS_DIR := $(shell pwd)/.tools
  BASE_MK := $(TOOLS_DIR)/build/base.mk
endif
-include $(BASE_MK)
ifeq ($(wildcard $(BASE_MK)),)
build test docker-build deploy undeploy:
	@echo "Downloading medik8s/tools into $(TOOLS_DIR)..."
	@if [ -d $(TOOLS_DIR) ]; then \
		if [ -f $(TOOLS_DIR)/.managed-by-makefile ]; then \
			echo "  Removing stale $(TOOLS_DIR)..."; rm -rf $(TOOLS_DIR); \
		else \
			echo "Error: $(TOOLS_DIR) exists but was not created by this Makefile."; exit 1; \
		fi; \
	fi
	@git clone --depth 1 https://github.com/medik8s/tools.git $(TOOLS_DIR)
	@touch $(TOOLS_DIR)/.managed-by-makefile
	@test -f $(BASE_MK) || { echo "Error: $(BASE_MK) not found after clone."; exit 1; }
	@$(MAKE) $@
endif
```

## Available Targets

### Development

```bash
make manifests        # Generate CRDs, RBAC, webhook manifests
make generate         # Generate DeepCopy implementations
make fmt              # Format code with goimports
make vet              # Run go vet
make fix-imports      # Fix import ordering
make test-imports     # Check import ordering (non-destructive)
make go-tidy          # Run go mod tidy
make go-vendor        # Run go mod vendor
make go-verify        # Tidy + vendor + verify checksums
make verify-unchanged # Verify no uncommitted changes
```

### Build

```bash
make build            # Build manager binary (+ agents if configured)
make run              # Run controller locally
make docker-build     # Build container image (runs tests first)
make docker-push      # Push container image
```

### Test

```bash
make test             # Run tests with verification (CI target)
make test-no-verify   # Run tests without post-verification
```

### Deployment

```bash
make install          # Install CRDs into cluster
make uninstall        # Uninstall CRDs from cluster
make deploy           # Deploy controller to cluster via kustomize
make undeploy         # Remove controller from cluster
make create-ns        # Create operator namespace
```

### Bundle / OLM

```bash
make bundle           # Generate bundle manifests and metadata
make bundle-build     # Build bundle image
make bundle-push      # Push bundle image
make bundle-validate  # Validate bundle directory
make bundle-run       # Deploy operator via OLM bundle
make bundle-run-update # Upgrade operator via OLM bundle
make bundle-cleanup   # Remove operator installed via bundle-run
make bundle-update    # Update CSV image, date, and icon
make bundle-reset     # Revert bundle to development version
make bundle-reset-date # Reset bundle createdAt field
make add-replaces-field # Add replaces field for versioned builds
make add-ocp-annotations # Add OCP-specific annotations to CSV
make bundle-community # Generate community bundle
make bundle-community-k8s  # Community bundle for K8s
make bundle-community-okd  # Community bundle for OKD
```

### Catalog

```bash
make catalog-build    # Build file-based catalog image
make catalog-push     # Push catalog image
```

### CI Composite Targets

```bash
make container-build  # Build operator + bundle images
make container-push   # Push all images (operator, bundle, catalog)
make full-gen         # Regenerate all auto-generated content
```

### Tool Installation

```bash
make kustomize        # Install kustomize
make controller-gen   # Install controller-gen
make envtest          # Install setup-envtest
make ginkgo           # Install ginkgo
make goimports        # Install goimports
make sort-imports     # Install sort-imports
make operator-sdk     # Install operator-sdk
make opm              # Install opm
make yq               # Install yq
make build-tools      # Install all tools
```

## Configuration

### Required Variables

```makefile
OPERATOR_NAME ?= node-healthcheck-operator
```

### Optional Variables

```makefile
# Main binary location (auto-detected from cmd/main.go or main.go)
BASE_MAIN_PATH ?= cmd/main.go

# Agent binaries (for operators like SBR/FAR)
BASE_AGENT_PATHS ?= cmd/fence-agent cmd/sbr-agent

# Custom build script (auto-detected from hack/build.sh)
BASE_BUILD_SCRIPT ?= ./hack/build.sh

# Container image
IMG ?= quay.io/medik8s/my-operator:latest

# Version
VERSION ?= 0.0.1

# Bundle and catalog images
BUNDLE_IMG ?= quay.io/medik8s/my-operator-bundle:latest
CATALOG_IMG ?= quay.io/medik8s/my-operator-catalog:latest

# Channels
CHANNELS ?= stable
DEFAULT_CHANNEL ?= stable

# Operator namespace for bundle-run
OPERATOR_NAMESPACE ?= openshift-workload-availability
```

### Tool Versions (Centrally Pinned)

All tool versions are pinned in base.mk to prevent cross-repo drift:

| Tool | Version | Install Method |
|------|---------|----------------|
| kustomize | v5.8.1 | go install |
| controller-gen | v0.21.0 | go install |
| setup-envtest | v0.24.1 | go install |
| ginkgo | v2.32.1 | go install |
| goimports | v0.49.0 | go install |
| sort-imports | v0.3.0 | go install |
| operator-sdk | v1.42.3 | url download |
| opm | v1.73.0 | url download |
| yq | v4.53.3 | go install |

Operators can override any version:

```makefile
CONTROLLER_GEN_VERSION ?= v0.21.0
-include $(TOOLS_DIR)/build/base.mk
```

## Versioned Tool Installation

Tools install to versioned directories (`bin/tool/version/tool`), preventing conflicts when switching versions:

```
bin/
├── controller-gen/
│   └── v0.21.0/
│       └── controller-gen
├── kustomize/
│   └── v5@v5.8.1/
│       └── kustomize
└── opm/
    └── v1.73.0/
        └── opm
```

## Examples

### Standard Operator (NHC, SNR, NMO, MDR)

```makefile
OPERATOR_NAME ?= node-healthcheck-operator
-include $(TOOLS_DIR)/build/base.mk
```

### Operator with Agent (FAR)

```makefile
OPERATOR_NAME ?= fence-agents-remediation
BASE_AGENT_PATHS ?= cmd/fence-agent
-include $(TOOLS_DIR)/build/base.mk
```

### Operator with Build Script (FAR)

```makefile
OPERATOR_NAME ?= fence-agents-remediation
# BASE_BUILD_SCRIPT auto-detected from hack/build.sh
-include $(TOOLS_DIR)/build/base.mk
```

## Prow CI Integration

Prow configs remain unchanged:

```yaml
tests:
- as: test
  commands: make test
  container:
    from: src
```

The operator's Makefile includes base.mk, so `make test` uses the shared standardized target. Prow runs the command in the operator repo, Make resolves the target from the included base.mk.

## Target Behavior

### `make test` (CI Target)

1. Runs `go-verify` (tidy + vendor + verify)
2. Runs `manifests`, `generate`, `fmt`, `vet`, `fix-imports`
3. Installs envtest + ginkgo
4. Runs ginkgo with coverage, excluding `/e2e` and `/test`
5. Runs `bundle-reset` + `verify-unchanged`

### `make build`

1. If `hack/build.sh` exists, uses it
2. Otherwise: `go build -o bin/manager cmd/main.go`
3. If `BASE_AGENT_PATHS` set, builds each agent binary

### `make docker-build`

1. Runs `test-no-verify` first
2. Builds container image with docker/podman
3. Tags as `$(IMG)`

### `make bundle`

1. Generates kustomize manifests via operator-sdk
2. Sets controller image in kustomization
3. Builds bundle with operator-sdk
4. Resets creation date
5. Validates bundle

### `make catalog-build`

1. Initializes FBC with opm
2. Renders bundle image
3. Adds channel entries
4. Validates catalog
5. Builds catalog image

## Migration Guide

### Before (Operator-Specific)

```makefile
# ~150-225 lines per operator for:
# - Tool versions (drifting across repos)
# - go-install-tool / url-install-tool macros
# - manifests, generate, fmt, vet targets
# - build, test, docker-build targets
# - bundle, catalog targets
# - Tool installation targets
```

### After (Shared base.mk)

```makefile
OPERATOR_NAME ?= node-healthcheck-operator
-include $(TOOLS_DIR)/build/base.mk

# Only operator-specific targets remain in Makefile
```

Benefits:
- Same targets available across all 6 operators
- Pinned tool versions prevent drift
- Bug fixes: update once in tools repo
- Prow CI gets consistent commands
- Single source of truth

## Lines Saved

Per operator: ~300-500 lines of duplicated logic replaced.

Across 6 operators: **~2,000-3,000 lines eliminated**.

## Compatibility with Existing Targets

Operator Makefiles can override any target by defining it before or after the include:

```makefile
-include $(TOOLS_DIR)/build/base.mk

# Override: custom test target
test: custom-test

custom-test:
	./hack/run-tests.sh
```

Variables set before the include take precedence (Make's `?=` operator).
