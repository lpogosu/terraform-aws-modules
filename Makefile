TERRAFORM_VERSION      ?= 1.9
TERRAFORM_DOCS_VERSION ?= 0.20.0
TFLINT_VERSION         ?= v0.60.0
CHECKOV_VERSION        ?= 3.2.334
GO_VERSION             ?= 1.23

# Everything runs in a container, so the result does not depend on what happens to be
# installed on the machine. TF_PLUGIN_CACHE_DIR keeps the provider out of every module
# directory: the AWS provider is about 700 MB unpacked, and without the cache every
# `init` downloads it again.
ROOT       := $(shell pwd)
CACHE_DIR  := $(ROOT)/.terraform-cache
DOCKER_RUN := docker run --rm -v "$(ROOT)":/w -w /w
TF         := $(DOCKER_RUN) -v "$(CACHE_DIR)":/plugin-cache -e TF_PLUGIN_CACHE_DIR=/plugin-cache -e TF_IN_AUTOMATION=1
TFDOCS     := $(DOCKER_RUN) quay.io/terraform-docs/terraform-docs:$(TERRAFORM_DOCS_VERSION)

DIRS := $(sort $(dir $(wildcard modules/*/ examples/*/)))

# Platforms the lock file has to cover. A lock generated on one platform breaks
# `terraform init` for everyone on the others.
LOCK_PLATFORMS := -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

$(CACHE_DIR):
	@mkdir -p $(CACHE_DIR)

.PHONY: fmt
fmt: ## Rewrite every .tf file into canonical form
	$(DOCKER_RUN) hashicorp/terraform:$(TERRAFORM_VERSION) fmt -recursive

.PHONY: fmt-check
fmt-check: ## Fail if any .tf file is not canonically formatted
	$(DOCKER_RUN) hashicorp/terraform:$(TERRAFORM_VERSION) fmt -check -recursive -diff

.PHONY: validate
validate: $(CACHE_DIR) ## terraform init + validate for every module and example
	@set -e; for d in $(DIRS); do \
		echo "==> $$d"; \
		$(TF) --entrypoint sh hashicorp/terraform:$(TERRAFORM_VERSION) -c \
			"cd $$d && terraform init -backend=false -input=false -no-color >/dev/null && terraform validate -no-color"; \
	done

.PHONY: docs
docs: ## Regenerate the input/output tables in every README
	$(TFDOCS) markdown table --config /w/.terraform-docs.yml \
		--recursive --recursive-include-main=false --recursive-path modules --output-file README.md /w
	$(TFDOCS) markdown table --config /w/.terraform-docs.yml \
		--recursive --recursive-include-main=false --recursive-path examples --output-file README.md /w

.PHONY: docs-check
docs-check: ## Fail if the generated tables are out of date
	$(TFDOCS) markdown table --config /w/.terraform-docs.yml \
		--recursive --recursive-include-main=false --recursive-path modules --output-file README.md --output-check /w
	$(TFDOCS) markdown table --config /w/.terraform-docs.yml \
		--recursive --recursive-include-main=false --recursive-path examples --output-file README.md --output-check /w

.PHONY: lint
lint: ## Run tflint with the AWS ruleset over every module and example
	$(DOCKER_RUN) --entrypoint sh ghcr.io/terraform-linters/tflint:$(TFLINT_VERSION) -c \
		'tflint --init >/dev/null && tflint --recursive --config /w/.tflint.hcl --format compact'

.PHONY: security
security: ## Run checkov over the whole repository
	$(DOCKER_RUN) bridgecrew/checkov:$(CHECKOV_VERSION) --directory /w --config-file /w/.checkov.yaml

.PHONY: vet
vet: ## go vet the Terratest package. Compiles the tests; does not run them
	$(DOCKER_RUN) -v "$(ROOT)/.go-cache":/gocache -e GOCACHE=/gocache -e GOFLAGS=-mod=mod \
		-w /w/test golang:$(GO_VERSION) sh -c 'go mod download && go vet ./...'

.PHONY: test
test: ## Run the Terratest suite. Creates real AWS resources and costs real money
	$(DOCKER_RUN) -v "$(ROOT)/.go-cache":/gocache -e GOCACHE=/gocache \
		-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION \
		-w /w/test golang:$(GO_VERSION) go test -v -timeout 45m ./...

.PHONY: lock
lock: $(CACHE_DIR) ## Regenerate cross-platform provider lock files for the examples
	@set -e; for d in $(sort $(dir $(wildcard examples/*/))); do \
		echo "==> $$d"; \
		$(TF) --entrypoint sh hashicorp/terraform:$(TERRAFORM_VERSION) -c \
			"cd $$d && terraform init -backend=false -input=false -no-color >/dev/null && terraform providers lock $(LOCK_PLATFORMS) -no-color"; \
	done

.PHONY: check
check: fmt-check validate lint security docs-check vet ## Everything CI runs

.PHONY: clean
clean: ## Remove provider downloads and the shared caches
	rm -rf $(CACHE_DIR) $(ROOT)/.go-cache
	find modules examples -type d -name .terraform -prune -exec rm -rf {} +
