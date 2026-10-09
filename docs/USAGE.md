# Using PostLayer

How to call a deployed `SoloPostLayer`: every function, who may call it, and copy-paste [`cast`](https://book.getfoundry.sh/cast/) commands. To deploy your own instance, see [Releasing to testnets](DEVELOPMENT.md#releasing-to-testnets). For the design, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Before you start

- Call the **proxy** address, never the implementation. The proxy keeps its address across upgrades.
- Solo mode: only the **owner** publishes, updates, hides and unhides posts and manages tip tokens. **Anyone** can read, like and tip.
- Post ids start at 1 and grow by one. `postCount()` is the id of the newest post.
- The contract holds no funds. A tip goes straight from the tipper to the post's author.

Set these once per shell:

```sh
export RPC_URL=<your chain's RPC url>
export PROXY=<proxy address>
```

On a real chain sign with a Foundry keystore (`cast wallet import <name> --interactive`) and add `--account <name>` to every `cast send`. On a local anvil chain you can use anvil's public test key instead (`--private-key 0xac09...ff80`, owner account 0); never use it on a real network.

## Function reference

### Posts

| Function | Who | What it does |
|---|---|---|
| `publishPost(bytes32 contentType, string contentUri, bytes32 contentHash)` | owner | Creates a post and emits `PostPublished`. `contentType` and `contentHash` must not be zero, `contentUri` must not be empty. The id is `postCount()` after the call. |
| `updatePost(uint256 postId, string contentUri, bytes32 contentHash)` | owner | Replaces the URI and hash, adds 1 to `version`, emits `PostUpdated` with the previous hash. The type and author do not change. |
| `hidePost(uint256 postId)` | owner | Hides a post (emits `PostHidden`). Does nothing if already hidden. |
| `unhidePost(uint256 postId)` | owner | Shows it again (emits `PostUnhidden`). Does nothing if not hidden. |
| `getPost(uint256 postId)` returns `Post` | anyone | `(author, hidden, publishedAt, updatedAt, version, contentType, contentHash, contentUri)`. Hidden posts can still be read. |
| `postCount()` returns `uint256` | anyone | Number of posts published so far. |

`author` is the address that published the post. It never changes, even if ownership moves later.

### Likes

| Function | Who | What it does |
|---|---|---|
| `likePost(uint256 postId)` | anyone except the post's author | Adds the caller's like (once per address), emits `PostLiked`. Not allowed on hidden posts. |
| `unlikePost(uint256 postId)` | a current liker | Removes the like, emits `PostUnliked`. Allowed on hidden posts. |
| `likeCount(uint256 postId)` returns `uint256` | anyone | Likes now on the post. |
| `hasLiked(uint256 postId, address account)` returns `bool` | anyone | Whether `account` likes it now. |

### Tips

| Function | Who | What it does |
|---|---|---|
| `tipPost(uint256 postId, address token, uint256 amount)` (payable) | anyone except the post's author | Pays `amount` to the post's author and emits `PostTipped`. Use `token = 0x0000000000000000000000000000000000000000` for the native coin, with `msg.value == amount`. For an ERC-20, send no value and approve the proxy for `amount` first. |
| `tipConfig(address token)` returns `(bool allowed, uint256 minTip)` | anyone | Whether tips in `token` are accepted and the minimum. |
| `setTokenAllowed(address token, uint256 minTip)` | owner | Accepts tips in `token` (or changes its minimum). `minTip` must not be zero. Emits `TokenAllowed`. |
| `setTokenDisallowed(address token)` | owner | Stops accepting `token`. Emits `TokenDisallowed`. |

Tips are off until the owner approves a token. That includes the native coin: call `setTokenAllowed(0x0000000000000000000000000000000000000000, minTip)` first. Never approve fee-on-transfer or rebasing tokens.

### Ownership and upgrades

| Function | Who | What it does |
|---|---|---|
| `owner()` / `pendingOwner()` | anyone | Current owner and the address that can accept a pending transfer. |
| `transferOwnership(address newOwner)` | owner | Starts a two-step transfer. |
| `acceptOwnership()` | pending owner | Completes it. |
| `renounceOwnership()` | owner | Always reverts (`RenounceOwnershipDisabled`). |
| `upgradeToAndCall(address newImplementation, bytes data)` | owner | UUPS upgrade; pass `0x` as `data` for no call. |
| `initialize(address)`, `proxiableUUID()`, `UPGRADE_INTERFACE_VERSION()` | n/a | Plumbing. `initialize` runs once at deployment and cannot be called again. |

Tips follow the post's stored author, not the current owner, so do not transfer ownership after publishing; deploy with the final owner from day one ([AUDIT.md](AUDIT.md)).

## Walkthrough

### Publish

`contentType` is a 32-byte tag your app defines (any non-zero value). `contentHash` is a hash of the content you store at the URI.

```sh
CONTENT_TYPE=$(cast keccak "blog")
CONTENT_HASH=$(cast keccak "$(cat post.md)")

cast send $PROXY "publishPost(bytes32,string,bytes32)" \
  $CONTENT_TYPE "ipfs://<cid>" $CONTENT_HASH --account owner --rpc-url $RPC_URL

cast call $PROXY "postCount()(uint256)" --rpc-url $RPC_URL      # the new post's id
```

### Read

```sh
cast call $PROXY \
  "getPost(uint256)((address,bool,uint48,uint48,uint32,bytes32,bytes32,string))" 1 --rpc-url $RPC_URL
```

To list every post, loop `getPost` from 1 to `postCount()`, or read the `PostPublished`, `PostUpdated`, `PostHidden` and `PostUnhidden` events (below).

### Update, hide, unhide

```sh
cast send $PROXY "updatePost(uint256,string,bytes32)" 1 "ipfs://<new cid>" $(cast keccak "$(cat post.md)") --account owner --rpc-url $RPC_URL
cast send $PROXY "hidePost(uint256)" 1 --account owner --rpc-url $RPC_URL
cast send $PROXY "unhidePost(uint256)" 1 --account owner --rpc-url $RPC_URL
```

### Like

```sh
cast send $PROXY "likePost(uint256)" 1 --account reader --rpc-url $RPC_URL
cast call $PROXY "likeCount(uint256)(uint256)" 1 --rpc-url $RPC_URL
cast call $PROXY "hasLiked(uint256,address)(bool)" 1 <reader address> --rpc-url $RPC_URL
cast send $PROXY "unlikePost(uint256)" 1 --account reader --rpc-url $RPC_URL
```

### Owner: approve tip tokens

```sh
NATIVE=0x0000000000000000000000000000000000000000

# native coin, minimum 0.001 (1e15 wei)
cast send $PROXY "setTokenAllowed(address,uint256)" $NATIVE 1000000000000000 --account owner --rpc-url $RPC_URL

# an ERC-20, minimum 1,000,000 base units
cast send $PROXY "setTokenAllowed(address,uint256)" <token> 1000000 --account owner --rpc-url $RPC_URL

cast call $PROXY "tipConfig(address)(bool,uint256)" $NATIVE --rpc-url $RPC_URL
cast send $PROXY "setTokenDisallowed(address)" <token> --account owner --rpc-url $RPC_URL
```

### Tip

Native coin (the amount and `--value` must match):

```sh
cast send $PROXY "tipPost(uint256,address,uint256)" 1 $NATIVE 1000000000000000 \
  --value 1000000000000000 --account reader --rpc-url $RPC_URL
```

ERC-20 (approve the proxy first, send no value):

```sh
cast send <token> "approve(address,uint256)" $PROXY 2000000 --account reader --rpc-url $RPC_URL
cast send $PROXY "tipPost(uint256,address,uint256)" 1 <token> 2000000 --account reader --rpc-url $RPC_URL
```

Approve only the amount you tip, and revoke any leftover allowance.

### Transfer ownership

```sh
cast send $PROXY "transferOwnership(address)" <new owner> --account owner --rpc-url $RPC_URL
cast send $PROXY "acceptOwnership()" --account <new owner account> --rpc-url $RPC_URL
```

## Events

| Event | Fields (`indexed` marked) |
|---|---|
| `PostPublished` | `postId` (indexed), `author` (indexed), `contentType`, `contentUri`, `contentHash` |
| `PostUpdated` | `postId` (indexed), `version`, `previousContentHash`, `contentUri`, `contentHash` |
| `PostHidden`, `PostUnhidden` | `postId` (indexed) |
| `PostLiked`, `PostUnliked` | `postId` (indexed), `liker` (indexed) |
| `PostTipped` | `postId` (indexed), `tipper` (indexed), `token` (indexed), `author`, `amount` |
| `TokenAllowed` | `token` (indexed), `minTip` |
| `TokenDisallowed` | `token` (indexed) |
| `OwnershipTransferStarted`, `OwnershipTransferred`, `Upgraded` | standard OpenZeppelin events |

Read them with the full signature, including `indexed`:

```sh
cast logs --from-block <deploy block> --address $PROXY \
  "PostPublished(uint256 indexed,address indexed,bytes32,string,bytes32)" --rpc-url $RPC_URL
```

An indexer should follow these events instead of looping over `getPost`.

## Errors

When a call reverts, `cast` prints the error selector and data. Decode it with the error's signature:

```sh
cast decode-error <data> --sig "TokenNotAllowed(address)"
```

| Function | Reverts with |
|---|---|
| any function taking a `postId` | `PostNotFound(postId)` for id 0 or an id above `postCount()` |
| `publishPost`, `updatePost`, `hidePost`, `unhidePost`, `setTokenAllowed`, `setTokenDisallowed`, `transferOwnership`, `upgradeToAndCall` | `OwnableUnauthorizedAccount(account)` when the caller is not the owner |
| `publishPost` | `EmptyContentType()`, `EmptyContentUri()`, `EmptyContentHash()` |
| `updatePost` | `EmptyContentUri()`, `EmptyContentHash()` |
| `likePost` | `PostHiddenCannotBeLiked`, `AuthorCannotLikeOwnPost`, `AlreadyLiked` |
| `unlikePost` | `NotLiked` |
| `tipPost` | `PostHiddenCannotBeTipped`, `AuthorCannotTipOwnPost`, `TokenNotAllowed`, `TipBelowMinimum`, `TipValueMismatch`, `NativeTransferFailed`, `ReentrantCall`, or the token's own revert for an ERC-20 |
| `setTokenAllowed` | `InvalidMinTip()` for a zero minimum |
| `setTokenDisallowed` | `TokenNotApproved(token)` |
| `acceptOwnership` | `OwnableUnauthorizedAccount(account)` when the caller is not the pending owner |
| `renounceOwnership` | `RenounceOwnershipDisabled()` |

`tipPost` checks in this order: post exists, not hidden, tipper is not the author, token approved, amount at least the minimum, then `msg.value`. Details are in [`ITipping`](../src/interfaces/ITipping.sol).

## From another contract

Import the interfaces (`IPostRegistry`, `IReactions`, `ITipping`, `ITokenAllowlist`) from `src/interfaces/` and call the proxy:

```solidity
IPostRegistry.Post memory post = IPostRegistry(proxy).getPost(1);
ITipping(proxy).tipPost{value: 0.001 ether}(1, address(0), 0.001 ether);
```

The interfaces are not frozen yet ([ARCHITECTURE.md](ARCHITECTURE.md)), so pin a release tag.
