# tools
Tools etc. which are not specific for one of the medik8s operators

## Dev Environment

Shared development environment for all medik8s operators. See [the development environment guide](docs/DEV_README.md) for full documentation.

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

## Documentation

### Table of contents

- [Development environment](docs/DEV_README.md) — setup, configuration, targets,
  and workflows for using the shared Medik8s development environment.
- [Kind reboot watcher](docs/kind-reboot-watcher.md) — what the watcher monitors,
  how its SNR and SBR modes work, how it restarts Kind nodes, and its timeout,
  usage, and simulation limits.

