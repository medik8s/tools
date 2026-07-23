VENV := venv
PIP := $(VENV)/bin/pip
PYTEST := $(VENV)/bin/pytest
PYTHON := $(VENV)/bin/python
UV := $(shell command -v uv 2>/dev/null)

$(VENV):
ifdef UV
	$(UV) venv $(VENV)
	$(UV) pip install -q -r requirements.txt --python $(PYTHON)
else
	python3 -m venv $(VENV)
	$(PIP) install -q -r requirements.txt
endif

.PHONY: test
test: $(VENV)
	$(PYTEST) -v

.PHONY: clean
clean:
	rm -rf $(VENV) .pytest_cache release.md release.html release-slack.txt
