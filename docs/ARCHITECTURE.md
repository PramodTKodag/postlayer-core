# Architecture

Design for `postlayer-core`. Items marked **planned** are not implemented yet.

## Goals

1. Publish content-neutral posts (blog first; image and video later).
2. Let readers like posts for free and tip authors.
3. Never hold user funds in normal operation.
4. Ship new features without changing the contract address.
5. Run at the same address on every supported EVM chain.

## Posts

A post stores a pointer, not the content: `contentType`, `contentUri` (IPFS or Arweave) and `contentHash`, plus author, version and timestamps. Titles and summaries live in the off-chain content. Events carry everything an indexer needs. Reasons: on-chain text is expensive, cannot be removed, and large posts break list reads.

## Modules

| Module | Responsibility |
|---|---|
| `PostRegistryModule` | Publish, update, hide posts (implemented) |
| `ReactionModule` | Free like and unlike (mapping plus counter, O(1)); implemented, own ERC-7201 storage `postlayer.storage.Reaction`, separate from the registry. Rules: the author cannot like their own post, one like per address per post, no new likes on hidden posts, unliking is always allowed, counts and flags stay readable on hidden posts |
| `TippingModule` | Pays a post's author directly in the native coin or an approved ERC-20 (implemented); holds no balances. Its reentrancy guard is a minimal one in its own ERC-7201 slot `postlayer.storage.Tipping` (OpenZeppelin's has a constructor, which the upgrade-safety validator rejects) |
| `TokenAllowlistModule` | Owner-approved tip tokens with a per-token minimum tip (implemented); own ERC-7201 slot `postlayer.storage.TokenAllowlist`. The native coin is the zero address; a minimum of zero is not allowed, so a zero minimum means "not approved" |
| `SoloPostLayer` | Deployable contract for solo mode: only the owner publishes (implemented, UUPS) |

Interfaces (`IPostRegistry`, `IReactions`, `ITipping`, `ITokenAllowlist`) are frozen and versioned before other projects build on them.

## Tips

1. Reader calls `tipPost(postId, token, amount)`; `token` is the zero address for the native coin.
2. Checks run in this order (see `ITipping`): the post exists, it is not hidden, the tipper is not the author, the token is approved, the amount meets the token's minimum (a zero amount always fails), and `msg.value` equals `amount` for native and is zero for ERC-20.
3. The `PostTipped` event is emitted, then the payout runs under `nonReentrant`.
4. Native is forwarded to the author with a low-level call. An ERC-20 goes straight from the tipper to the author with `SafeERC20` (the tipper must have approved the contract). A rejected payout reverts the whole tip: nothing is escrowed and nothing is held.

The tip goes to the post's stored author, not to a caller-chosen address. Hidden posts take no tips. Core charges no fee; platform fees belong to `postlayer-platform`. Owners must not approve fee-on-transfer or rebasing tokens. The stored author is the address that published the post and never changes, while editing follows the current owner, so a later `transferOwnership` does not move the payee: deploy with the final owner (for example the multisig) from day one and do not transfer ownership afterwards.

## Upgradeability

- UUPS proxy (ERC-1822 on ERC-1967). The proxy keeps the address and the data; upgrades swap the implementation.
- OpenZeppelin Contracts Upgradeable v5 with ERC-7201 namespaced storage: each module has its own storage struct.
- Storage is append-only: never reorder, retype or remove fields.
- The implementation constructor calls `_disableInitializers()`; the proxy is initialized in the same transaction that creates it.
- `_authorizeUpgrade` is restricted to the owner (`Ownable2Step`, two-step transfer). `renounceOwnership` is disabled so one mistaken call cannot lock posting and upgrades for good. A dedicated upgrader role, a multisig with a timelock, and an optional one-way upgrade lock are **planned**.
- Deploy the proxy with the `initialize` calldata passed to its constructor, so the proxy is created and initialized in one transaction. An uninitialized proxy could be initialized by anyone who front-runs a separate `initialize` call.
- Upgrades are covered by tests: deploy v1, write state, upgrade, check the state survived (`make test`), and an OpenZeppelin upgrade-safety check (`make test-upgrades`).

Trade-off: an upgradeable contract asks users to trust the upgrade process, not only the code. Because tips are paid out immediately, the contract stores no balances, but ERC-20 allowances that tippers grant to the proxy persist across upgrades, so a compromised upgrade path could pull tokens up to those allowances and redirect future tips. Front ends should request exact-amount approvals, and tippers should revoke leftovers. The timelock exists for that reason.

## Same address on every chain

Implemented for local chains (`script/DeploySoloPostLayer.s.sol`); deployment to real chains has not been done.

- Deploy through the standard deterministic CREATE2 factory (`0x4e59b44847b379578588920cA78FbF26c0B4956C`). Real chains must already have it; the deploy script fails if it is missing. Only local anvil chains get it installed (`script/InstallFactory.s.sol`).
- The implementation and the proxy salts are derived from `SALT_LABEL`. The proxy is created with its initializer calldata (`initialize(OWNER)`) in the same transaction, so initialization cannot be front-run.
- The proxy address depends on the factory, `SALT_LABEL`, `OWNER` and the exact compiled bytecode. Changing any of them changes the address.
- Re-running the script skips contracts that already exist. `script/CheckDeployment.s.sol` verifies on each chain that the RPC reports the expected chain id and that the proxy has code, the expected owner and the expected ERC-1967 implementation, and fails when given no chains. It compares against the initial implementation and owner, so it fails after an upgrade or an ownership transfer: it is a post-deploy check, not a monitor.
- Compiler version, optimizer settings and `evm_version` are fixed, and `bytecode_hash = "none"` keeps bytecode independent of source paths.
- Each chain has its own state. Upgrades run per chain; keep a record of the version deployed on each chain.
- The native coin differs per chain, so the minimum tip is configured per chain and per token.

## Contract size

Contracts are limited to 24,576 bytes (EIP-170). Logic is split into modules and libraries; media handling stays off chain.

## Out of scope for core

Multiple authors, platform fees and author registration belong to `postlayer-platform`, which builds on the modules above.
