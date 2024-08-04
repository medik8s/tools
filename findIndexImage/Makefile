SHELL := /bin/bash

GOROOT := $(shell go env GOROOT)

.PHONY: build
build:
	goreleaser release --snapshot --clean

.PHONY: lint
lint:
	go mod tidy
	go fmt
	go vet
	goreleaser check

.PHONY: cp-wasm-js
cp-wasm-js:
	cp $(GOROOT)/misc/wasm/wasm_exec.js frontend/ui

.PHONY: wasm
wasm:
	GOOS=js GOARCH=wasm go build -o frontend/ui/ui.wasm frontend/wasm/main.go
	## install "binaryen" for this tool!
	wasm-opt frontend/ui/ui.wasm --enable-bulk-memory -Oz -o frontend/ui/ui.wasm
