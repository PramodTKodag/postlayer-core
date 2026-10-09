# postlayer-core: single entry point for every task. Run `make` or `make help`.
# All tools run inside the pinned Docker image (see docker/Dockerfile).

export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)

COMPOSE   := docker compose
RUN_TOOLS := $(COMPOSE) run --rm tools

.DEFAULT_GOAL := help

.PHONY: help up down doctor versions \
        image build rebuild sizes \
        test upgrade-reference test-upgrades test-release-tools test-match test-fork snapshot gas-report coverage \
        fmt fmt-check slither aderyn analyze ci \
        install update-deps \
        chains-up chains-down chains-status chains-logs deploy-check \
        release-preflight release-deploy release-verify release-check release-manifest test-fork-release require-release-env \
        shell clean

##@ Help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo

##@ Run the project

up: image chains-up chains-status deploy-check ## One command: build the image, start both local chains, deploy to both and check the addresses match

down: chains-down ## Stop everything started by `make up`

deploy-check: ## Deploy SoloPostLayer to both local chains and check the proxy address matches
	$(RUN_TOOLS) "script/deploy-local.sh"

##@ Setup

doctor: ## Check that Docker and Compose are available and running
	@docker info >/dev/null 2>&1 || { echo "Docker is not running. Start Docker (or OrbStack) first."; exit 1; }
	@$(COMPOSE) version >/dev/null 2>&1 || { echo "Docker Compose is missing."; exit 1; }
	@echo "Docker and Compose are ready."

versions: ## Print the pinned tool versions inside the image
	$(RUN_TOOLS) "forge --version | head -1; anvil --version | head -1; node --version; slither --version; aderyn --version"

##@ Build

image: doctor ## Build the pinned tooling image
	$(COMPOSE) --profile tools build tools

build: ## Compile contracts
	$(RUN_TOOLS) "forge build"

rebuild: ## Clean compile from scratch
	$(RUN_TOOLS) "forge clean && forge build"

sizes: ## Compile and show contract sizes against the 24 KB limit
	$(RUN_TOOLS) "forge build --sizes"

##@ Test

test: ## Run unit, fuzz and invariant tests
	$(RUN_TOOLS) "forge test -vvv --no-match-path 'test/upgrades/*'"

# Released version the validator compares storage layout against; update after each release.
UPGRADE_REFERENCE_TAG ?= testnet-0.1.0

upgrade-reference: ## Build the released version's compiler output used as the upgrade baseline
	script/prepare-upgrade-reference.sh $(UPGRADE_REFERENCE_TAG)
	$(RUN_TOOLS) "cd .upgrade-reference/src && FOUNDRY_PROFILE=default FOUNDRY_AST=true FOUNDRY_EXTRA_OUTPUT='[\"storageLayout\"]' forge build --build-info --build-info-path ../reference-build-info src"

test-upgrades: upgrade-reference ## Check upgrade safety (OpenZeppelin validator, needs ffi)
	$(RUN_TOOLS) "npm ci --ignore-scripts && forge clean && FOUNDRY_PROFILE=upgrades forge test -vvv --match-path 'test/upgrades/*'"

test-release-tools: ## Offline tests for the release helpers (manifest writer and release.sh, with stubbed forge and cast)
	$(RUN_TOOLS) "PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test/release_tools -v && sh test/release_tools/test_release_sh.sh"

test-match: ## Run tests matching a name: make test-match MATCH=testFuzz_tip
	@test -n "$(MATCH)" || { echo "Usage: make test-match MATCH=<test name pattern>"; exit 1; }
	$(RUN_TOOLS) "forge test -vvv --match-test '$(MATCH)'"

test-fork: ## Run tests against a live chain: FORK_RPC_URL=<rpc url> make test-fork (the URL stays out of command lines and output)
	@test -n "$$FORK_RPC_URL" || { echo "Usage: FORK_RPC_URL=<rpc url> make test-fork"; exit 1; }
	$(RUN_TOOLS) "FOUNDRY_ETH_RPC_URL=\"\$$FORK_RPC_URL\" python3 script/hide_urls.py forge test -vv"

snapshot: ## Write the gas snapshot (.gas-snapshot)
	$(RUN_TOOLS) "forge snapshot"

gas-report: ## Print gas per function
	$(RUN_TOOLS) "forge test --gas-report"

coverage: ## Print test coverage
	$(RUN_TOOLS) "forge coverage"

##@ Quality

fmt: ## Format Solidity sources
	$(RUN_TOOLS) "forge fmt"

fmt-check: ## Fail if sources are not formatted
	$(RUN_TOOLS) "forge fmt --check"

slither: ## Static analysis with Slither (fails on medium or higher)
	$(RUN_TOOLS) "slither . --fail-medium"

aderyn: ## Static analysis with Aderyn (writes report.md)
	$(RUN_TOOLS) "aderyn ."

analyze: slither aderyn ## Run both static analyzers

ci: fmt-check sizes test test-upgrades test-release-tools analyze ## Everything CI runs

##@ Dependencies

install: ## Install a dependency: make install DEP=OpenZeppelin/openzeppelin-contracts-upgradeable@v5.7.0
	@test -n "$(DEP)" || { echo "Usage: make install DEP=<owner/repo@tag>"; exit 1; }
	$(RUN_TOOLS) "forge install $(DEP)"

update-deps: ## Update git submodule dependencies to their pinned refs
	git submodule update --init --recursive

##@ Local chains

chains-up: doctor ## Start two local chains: 8545 (id 31337) and 8546 (id 31338)
	$(COMPOSE) up -d --wait anvil-a anvil-b

chains-down: ## Stop the local chains
	$(COMPOSE) down

chains-status: ## Show chain ID and block number of both chains
	@printf "anvil-a (host :8545) chain-id "; $(COMPOSE) exec -T anvil-a cast chain-id --rpc-url http://127.0.0.1:8545
	@printf "anvil-a (host :8545) block     "; $(COMPOSE) exec -T anvil-a cast block-number --rpc-url http://127.0.0.1:8545
	@printf "anvil-b (host :8546) chain-id "; $(COMPOSE) exec -T anvil-b cast chain-id --rpc-url http://127.0.0.1:8545
	@printf "anvil-b (host :8546) block     "; $(COMPOSE) exec -T anvil-b cast block-number --rpc-url http://127.0.0.1:8545

chains-logs: ## Follow the logs of both chains
	$(COMPOSE) logs -f anvil-a anvil-b

##@ Release

# compose reads .env itself (including KEYSTORE_DIR, with ~ expanded); nothing from .env is evaluated by the host shell.
RELEASE := $(COMPOSE) run --rm release
# Early guard mirroring chain_config.CHAIN_ID: digits only, no leading zero, at most 18.
REQUIRE_CHAIN = case "$$CHAIN" in ''|0*|*[!0123456789]*) echo "CHAIN must be a chain id (digits, no leading zero), e.g. make $@ CHAIN=11155111"; exit 1 ;; esac; test $${\#CHAIN} -le 18 || { echo "CHAIN must be a chain id of at most 18 digits, e.g. make $@ CHAIN=11155111"; exit 1; }

# CHAINS_FILE in .env would swap the committed chains.json for another chain list; that is test-only (the local flow
# sets it itself), so a real release refuses it, and so LOCAL_CHAINS_OK, its opt-in. This grep is an early hint for the
# usual spellings; chain_config.py enforces the refusal where the file is read. .env is only grepped, never sourced.
# FOUNDRY_* and DAPP_* (forge reads both prefixes, in any letter case) would change the compiled bytecode and so the
# addresses behind the manifest; nothing downstream re-checks them, so for these variables the grep is the only check.
require-release-env:
	@test -f .env || { echo "Create .env from .env.example first"; exit 1; }
	@grep -q '^KEYSTORE_DIR=.' .env || { echo "Set KEYSTORE_DIR in .env"; exit 1; }
	@! grep -Eq '^[[:space:]]*(export[[:space:]]+)?(CHAINS_FILE|LOCAL_CHAINS_OK)[[:space:]]*[=:]' .env || { echo "CHAINS_FILE and LOCAL_CHAINS_OK are test-only and must not be set in .env for a release; remove them so chains.json is used"; exit 1; }
	@! grep -Eiq '^[[:space:]]*(export[[:space:]]+)?(FOUNDRY|DAPP)_[A-Z0-9_]*[[:space:]]*[=:]' .env || { echo "FOUNDRY_* and DAPP_* settings must not be set in .env for a release: they change the compiled bytecode (and so the addresses) while the manifest records the foundry.toml settings; remove them"; exit 1; }

release-preflight: require-release-env ## Read-only checks on every chain id in CHAINS (.env; chain data in chains.json)
	$(RELEASE) "script/release.sh preflight"

release-deploy: require-release-env ## Broadcast to ONE chain: make release-deploy CHAIN=11155111 (asks for confirmation)
	@$(REQUIRE_CHAIN)
	$(RELEASE) "script/release.sh deploy $(CHAIN)"

release-verify: require-release-env ## Verify source on Etherscan and Sourcify: make release-verify CHAIN=11155111
	@$(REQUIRE_CHAIN)
	$(RELEASE) "script/release.sh verify $(CHAIN)"

release-check: require-release-env ## Check the deployment on every chain in CHAINS
	$(RELEASE) "script/release.sh check"

release-manifest: require-release-env ## Write deployments/<RELEASE_NAME>.json from chain state (run after a real deploy)
	$(RELEASE) "python3 script/write_release_manifest.py"

test-fork-release: require-release-env ## Fork-deploy on every chain in CHAINS (.env); uses the chain RPC URLs (chains.json or your override)
	$(RELEASE) "script/release.sh fork-test"

##@ Utilities

shell: ## Open a shell in the tooling container
	$(COMPOSE) run --rm --entrypoint bash tools

clean: ## Remove build output, reports and caches (named volumes)
	$(COMPOSE) --profile tools down --volumes
	rm -rf out cache report.md
