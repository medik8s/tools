OPERATOR_NAME ?= kind-block-test
TOOLS_DIR ?= $(shell cd .. && pwd)/tools
DEV_MK := $(TOOLS_DIR)/dev/dev.mk
-include $(DEV_MK)

OPERATOR_SDK_VERSION ?= v1.42.2
OPERATOR_SDK = ./bin/operator-sdk
export KIND_BLOCK_STORAGE ?= true
export MEDIK8S_CLUSTER_NAME ?= block-ci
export KIND_BLOCK_STATE_DIR ?= $(CURDIR)/dist/block-ci
export KUBECONFIG ?= $(KIND_BLOCK_STATE_DIR)/kubeconfig
export SKIP_REGISTRY ?= true
export CONTAINER_TOOL ?= docker

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
