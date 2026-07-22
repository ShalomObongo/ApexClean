.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help build app universal run test coverage lint format clean ci

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Compile in debug
	swift build

app: ## Build the signed ApexClean.app bundle
	@bash Scripts/bundle.sh

universal: ## Build ApexClean.app for Apple Silicon and Intel
	@UNIVERSAL=1 bash Scripts/bundle.sh

run: app ## Build and launch ApexClean.app
	@open dist/ApexClean.app

test: ## Run the ApexCore test suite
	swift test

coverage: ## Run tests and report engine coverage
	@swift test --enable-code-coverage
	@BIN="$$(swift build --show-bin-path)"; \
	xcrun llvm-cov report \
		"$$BIN/ApexCleanPackageTests.xctest/Contents/MacOS/ApexCleanPackageTests" \
		-instr-profile="$$BIN/codecov/default.profdata" \
		--ignore-filename-regex='(/Tests/|/\.build/|/Sources/ApexClean/)'

lint: ## Check formatting without changing anything
	swift format lint --recursive --strict --configuration .swift-format Sources Tests

format: ## Apply the project formatting style in place
	swift format --in-place --recursive --configuration .swift-format Sources Tests

ci: lint test universal ## Run everything CI runs, locally

clean: ## Remove build artefacts
	rm -rf .build dist
