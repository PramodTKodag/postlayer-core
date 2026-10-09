#!/bin/sh
# Installs the factory on both local chains, deploys SoloPostLayer to each, and checks the addresses match.
# Local chains only: the account and key below are anvil's public default account 0.
set -eu

CHAIN_A=http://anvil-a:8545
CHAIN_B=http://anvil-b:8545
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

export OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# Anvil account 0 is a plain account (no code); declaring it keeps preflight and the deploy script from demanding code at the owner address.
export OWNER_IS_EOA=true
export SALT_LABEL=postlayer-local

for chain in "31337 $CHAIN_A" "31338 $CHAIN_B"; do
  set -- $chain
  forge script script/InstallFactory.s.sol --rpc-url "$2"
  # The deploy script refuses a chain other than EXPECTED_CHAIN_ID, so each chain's id is stated here.
  EXPECTED_CHAIN_ID="$1" forge script script/DeploySoloPostLayer.s.sol --rpc-url "$2" --broadcast --private-key "$DEPLOYER_KEY"
done

# The scripts read each RPC url from the named environment variable, so urls never reach script arguments or traces.
export CHAIN_31337_RPC_URL="$CHAIN_A" CHAIN_31338_RPC_URL="$CHAIN_B"
forge script script/CheckDeployment.s.sol --sig 'run(string[],uint256[])' '[CHAIN_31337_RPC_URL,CHAIN_31338_RPC_URL]' '[31337,31338]'

# Exercise the release helpers against the local chains (read-only), keyed by chain id. Display name, RPC URL and explorer come from the
# local fixture, so the real chains.json never lists local chains. The RPC URLs are resolved from the file here.
unset CHAIN_31337_RPC_URL CHAIN_31338_RPC_URL
export CHAINS_FILE=script/local-chains.json LOCAL_CHAINS_OK=1
export CHAINS="31337 31338"
export DEPLOYER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
script/release.sh preflight
script/release.sh check

# Preflight reads OWNER, OWNER_IS_EOA and OWNER_CODEHASH itself, so exercise that wiring against the real chains. An owner
# that is not declared an EOA must have code on every chain and that code must hash to the pin; a malformed value fails at
# parsing; and the owner is checked on every chain separately.
expect_preflight_refusal() { # <expected error text>; runs with the caller's environment
  if out="$(script/release.sh preflight 2>&1)"; then
    echo "error: preflight should have failed with '$1'" >&2; exit 1
  fi
  case "$out" in *"$1"*) ;; *) echo "error: preflight failed without '$1':" >&2; echo "$out" >&2; exit 1 ;; esac
}
expect_preflight_ok() { # runs with the caller's environment; both chains must report OK
  if ! out="$(script/release.sh preflight 2>&1)"; then
    echo "error: preflight should have passed:" >&2; echo "$out" >&2; exit 1
  fi
  for chain_id in 31337 31338; do
    case "$out" in *"OK preflight, chain id $chain_id"*) ;; *) echo "error: preflight did not pass chain $chain_id:" >&2; echo "$out" >&2; exit 1 ;; esac
  done
}
# An empty value stands for "not declared": forge fills a variable that is unset from ./.env, so unsetting it here would
# let a developer's own .env change what this test checks.
WALLET_OWNER=0x1111111111111111111111111111111111111111
# forge caches chain state per block number and anvil_setCode does not mine, so mine a block after changing the code or
# forge would keep answering from the cache of an earlier run.
set_wallet_code() { # <rpc url> <code>
  cast rpc --rpc-url "$1" anvil_setCode "$WALLET_OWNER" "$2" > /dev/null
  cast rpc --rpc-url "$1" anvil_mine > /dev/null
}
WALLET_CODEHASH="$(cast keccak 0x00)"
OTHER_CODEHASH="$(cast keccak 0x6000)"
(OWNER_IS_EOA=; OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER_CODEHASH; expect_preflight_refusal "OwnerHasNoCode(31337")
(OWNER_IS_EOA=yes; OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER_CODEHASH; expect_preflight_refusal "failed parsing \$OWNER_IS_EOA")
# An owner declared an EOA has no code to pin: a pin next to OWNER_IS_EOA=true is refused, never ignored.
(OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER_CODEHASH; expect_preflight_refusal "OwnerIsEoaWithCodehash(31337")
# A contract-wallet owner needs a pin; release.sh asks for it, and a malformed one fails at parsing, not as "unset".
(OWNER_IS_EOA=; OWNER_CODEHASH=; export OWNER_CODEHASH; expect_preflight_refusal "OWNER_CODEHASH is not set")
# A contract-wallet owner that exists on chain A only: chain A passes, chain B is refused.
set_wallet_code "$CHAIN_A" 0x00
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; expect_preflight_refusal "OwnerHasNoCode(31338"
 case "$out" in *"(31337"*) echo "error: chain A has the owner's pinned code but was refused" >&2; echo "$out" >&2; exit 1 ;; esac)
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH=zz; export OWNER OWNER_CODEHASH; expect_preflight_refusal "failed parsing")
# Declaring the wallet an EOA must not switch the owner checks off: an address with code is refused as an EOA.
(OWNER="$WALLET_OWNER" OWNER_CODEHASH=; export OWNER OWNER_CODEHASH; expect_preflight_refusal "OwnerIsEoaHasCode(31337")
# The pinned code on both chains passes on both.
set_wallet_code "$CHAIN_B" 0x00
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; expect_preflight_ok)
# A different contract at the owner address on chain B (the address was claimed by someone else) is refused there,
# after chain A passed: the pin is checked on every chain of the loop.
set_wallet_code "$CHAIN_B" 0x6000
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; expect_preflight_refusal "OwnerCodehashMismatch(31338"
 case "$out" in *"OwnerCodehashMismatch(31337"*) echo "error: chain A has the pinned code but was refused" >&2; echo "$out" >&2; exit 1 ;; esac)
# A pin that is not the code at the owner is refused, whichever chain is looked at first.
set_wallet_code "$CHAIN_B" 0x00
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$OTHER_CODEHASH"; export OWNER OWNER_CODEHASH; expect_preflight_refusal "OwnerCodehashMismatch(31337")

# The deploy script enforces the same checks itself, so a broadcast cannot skip the preflight: it refuses before sending anything.
expect_deploy_refusal() { # <rpc url> <expected chain id> <expected error text>; runs with the caller's environment
  if out="$(EXPECTED_CHAIN_ID="$2" forge script script/DeploySoloPostLayer.s.sol --rpc-url "$1" --broadcast --private-key "$DEPLOYER_KEY" 2>&1)"; then
    echo "error: deploy should have failed with '$3'" >&2; exit 1
  fi
  case "$out" in *"$3"*) ;; *) echo "error: deploy failed without '$3':" >&2; echo "$out" >&2; exit 1 ;; esac
}
set_wallet_code "$CHAIN_B" 0x
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_B" 31338 "OwnerHasNoCode(31338")
# The message ends with the pinned hash and the owner's actual hash, so a pin that stopped being read (zero) cannot satisfy this.
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$OTHER_CODEHASH"; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_A" 31337 "$OTHER_CODEHASH, $WALLET_CODEHASH)")
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH=; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_A" 31337 "OwnerCodehashNotPinned(31337")
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH=zz; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_A" 31337 "failed parsing")
(OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_A" 31337 "OwnerIsEoaWithCodehash(31337")
(OWNER="$WALLET_OWNER" OWNER_CODEHASH=; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_A" 31337 "OwnerIsEoaHasCode(31337")
(expect_deploy_refusal "$CHAIN_B" 31337 "WrongChainId(31337")
# No expected chain id means no deploy: the variable is required, an empty one does not parse.
(expect_deploy_refusal "$CHAIN_B" "" "EXPECTED_CHAIN_ID")
# The pinned code is accepted: the same run without --broadcast simulates the whole deploy and passes. (A real broadcast
# here would replace the broadcast record of the main deploy, which the manifest below reads.)
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH
 set_wallet_code "$CHAIN_A" 0x00
 EXPECTED_CHAIN_ID=31337 forge script script/DeploySoloPostLayer.s.sol --rpc-url "$CHAIN_A" --private-key "$DEPLOYER_KEY" > /dev/null)
set_wallet_code "$CHAIN_A" 0x

# Write a manifest for the local chains into a temp dir and check its shape.
export RELEASE_NAME=local-check OWNER SALT_LABEL
MANIFEST_DIR="$(mktemp -d)"; export MANIFEST_DIR
python3 script/write_release_manifest.py
python3 - "$MANIFEST_DIR/local-check.json" "$CHAINS_FILE" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
required = ["release", "gitCommit", "gitTreeClean", "solc", "evmVersion", "optimizerRuns", "factory",
            "saltLabel", "owner", "implementation", "proxy", "chains"]
missing = [k for k in required if k not in m]
assert not missing, f"manifest missing {missing}"
assert set(m["chains"]) == {"31337", "31338"}, m["chains"].keys()
for key, chain in m["chains"].items():
    assert chain["chainId"] == int(key)
    assert chain["name"] == {"31337": "anvil_a", "31338": "anvil_b"}[key]
    assert chain["owner"].lower() == m["owner"].lower()
    assert chain["deployTransactions"], f"{key}: no deploy transactions recorded"
text = json.dumps(m)
for entry in json.load(open(sys.argv[2])).values():
    assert entry["rpcUrl"] not in text, "manifest must not contain RPC URLs"
assert "rpc" not in text.lower(), "manifest must not mention RPC"
print("OK manifest", sys.argv[1])
PY

# A second run for the same release must refuse to overwrite the manifest.
if refusal="$(python3 script/write_release_manifest.py 2>&1)"; then
  echo "manifest writer overwrote an existing manifest" >&2; exit 1
fi
case "$refusal" in
  *"refusing to overwrite"*) ;;
  *) echo "unexpected manifest writer failure: $refusal" >&2; exit 1 ;;
esac
echo "OK manifest overwrite refused"
