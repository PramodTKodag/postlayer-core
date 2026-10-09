# postlayer-core

On-chain publishing layer: authors publish posts, readers like them and tip the author in native coin or approved tokens. Upgradeable (UUPS), chain-agnostic, content-type neutral.

> **Status: post registry, UUPS `SoloPostLayer` and a same-address deployment script (proven on the two local chains) are implemented; free likes and tips (native coin and owner-approved ERC-20 tokens) are implemented too; real-chain deployment is not. Not audited. Do not deploy to mainnet.**

## What it is

PostLayer starts as a blogging contract and is built so images and video can follow without a redesign. A post stores a pointer to its content (IPFS or Arweave) plus a hash; likes are free; tips are paid to the post's author in the same transaction, so the contract holds no user funds.

| Mode | Who posts | Tips | Where it lives |
|---|---|---|---|
| **Solo** | Only the owner (set at initialization) | 100% to the post's author | This repo (`postlayer-core`, MIT) |
| **Platform** | Many registered authors | Author share plus a capped platform fee | Separate repo (`postlayer-platform`) built on this one |

## Features

Implemented:

- Publish, update and hide posts (`contentType`, `contentUri`, `contentHash`).
- UUPS upgradeable proxy: ship new features and keep the same address.
- Same-address deployment through a CREATE2 factory, proven on the two local chains.
- Free likes with O(1) cost: one per address per post, the author cannot like their own post, no new likes on hidden posts.
- Tips paid straight to the post's author in the native coin or an ERC-20 the owner has approved, each token with its own minimum tip. The contract holds no tip balances; a rejected payout reverts the tip.

Planned:

- Deployment to real EVM chains with the same address on each.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design.

## Quick start

Requirements: Docker (with Compose) and `make`. No local Solidity toolchain is needed.

```sh
make up      # build the tooling image (first run only), start two local chains, deploy to both, check the addresses match
make down    # stop everything
make help    # list every command
make ci      # run everything CI runs
```

`make up` starts two local chains: `127.0.0.1:8545` (chain id 31337) and `127.0.0.1:8546` (chain id 31338). `make up` then deploys `SoloPostLayer` to both and checks that the proxy address matches (`make deploy-check`).

### Testnet release

The step-by-step process for deploying to testnets is in [Releasing to testnets](docs/DEVELOPMENT.md#releasing-to-testnets).

More in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Repository layout

```
.
├── src/                  Contracts
├── test/                 Unit, fuzz, invariant and upgrade tests
├── script/               Deploy and check scripts
├── docker/Dockerfile     Pinned tooling image: Foundry, Node, Slither, Aderyn
├── docker-compose.yml    Tooling container and two local anvil chains
├── Makefile              Single entry point for every task
├── foundry.toml          Compiler and test settings
├── docs/                 Architecture, development and conventions
└── .github/workflows/    CI
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modules, upgradeability, storage rules, same-address deployment |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Docker setup, commands, test layers, CI |
| [docs/CONVENTIONS.md](docs/CONVENTIONS.md) | Naming and code style |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose and submit changes |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

## Security

This project is intended to handle other people's money. It is unaudited. Read [SECURITY.md](SECURITY.md) before using any code from this repository.

## License

MIT. See [LICENSE](LICENSE).
