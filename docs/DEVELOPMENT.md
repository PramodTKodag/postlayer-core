# Development

Everything runs in Docker, so every contributor and CI use the same tool versions. Only Docker (with Compose) and `make` are needed on your machine.

## Run the project (one command)

```sh
make up     # builds the tooling image if needed, starts both local chains, deploys to both and checks the addresses match
make down   # stops everything
```

`make up` is the normal way to start working. The first run builds the image and takes a few minutes. Every step below is also available as its own command.

## Step-by-step setup

```sh
make doctor     # checks that Docker and Compose are running
make image      # builds the pinned tooling image
make versions   # prints the tool versions inside the image
```

## The tooling image

`docker/Dockerfile` is the single source of truth for versions:

| Tool | Version | Notes |
|---|---|---|
| Foundry (forge, cast, anvil) | 1.8.5 | Official image, pinned by tag and digest |
| Node.js | 24.21.0 | Tarball verified by SHA-256 |
| Slither | 0.11.6 | Installed in a Python virtualenv |
| Aderyn | 0.6.8 | Installed with npm |
| OpenZeppelin upgrades-core | 1.46.0 | Pinned in `package.json`, installed by `make test-upgrades` |
| Solidity | 0.8.37 | Set in `foundry.toml` |

Update a version by editing the Dockerfile (or `foundry.toml` for solc), rebuilding with `make image`, and running `make ci`. CI builds the same image.

The container runs as your user, so files in `out/` and `cache/` belong to you. Compiler downloads are cached in a named Docker volume; `make clean` removes it.

## Common tasks

Run `make help` for the full list.

| Task | Command |
|---|---|
| Compile | `make build` |
| Contract sizes vs 24 KB limit | `make sizes` |
| All tests (excludes `test/upgrades`) | `make test` |
| Upgrade-safety check | `make test-upgrades` |
| One test | `make test-match MATCH=test_RevertWhen_publishPostCalledByNonOwner` |
| Tests against a real chain's state | `make test-fork FORK_URL=<rpc url>` |
| Gas report / snapshot | `make gas-report` / `make snapshot` |
| Coverage | `make coverage` |
| Format / check format | `make fmt` / `make fmt-check` |
| Static analysis | `make slither`, `make aderyn`, or `make analyze` |
| Release helper tests (offline) | `make test-release-tools` |
| Everything CI runs | `make ci` |
| Add a dependency | `make install DEP=OpenZeppelin/openzeppelin-contracts-upgradeable@v5.7.0` |
| Shell in the container | `make shell` |

## Test layers

1. **Unit, fuzz and invariant tests** (`make test`): in-process, fast, no node needed. Fuzz and invariant run counts are set in `foundry.toml`; CI uses the larger `ci` profile.
   `make test` excludes `test/upgrades`; `make test-upgrades` runs it with the `upgrades` profile (ffi enabled). `make test-upgrades` validates the upgrade safety of the implementation (constructor and initializer, unsafe patterns, initial values). `make upgrade-reference` first exports the released tag (`UPGRADE_REFERENCE_TAG` in the Makefile, currently `testnet-0.1.0`) with `git archive` into the git-ignored `.upgrade-reference/` and builds it there; the test then validates the current `SoloPostLayer` against that build through the validator's `referenceBuildInfoDir` option, so a storage-layout regression against the released version fails. The tag must exist locally (`git fetch --tags`). After each release, move `UPGRADE_REFERENCE_TAG` to the new tag. The validation profile compiles with `evm_version = "cancun"` only for the library's proxies; shipped bytecode stays `shanghai`. For the same reason `test/upgrades` is skipped by the default profile and compiled only under the `upgrades` profile. The OpenZeppelin validator is pinned in `package.json` and `package-lock.json`; `make test-upgrades` installs it with `npm ci` and the library's `npx` call uses that copy.
2. **Fork tests** (`make test-fork`): replay tests against a real chain's state. Run these for each target chain before a release to catch chain-specific issues such as a missing CREATE2 factory.
3. **Local chains** (`make chains-up`): two anvil nodes with different chain IDs, used to check that the same deployment produces the same address on both.

## Local chains

`make up` starts these for you. To manage them on their own:

```sh
make chains-up       # 127.0.0.1:8545 (chain id 31337) and 127.0.0.1:8546 (chain id 31338)
make chains-status   # chain ID and block number of both nodes
make chains-logs     # follow logs
make chains-down     # stop
```

`make up` also runs `make deploy-check`. It runs `script/deploy-local.sh`, which installs the deterministic factory on both local chains, deploys `SoloPostLayer` (implementation and UUPS proxy) to each, then verifies on both that the proxy has code, the expected owner and the expected ERC-1967 implementation. It then runs the release preflight, the deployment check and the manifest writer (into a temporary directory) against the two local chains, whose chain data comes from `script/local-chains.json` (keyed by chain id, `31337` and `31338`, display names `anvil_a` and `anvil_b`) (selected with `CHAINS_FILE`, a test-only knob, together with `LOCAL_CHAINS_OK=1`) so the real `chains.json` never lists local chains. `chain_config.py` (used by `release.sh` and the manifest writer) refuses `CHAINS_FILE` unless `LOCAL_CHAINS_OK=1` is set, and every `make release-*` target (and `make test-fork-release`) fails early if `.env` has a line setting `CHAINS_FILE` or `LOCAL_CHAINS_OK`, so a real release always reads the committed `chains.json`; never set either variable in `.env`. It ends with `OK` lines per chain showing the chain id and the same proxy address, plus a manifest line. The script uses anvil's public account 0 as deployer and owner and the salt label `postlayer-local`; these values live only in `script/deploy-local.sh`.

## Releasing to testnets

The release commands run in a separate `release` Compose service. It is the only service that mounts your Foundry keystore directory (read-only) and the only one that receives `.env` as environment variables. It does not hide `.env` from the others: the file sits in the workspace mount that every tooling container reads, and forge auto-loads `./.env` wherever it runs (which is why the fork test is opt-in). So do not run untrusted code through `make shell` or `make test-upgrades` while `.env` holds real RPC keys. No private key or keystore password is ever stored in the repository or in `.env`.

1. **Prerequisites.** Use a dedicated testnet account as `OWNER` and set `OWNER_IS_EOA=true` for it; never reuse a mainnet key. Fund the deployer address with faucet coins on every target chain. The deterministic factory must already exist on each chain (the deploy script never installs it on a real chain).
2. **Create the keystore** on the host (not in Docker): `cast wallet import <name> --interactive`. You type the private key and choose a password; the encrypted file lands in `~/.foundry/keystores`. `KEYSTORE_DIR` must point to a dedicated directory that contains only testnet accounts (for example `~/.foundry/testnet-keystores`; pass `--keystore-dir` to `cast wallet import`), because the whole directory is mounted into the release container. Use the account name as `KEYSTORE_ACCOUNT` and its public address as `DEPLOYER_ADDRESS`.
3. **Configure.** Chain data is public and committed in `chains.json`: per chain, keyed by its chain id (for example `"11155111"`), the same `chainId` (it must equal the key), an optional display `name` (used in messages only, never as an identifier), `explorerUrl` and a default public `rpcUrl`. Do not put a key in it: the tooling rejects an `rpcUrl` with credentials or a query string, but a key in the URL hostname or path cannot be detected either, so check what you commit. `chains.json` and `script/chain_config.py` decide where deploys are sent, so changes to them need explicit review (see `.github/CODEOWNERS`). `cp .env.example .env` and fill it in:

   | Variable | Meaning |
   |---|---|
   | `CHAINS` | Space-separated chain ids of this release (for example `"84532 11155111"`); each needs an entry in `chains.json`; digits only, no leading zero, at most 18 digits; chain names are refused |
   | `CHAIN_<id>_RPC_URL` | Optional. Your own RPC URL for that chain (may contain a secret); replaces the public `rpcUrl` from `chains.json` |
   | `OWNER` | Proxy owner |
   | `OWNER_IS_EOA` | Set to `true` when `OWNER` is a plain account (EOA). Left unset, preflight requires `OWNER` to have code on every chain, so a contract wallet such as a Safe must already be deployed on each target chain |
   | `SALT_LABEL` | Names the deployment; part of the address |
   | `DEPLOYER_ADDRESS` | Public address of the keystore account (balance check and `--sender`) |
   | `KEYSTORE_ACCOUNT` | Name given to `cast wallet import` |
   | `KEYSTORE_DIR` | Dedicated host directory holding only testnet keystores, mounted read-only; may start with `~` (Compose expands it) |
   | `ETHERSCAN_API_KEY` | Etherscan API v2 key; optional, Etherscan verification is skipped without it (Sourcify needs none) |
   | `MANIFEST_DIR` | Optional directory for the manifest instead of `deployments/` |
   | `RELEASE_FORK_TEST` | Set to `1` by `make test-fork-release` only; not for `.env` |
   | `RELEASE_NAME` | Manifest name; lowercase letters, digits, `-`, `.`, `_`, not starting with `.` or `-` (for example `testnet-0.1.0`) |

   `<id>` is the chain id, for example `CHAIN_84532_RPC_URL`. The expected chain id comes from `chains.json`; deploy, check and the manifest refuse to continue on a mismatch. A `.env` that still lists chain names (`CHAINS="ethereum_sepolia"`) fails with `chain 'ethereum_sepolia' is not a chain id; use e.g. 11155111`; replace the names with ids. Use the override when the public RPC is rate-limited or you want a private or paid endpoint; leave it unset otherwise. Variables left over from older layouts (`<NAME>_RPC_URL`, `<NAME>_CHAIN_ID`, `<NAME>_EXPLORER_URL`) are ignored and can be deleted from `.env`.
4. **Preflight (read-only, required before deploy):** `make release-preflight`. Deploy itself checks only the chain id and your confirmation, so always run preflight first. It checks every chain in `CHAINS`: chain id, factory, deployer balance, that `OWNER` has code on the chain (unless `OWNER_IS_EOA=true`) and predicted addresses. It does not check for existing code at the predicted addresses; re-running a deploy is safe because `DeploySoloPostLayer` skips any contract that already has code at its predicted address.
5. **Optional fork test:** `make test-fork-release`. Deploys the real script on a fork of every chain in `CHAINS` and checks the chain id, that the proxy address is identical and that it works. It uses a throwaway owner and a fixed salt label, so it cannot confirm your release addresses; only preflight and check do that. It runs only through this target (`script/release.sh fork-test` exports each chain's `CHAIN_<id>_RPC_URL` and `CHAIN_<id>_ID` and sets `RELEASE_FORK_TEST=1`), so plain `make test` never forks a real chain even though forge auto-loads `.env`. Traces are deliberately off (`-vv`), because forge traces would print the RPC URL; do not raise the verbosity.
6. **Deploy, one chain at a time:** `make release-deploy CHAIN=84532`. It confirms the chain id, prints the chain (id and display name), signer, deployer, owner and salt label, and asks you to type the chain id. Then forge prompts for the keystore password and broadcasts. Repeat for each chain.
7. **Verify source, per chain:** `make release-verify CHAIN=84532`. Refuses to run when the chain's RPC reports another chain id. Verifies the implementation and the proxy on Sourcify and on Etherscan (forge `--chain`). Without `ETHERSCAN_API_KEY` the Etherscan pass is skipped with a notice; the command fails only if a verification that ran fails. The Etherscan v2 path could not be tested locally; treat it as untested until the first real run.
8. **Check:** `make release-check`. Confirms on every chain that the RPC reports the configured chain id and that the proxy has code, the expected owner and the expected implementation, at the same address.
9. **Manifest:** `make release-manifest` writes `deployments/<RELEASE_NAME>.json` from chain state, with `chains` keyed by chain id (commit, build settings, addresses, code hashes, deploy transactions, explorer links). Chain id, owner, implementation slot and code hashes are read back from the chains; the deploy transaction list comes from the broadcast file in this checkout, the commit and build settings from this checkout, and the addresses are predicted. The writer fails if the broadcast file is missing, has no transactions, has a failed or receipt-less transaction, or did not create the predicted implementation and proxy. A re-run of the deploy that skipped existing contracts leaves no creation transactions, so keep the original `broadcast/DeploySoloPostLayer.s.sol/<chainId>/run-latest.json` from the real deploy until the manifest is written. The write is atomic and it refuses to overwrite an existing file; it warns when the git tree is not clean. The file is your own record of your own deployment: `deployments/` is git-ignored, so it is not committed. Every integrator deploys their own instance (own `OWNER` and `SALT_LABEL`); this repo does not publish a shared deployment.
10. **Tag** a release only with the owner's explicit go-ahead.

Warnings:

- Private RPC URLs and API keys live only in `.env` (the public RPC URLs in `chains.json` are not secret). The scripts and the manifest writer take the names of the variables, not URLs, so URLs stay out of command lines, traces and the manifest. URLs are masked in error text in three places, and only when the exact URL string appears: the manifest writer, `release.sh preflight` and `check` (forge's output is replaced by `<rpc url hidden>` for every configured RPC URL and shown once forge finishes), and the chain-id read behind `deploy` and `verify` (`cast`'s error text is dropped). `deploy` itself streams forge's output unmasked and relies on that up-front chain-id check to catch an unreachable RPC first. Forge records the RPC URL in `cache/<script>/<chainId>/run-latest.json` and in `broadcast/`; both are git-ignored and must not be shared. Other `cast` and `forge` output, and any variation of the URL (its host, a re-encoded form), is not masked, so do not paste raw terminal output publicly.
- The same proxy address on every chain needs the same `OWNER`, `SALT_LABEL` and build. Release from a clean tree at a recorded commit.
- Move ownership to a multisig and timelock before any mainnet use.
- To add a chain, add one entry to `chains.json` keyed by its chain id (`chainId` equal to the key, optional `name` of 1-40 letters, digits, spaces, `_`, `.` or `-`, `explorerUrl`, public `rpcUrl`) and put the id in `CHAINS`. No `.env` variables are needed; set `CHAIN_<id>_RPC_URL` only if you want a private RPC for it.

Anvil's accounts and mnemonic are public. Never send real funds to them. The ports are published on `127.0.0.1` only.

Inside the Compose network the chains are reachable as `http://anvil-a:8545` and `http://anvil-b:8545`.

## Static analysis

- `make slither` fails on findings of medium severity or higher. Paths outside `src/` are filtered in `slither.config.json`.
- `make aderyn` writes `report.md` (not committed). It does not fail the build; review it on every change.

## Compiler settings

`foundry.toml` pins the Solidity version, EVM version and optimizer, and drops metadata hashes so bytecode, and therefore CREATE2 addresses, do not depend on the build machine. Upgrade-safety checks from OpenZeppelin need `ffi`, so they run in the separate `upgrades` profile and the default profile cannot run shell commands.

## CI

`.github/workflows/ci.yml` builds the same tooling image and runs `make ci` with the larger fuzz and invariant counts. Third-party Actions are pinned by commit SHA.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Docker is not running` | Start Docker Desktop or OrbStack, then `make doctor` |
| Permission errors in `out/` or `cache/` | `make clean`, then rerun; the container runs as your user |
| `forge` cannot download a compiler | Check network access; the download is cached after the first success |
| Port 8545 or 8546 already in use | Stop the other node, or edit the host ports in `docker-compose.yml` |
