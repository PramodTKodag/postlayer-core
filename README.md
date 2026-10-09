# postlayer-core

[![CI](https://github.com/PramodTKodag/postlayer-core/actions/workflows/ci.yml/badge.svg)](https://github.com/PramodTKodag/postlayer-core/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/PramodTKodag/postlayer-core/badge)](https://scorecard.dev/viewer/?uri=github.com/PramodTKodag/postlayer-core)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

On-chain publishing layer: authors publish posts, readers like them and tip the author in native coin or approved tokens. Upgradeable (UUPS), chain-agnostic, content-type neutral.

> **Status: post registry, UUPS `SoloPostLayer`, free likes, tips (native coin and owner-approved ERC-20 tokens), a same-address deployment script (proven on the two local chains) and testnet release tooling are implemented; the `testnet-0.1.0` release was deployed to Ethereum Sepolia. Not audited. Do not deploy to mainnet.**

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
- Same-address deployment through a CREATE2 factory, proven on the two local chains, with release tooling for real chains (preflight, deploy, verify, check, manifest).
- Free likes with O(1) cost: one per address per post, the author cannot like their own post, no new likes on hidden posts.
- Tips paid straight to the post's author in the native coin or an ERC-20 the owner has approved, each token with its own minimum tip. The contract holds no tip balances; a rejected payout reverts the tip.

Planned:

- Mainnet deployment, which needs an audit and an owner that is a multisig behind a timelock first.

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
├── chains.json           Public chain data for releases (chain id, explorer, default RPC)
├── docs/                 Architecture, development, conventions and users
└── .github/              CI, security scans, dependency updates, issue and PR templates
```

## Documentation

| Doc | Contents |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modules, upgradeability, storage rules, same-address deployment |
| [docs/USAGE.md](docs/USAGE.md) | Every function, who can call it, `cast` examples, events and errors |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Docker setup, commands, test layers, CI |
| [docs/CONVENTIONS.md](docs/CONVENTIONS.md) | Naming and code style |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose and submit changes |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | How we treat each other |
| [GOVERNANCE.md](GOVERNANCE.md) | Who decides, and how changes and releases happen |
| [SUPPORT.md](SUPPORT.md) | Where to ask questions and report bugs |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability |
| [docs/USED_BY.md](docs/USED_BY.md) | Projects built on PostLayer |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

## Security

This project is intended to handle other people's money. It is unaudited. Read [SECURITY.md](SECURITY.md) before using any code from this repository.

## Using PostLayer

Every integrator deploys their own instance with their own owner and salt label; this repository publishes no shared deployment. You do not need permission.

Once deployed, call the proxy address. The owner publishes; anyone reads, likes and tips:

```sh
cast send $PROXY "publishPost(bytes32,string,bytes32)" $(cast keccak "blog") "ipfs://<cid>" $(cast keccak "<content>") --account owner --rpc-url $RPC_URL
cast call $PROXY "getPost(uint256)((address,bool,uint48,uint48,uint32,bytes32,bytes32,string))" 1 --rpc-url $RPC_URL
cast send $PROXY "likePost(uint256)" 1 --account reader --rpc-url $RPC_URL
cast send $PROXY "tipPost(uint256,address,uint256)" 1 0x0000000000000000000000000000000000000000 1000000000000000 --value 1000000000000000 --account reader --rpc-url $RPC_URL
```

Tips are off until the owner approves a token (the native coin included). Every function, who can call it, the events, the errors and more examples are in [docs/USAGE.md](docs/USAGE.md).

## License and credit

MIT. See [LICENSE](LICENSE). If you copy or publish this source (including as the verified source of your deployment), keep the copyright and license notice with it. If you build on PostLayer, you are welcome to add your project to [docs/USED_BY.md](docs/USED_BY.md) and to cite it with [CITATION.cff](CITATION.cff). The project is funded through [GitHub Sponsors](https://github.com/sponsors/PramodTKodag).
