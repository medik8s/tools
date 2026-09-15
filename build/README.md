# Medik8s CI Build Targets

Shared build, test, and deployment targets for consistent Prow CI across all Medik8s operators.

## Quick Start

Add to end of operator Makefile:

```makefile
# Shared CI targets from medik8s/tools
BASE_OPERATOR_NAME ?= node-healthcheck-operator
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

```bash
make build           # Build operator binary (and agents if configured)
make test            # Run unit tests with code generation and verification
make test-no-verify  # Run unit tests without verification (faster for CI)
make docker-build    # Build container image
make docker-push     # Push container image
make deploy          # Deploy operator to cluster via kustomize
make undeploy        # Remove operator from cluster
```

## Configuration

### Required Variables

```makefile
BASE_OPERATOR_NAME ?= node-healthcheck-operator
```

### Optional Variables

```makefile
# Main binary location (auto-detected from main.go or cmd/main.go)
BASE_MAIN_PATH ?= main.go

# Agent binaries (for operators like SBR)
BASE_AGENT_PATHS ?= cmd/sbr-agent

# Container image
IMG ?= ttl.sh/node-healthcheck-operator:1h

# Version
VERSION ?= 0.0.1

# Build platforms
BASE_PLATFORMS ?= linux/amd64,linux/arm64
```

## Examples

### Standard Operator (NHC, SNR, NMO, MDR, FAR)

```makefile
BASE_OPERATOR_NAME ?= node-healthcheck-operator
-include $(TOOLS_DIR)/build/base.mk
```

Result:
- `make build` → `go build -o bin/manager main.go`
- `make test` → runs generate, fmt, vet, then tests
- `make docker-build` → builds container image

### Operator with Agent (SBR)

```makefile
BASE_OPERATOR_NAME ?= storage-based-remediation
BASE_AGENT_PATHS ?= cmd/sbr-agent
-include $(TOOLS_DIR)/build/base.mk
```

Result:
- `make build` → builds both `bin/manager` and `bin/sbr-agent`
- `make test` → same standardized test flow
- `make docker-build` → builds container image

## Prow CI Integration

Prow configs remain unchanged:

```yaml
tests:
- as: test
  commands: make test
  container:
    from: src
```

The operator's Makefile includes base.mk, so `make test` uses the shared standardized target.

## Target Behavior

### `make build`

1. Runs `generate`, `fmt`, `vet`
2. Builds `bin/manager` from `main.go` (or `cmd/main.go`)
3. If `BASE_AGENT_PATHS` set, builds each agent binary

### `make test`

1. Runs `generate`, `fmt`, `vet`
2. Installs envtest
3. Runs `go test` with KUBEBUILDER_ASSETS set
4. Excludes `/e2e` tests
5. Generates `cover.out`

### `make test-no-verify`

Same as `test` but skips `generate`, `fmt`, `vet` for faster CI runs.

### `make docker-build`

1. Builds container image with `$(BASE_CONTAINER_TOOL)` (docker or podman)
2. Tags as `$(IMG)`
3. Supports multi-platform via `$(BASE_PLATFORMS)`

### `make deploy`

1. Runs `manifests` and `kustomize`
2. Updates `config/manager/kustomization.yaml` with `$(IMG)`
3. Applies to cluster via `kubectl apply`

## Migration Guide

### Before (Operator-Specific Makefile)

```makefile
# node-healthcheck-operator/Makefile
test: test-no-verify
test-no-verify: envtest
	go test ./... -coverprofile cover.out

docker-build: test-no-verify
	docker build -t ${IMG} .
```

### After (Shared base.mk)

```makefile
# node-healthcheck-operator/Makefile
BASE_OPERATOR_NAME ?= node-healthcheck-operator
-include $(TOOLS_DIR)/build/base.mk
```

Benefits:
- Same targets available
- Standardized behavior across all operators
- Single source of truth (fix once in base.mk)
- Prow CI gets consistent commands

## Lines Saved

Estimate per operator:
- ~100-150 lines of duplicated target logic
- ~50-75 lines of tool installation
- **Total: ~150-225 lines per operator**

Across 6 operators: **~900-1,350 lines eliminated**

## Compatibility with Existing Targets

If your operator has custom `build` or `test` targets, you can:

1. **Override**: Define your target AFTER including base.mk
2. **Extend**: Call base target from your custom one
3. **Rename**: Keep custom as `build-custom`, use base.mk for CI

Example extending:

```makefile
-include $(TOOLS_DIR)/build/base.mk

# Custom test that adds extra checks
test: base-test
	@echo "Running custom validation..."
	./hack/verify-something.sh

base-test: generate fmt vet envtest
	KUBEBUILDER_ASSETS="$(shell $(BASE_ENVTEST) use $(BASE_ENVTEST_VERSION) --bin-dir $(LOCALBIN) -p path)" go test ./... -coverprofile cover.out
```

## Tool Versions

base.mk uses separate tool binaries to avoid conflicts:

- `$(LOCALBIN)/kustomize-base` (v5.8.1)
- `$(LOCALBIN)/controller-gen-base` (v0.17.0)
- `$(LOCALBIN)/setup-envtest-base` (release-0.19)

Your operator can have its own versions in parallel.

## Updating

When tools repo updates base.mk:

```bash
# If using sibling checkout
cd ../tools && git pull

# If using .tools/
rm -rf .tools && make test  # auto-clones latest
```

CI automatically gets latest on each run (shallow clone).
