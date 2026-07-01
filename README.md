# tools
Tools etc. which are not specific for one of the medik8s operators

## Dev Environment

Shared development environment for all medik8s operators. See [dev/README.md](dev/README.md) for full documentation.

### Quick Start

```bash
# 1. Add to your operator's Makefile (one-time):
#    TOOLS_DIR ?= $(shell cd .. && pwd)/tools
#    -include $(TOOLS_DIR)/dev/dev.mk

# 2. Create the dev cluster:
make dev-setup

# 3. Build and deploy your operator:
make dev-deploy

# 4. Simulate failures:
make dev-simulate-failure
```

## Other Tools

- `findIndexImage/` — Find OCP index images for IIB discovery
- `scripts/` — Build and deploy scripts for NHC+SNR
