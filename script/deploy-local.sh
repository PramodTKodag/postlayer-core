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

# Preflight reads OWNER and OWNER_IS_EOA itself, so exercise that wiring against the real chains: anything but a
# plain boolean "true" must be refused for an owner without code (a malformed value fails at parsing), and the owner is checked on every chain separately.
expect_preflight_refusal() { # <expected error text>; runs with the caller's environment
  if out="$(script/release.sh preflight 2>&1)"; then
    echo "error: preflight should have failed with '$1'" >&2; exit 1
  fi
  case "$out" in *"$1"*) ;; *) echo "error: preflight failed without '$1':" >&2; echo "$out" >&2; exit 1 ;; esac
}
# An empty value stands for "not declared": forge fills a variable that is unset from ./.env, so unsetting it here would
# let a developer's own .env change what this test checks.
(OWNER_IS_EOA=; expect_preflight_refusal "OwnerHasNoCode(31337")
(OWNER_IS_EOA=yes; expect_preflight_refusal "failed parsing \$OWNER_IS_EOA")
# A contract-wallet owner that exists on chain A only: chain A passes, chain B is refused.
WALLET_OWNER=0x1111111111111111111111111111111111111111
cast rpc --rpc-url "$CHAIN_A" anvil_setCode "$WALLET_OWNER" 0x00 > /dev/null
WALLET_CODEHASH="$(cast keccak 0x00)"
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; expect_preflight_refusal "OwnerHasNoCode(31338")
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; out="$(script/release.sh preflight 2>&1 || true)"
 case "$out" in *"OwnerHasNoCode(31337"*|*"OwnerCodehashMismatch(31337"*) echo "error: chain A has the owner's pinned code but was refused" >&2; exit 1 ;; esac)
# A different contract at the owner address (the address was claimed by someone else) or no pin at all must be refused, never accepted as "has code".
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$(cast keccak 0x6000)"; export OWNER OWNER_CODEHASH; expect_preflight_refusal "OwnerCodehashMismatch(31337")
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH=; export OWNER OWNER_CODEHASH; expect_preflight_refusal "OwnerCodehashMismatch(31337")

# The deploy script enforces the same checks itself, so a broadcast cannot skip the preflight: it refuses before sending anything.
expect_deploy_refusal() { # <rpc url> <expected chain id> <expected error text>; runs with the caller's environment
  if out="$(EXPECTED_CHAIN_ID="$2" forge script script/DeploySoloPostLayer.s.sol --rpc-url "$1" --broadcast --private-key "$DEPLOYER_KEY" 2>&1)"; then
    echo "error: deploy should have failed with '$3'" >&2; exit 1
  fi
  case "$out" in *"$3"*) ;; *) echo "error: deploy failed without '$3':" >&2; echo "$out" >&2; exit 1 ;; esac
}
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$WALLET_CODEHASH"; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_B" 31338 "OwnerHasNoCode(31338")
(OWNER_IS_EOA=; OWNER="$WALLET_OWNER" OWNER_CODEHASH="$(cast keccak 0x6000)"; export OWNER OWNER_CODEHASH; expect_deploy_refusal "$CHAIN_A" 31337 "OwnerCodehashMismatch(31337")
(expect_deploy_refusal "$CHAIN_B" 31337 "WrongChainId(31337")
# No expected chain id means no deploy: the variable is required, an empty one does not parse.
(expect_deploy_refusal "$CHAIN_B" "" "EXPECTED_CHAIN_ID")
cast rpc --rpc-url "$CHAIN_A" anvil_setCode "$WALLET_OWNER" 0x > /dev/null

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
