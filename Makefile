.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help build app run test lint clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Compile in debug
	swift build

app: ## Build the signed ApexClean.app bundle
	@bash Scripts/bundle.sh

run: app ## Build and launch ApexClean.app
	@open dist/ApexClean.app

test: ## Run the ApexCore test suite
	swift test

clean: ## Remove build artefacts
	rm -rf .build dist
