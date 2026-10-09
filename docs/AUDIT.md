# Audit readiness

Scope, trust model, invariants and static-analysis triage for `postlayer-core`, for reviewers and auditors. The project has **not** been audited yet (see `SECURITY.md`).

## Scope

In scope: everything under `src/` (`SoloPostLayer` and the four modules, about 340 lines) and the deterministic deploy path in `script/` (`DeploySoloPostLayer.s.sol`, `DeploymentGuards.sol`, `DeterministicFactory.sol`). Out of scope: OpenZeppelin dependencies in `lib/`, tests, and the off-chain release tooling.

Build: solc 0.8.37, `evm_version = "shanghai"`, optimizer 200 runs, `bytecode_hash = "none"`. Review the tagged release (`testnet-0.1.0`), not a moving branch.

## Roles and trust model

| Role | Can | Cannot |
|---|---|---|
| Owner (one address, `Ownable2Step`) | Publish, update, hide and unhide posts; approve and remove tip tokens and set their minimum; upgrade the implementation (UUPS) | Move tips or user funds (the contract holds none); renounce ownership (disabled) |
| Reader (any address) | Like and unlike (once per post, not their own), tip a visible post that is not their own | Choose the tip recipient; publish or edit anything |

- Solo mode: only the owner publishes, so the owner is the only author and receives every tip.
- The owner is trusted. A malicious or compromised owner can upgrade to arbitrary code, so mainnet requires the owner to be a multisig behind a timelock (not yet done; the testnet owner is a single EOA).
- Approving a token trusts that token's code. Fee-on-transfer and rebasing tokens must not be approved (owner policy, not checked on-chain).

## Invariants (tested)

| Property | Test |
|---|---|
| `postCount` equals the number of published posts | `PostRegistryInvariant` |
| A post's author never changes; version only grows by one per update; hide and unhide change only the `hidden` flag | `PostRegistryInvariant` |
| `likeCount` equals the number of distinct likers; the author is never counted | `ReactionsInvariant` |
| The contract holds no tip funds; the author receives exactly what was tipped | `TippingInvariant` |
| Each module's storage slot matches the ERC-7201 formula | `test_storageLocation_matchesErc7201Formula` in `PostRegistry`, `Reactions`, `TokenAllowlist` and `Tipping` tests |
| Storage layout is compatible with the released version and the upgrade is safe | `UpgradeSafety` (baseline built from the release tag), `SoloPostLayerUpgrade` |

## Known behaviour and limitations

- **No custody.** Tips are forwarded in the same transaction. A rejecting author (native) or a blocklisted author (ERC-20) makes that tip revert; the tipper keeps their funds.
- **Reentrancy.** `tipPost` forwards all gas to the author for native tips. It is guarded by a minimal reentrancy flag in its own ERC-7201 slot (`ReentrancyGuardTransient` is not used because the EVM target is `shanghai`).
- **Forced ETH.** Ether can still arrive through `selfdestruct` or as a block reward. It is not tracked or claimable. The invariant tests compare tip flows, not the absolute balance.
- **Upgrades.** The owner can change tipping behaviour for future tips. No stored balances exist to take.
- **Payee does not follow ownership.** Tips go to the address that published the post. After `transferOwnership` (or a key rotation) the previous owner keeps receiving tips on existing posts, while the new owner edits them. Rule: deploy with the final owner from day one and do not transfer ownership. Accepted as a documented rule instead of a code change.
- **Owner must exist on every chain.** `initialize(OWNER)` accepts any non-zero address. The deploy script (and the preflight) refuse when `OWNER` has no code on the target chain, so a contract-wallet owner that is not deployed on one chain cannot be baked into that chain's proxy by this tooling. An owner declared a plain account with `OWNER_IS_EOA=true` must instead have no contract code (an EIP-7702 delegation is allowed), so the flag cannot be used to skip the contract-wallet checks. They also require the code at `OWNER` to hash to the operator-pinned `OWNER_CODEHASH`, so a different contract that someone else deployed at that address on that chain is refused. The pin does not prove control: a wallet whose code is identical on every chain (a Safe proxy) can be replayed at the same address by someone else, with their own signers. The operator must check the signers and threshold on every chain before deploying.
- **Anyone can deploy the canonical proxy on a chain you never targeted.** Deployment is permissionless and the init code, including `OWNER`, is public once deployed anywhere. With an EOA owner this is harmless. With a contract-wallet owner whose address someone else could claim on that chain (a Safe whose factory or singleton differs there), the proxy at the canonical address would belong to that claimant. The same address therefore does not mean "operated by us" outside the chains you deployed to; front ends must trust only the chains in their own release record.
- **The release workspace is shared with the other tooling.** The `release` container builds into its own `/tmp` output and cache and ignores Python bytecode in the workspace, but it bind-mounts the same working tree as `tools`, which runs third-party code (the upgrade validator with ffi). Sources, `lib/`, `foundry.toml` and `.git` can therefore be changed by that code, and the change can be hidden from `git status` (for example with `git update-index --assume-unchanged`), so the manifest's `gitTreeClean` flag does not prove the tree is untouched. Release from a fresh clone, and do not run `make test-upgrades` or other `tools` commands in the clone you release from.
- **Same address across chains** depends on the deterministic factory, the salt label, the owner and the exact bytecode.

## Static analysis triage

Run with `make analyze` (Slither fails on medium or higher; Aderyn writes `report.md`).

| Tool | Finding | Verdict |
|---|---|---|
| Slither | Inline assembly in the four `_get…Storage()` helpers | Expected: the ERC-7201 slot assignment, standard pattern |
| Aderyn H-1 | "Contract locks Ether without a withdraw function" | False positive: `tipPost` is `payable` but forwards the native amount to the author in the same call and reverts on a mismatch; `invariant_contractNeverHoldsFunds` covers it. Only forced ETH can remain (see above) |
| Aderyn L-1 | Centralization risk (`onlyOwner` on upgrade and `renounceOwnership`) | Accepted: the owner trust model above; mitigated for mainnet by multisig and timelock |
| Aderyn L-2 | Empty block in `_authorizeUpgrade` | Expected: the access check is the `onlyOwner` modifier |
| Aderyn L-3 | `nonReentrant` modifier used once | Accepted: kept as a named modifier for clarity |
| Aderyn L-4 | Unchecked return of `_getExistingPost` in `ReactionModule` | Intended: the call is made for its revert on a missing post |

## Before an external audit

- Owner moves to a multisig and timelock (mainnet precondition).
- Fix the release tag to be audited and rebuild the upgrade baseline from it.
- Run `make ci` from a clean checkout and attach the output.
