OPERATOR_NAME ?= kind-block-test

# This repository is the tools checkout, so use its own dev.mk by default.
TOOLS_DIR ?= $(if $(wildcard $(CURDIR)/dev/dev.mk),$(CURDIR),$(shell cd .. && pwd)/tools)
DEV_MK := $(TOOLS_DIR)/dev/dev.mk
-include $(DEV_MK)

OPERATOR_SDK_VERSION ?= v1.42.2
OPERATOR_SDK = ./bin/operator-sdk

# Block-storage settings for this repository's own e2e target, and only for it.
# They must not be global: plain 'make dev-setup' — which the NFS, standard and
# MDR workflows run — would then switch to block mode, and kind_block_state()
# redirects KUBECONFIG into the block state directory, leaving those jobs
# without a kubeconfig.
#
# '?=' cannot express "env wins" here: dev.mk bare-exports several of these
# names, which defines them (empty) and makes '?=' a no-op. Check the origin
# instead, so the job env still takes precedence over these defaults.
block_default = $(if $(findstring environment,$(origin $(1)))$(findstring command line,$(origin $(1))),$($(1)),$(2))

BLOCK_STORAGE := $(call block_default,KIND_BLOCK_STORAGE,true)
BLOCK_CLUSTER := $(call block_default,MEDIK8S_CLUSTER_NAME,block-ci)
BLOCK_STATE_DIR := $(call block_default,KIND_BLOCK_STATE_DIR,$(CURDIR)/dist/block-ci)
BLOCK_KUBECONFIG := $(call block_default,KUBECONFIG,$(BLOCK_STATE_DIR)/kubeconfig)
BLOCK_SKIP_REGISTRY := $(call block_default,SKIP_REGISTRY,true)

# Exported for the sub-makes these recipes run.
BLOCK_TARGETS := test-kind-block test-block-verify
$(BLOCK_TARGETS): export KIND_BLOCK_STORAGE = $(BLOCK_STORAGE)
$(BLOCK_TARGETS): export MEDIK8S_CLUSTER_NAME = $(BLOCK_CLUSTER)
$(BLOCK_TARGETS): export KIND_BLOCK_STATE_DIR = $(BLOCK_STATE_DIR)
$(BLOCK_TARGETS): export KUBECONFIG = $(BLOCK_KUBECONFIG)
$(BLOCK_TARGETS): export SKIP_REGISTRY = $(BLOCK_SKIP_REGISTRY)

.PHONY: test-kind-block
test-kind-block:
	python3 -m unittest discover -s dev/tests -v
	@trap '$(MAKE) dev-teardown' EXIT; \
	$(MAKE) dev-setup && \
	$(MAKE) test-block-verify

.PHONY: test-block-verify
test-block-verify:
	@echo "=== Deploying test pods ==="
	kubectl apply -f dev/test-block.yaml
	kubectl wait --for=condition=Ready pod/block-writer pod/block-reader --timeout=120s
	@echo "=== Testing direct I/O cross-node write and read ==="
	@TOKEN="MEDIK8S_CI_$$(date +%s)"; \
	kubectl exec block-writer -- sh -c "printf '%-4096s' '$$TOKEN' | dd of=/dev/testblock bs=4096 count=1 oflag=direct status=none" && \
	OUTPUT=$$(kubectl exec block-reader -- dd if=/dev/testblock bs=4096 count=1 status=none | tr -d ' \0') && \
	echo "Wrote: '$$TOKEN'" && \
	echo "Read:  '$$OUTPUT'" && \
	if [ "$$TOKEN" = "$$OUTPUT" ]; then \
		echo "✅ SUCCESS: Shared raw block storage verified across worker nodes!"; \
	else \
		echo "❌ FAILURE: Read payload did not match written token!"; exit 1; \
	fi
	
.PHONY: operator-sdk
operator-sdk: ## Download operator-sdk locally if necessary.
ifeq (,$(wildcard $(OPERATOR_SDK)))
	@{ \
	set -e ;\
	mkdir -p $(dir $(OPERATOR_SDK)) ;\
	OS=$$(go env GOOS 2>/dev/null || echo linux) && ARCH=$$(go env GOARCH 2>/dev/null || echo amd64) && \
	curl -sSLo $(OPERATOR_SDK) https://github.com/operator-framework/operator-sdk/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_$${OS}_$${ARCH} ;\
	chmod +x $(OPERATOR_SDK) ;\
	}
endif
