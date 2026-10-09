#!/bin/sh
# Release helper. Operator settings come from the environment (see .env.example); display name, explorer and default
# RPC URL of each chain come from chains.json via chain_config.py, keyed by chain id (CHAIN_<id>_RPC_URL overrides the RPC URL).
#   release.sh preflight           read-only checks on every chain id in $CHAINS
#   release.sh deploy <chain id>   broadcast the deploy to one chain (asks for confirmation)
#   release.sh verify <chain id>   verify implementation and proxy on Etherscan and Sourcify
#   release.sh check               check the deployment on every chain
#   release.sh fork-test           deploy on a fork of every chain in $CHAINS, using the chains.json RPC URL or your CHAIN_<id>_RPC_URL override
set -eu
set -f # no glob expansion of $CHAINS

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

fail() { echo "error: $*" >&2; exit 1; }

need() {
  eval "value=\${$1:-}"
  [ -n "$value" ] || fail "$1 is not set (see .env.example)"
}

# Early guard mirroring chain_config.CHAIN_ID: digits only, no leading zero, at most 18. Chain ids become part of
# variable names, so nothing else is accepted. Digits are spelled out because ranges can match other characters under some locales.
validate_chain() {
  case "$1" in
    ''|0*|*[!0123456789]*) fail "chain '$1' is not a chain id; use e.g. 11155111" ;;
  esac
  [ "${#1}" -le 18 ] || fail "chain '$1' is not a chain id; use e.g. 11155111"
}

# chain_setting <chain id> <chainId|name|explorerUrl|rpcUrl>: the value from chains.json (rpcUrl: or the CHAIN_<id>_RPC_URL override).
# chain_config.py prints its own `error:` line and exits non-zero on an unknown chain, a bad file, or a CHAINS_FILE
# set without LOCAL_CHAINS_OK=1 (test-only; the local flow and the tests opt in, a real release must read chains.json).
chain_setting() {
  validate_chain "$1"
  python3 "$SCRIPT_DIR/chain_config.py" get "$1" "$2"
}

# chain_list: prints $CHAINS after checking that every entry is a chain id and none is repeated.
chain_list() {
  need CHAINS
  seen=" "
  for c in $CHAINS; do
    validate_chain "$c"
    case "$seen" in *" $c "*) fail "chain $c is listed more than once in CHAINS" ;; esac
    seen="$seen$c "
  done
  echo "$CHAINS"
}

# chain_label <chain id>: "chain 11155111 (Ethereum Sepolia)", or "chain 11155111" when the chain has no display name.
chain_label() {
  name="$(chain_setting "$1" name)"
  echo "chain $1${name:+ ($name)}"
}

# chain_values <field>: comma-separated chain_setting values over $CHAINS
chain_values() {
  chains="$(chain_list)"
  out=""
  for c in $chains; do
    v="$(chain_setting "$c" "$1")"
    out="${out:+$out,}$v"
  done
  echo "$out"
}

# export_chain_env: exports CHAIN_<id>_RPC_URL (resolved) and CHAIN_<id>_ID for every chain in $CHAINS. Forge scripts and
# the fork test read them by name from the environment, so no URL ever appears in a command line or a forge trace.
export_chain_env() {
  chains="$(chain_list)"
  for c in $chains; do
    rpc="$(chain_setting "$c" rpcUrl)"; id="$(chain_setting "$c" chainId)"
    export "CHAIN_${c}_RPC_URL=$rpc" "CHAIN_${c}_ID=$id"
  done
}

# rpc_var_names: [CHAIN_<id>_RPC_URL,...], the names export_chain_env sets.
rpc_var_names() {
  chains="$(chain_list)"
  out=""
  for c in $chains; do
    out="${out:+$out,}CHAIN_${c}_RPC_URL"
  done
  echo "[$out]"
}

# run_hiding_rpc_urls <command...>: runs the command, then prints its combined output with every RPC URL configured for
# $CHAINS replaced by <rpc url hidden>, and returns the command's exit status. Forge echoes the URL in provider errors and
# the URLs may carry a key. The URLs travel to the filter through the environment (never argv) and are matched literally,
# longest first. The output is shown only once the command ends.
run_hiding_rpc_urls() {
  chains="$(chain_list)"; urls=""
  for c in $chains; do urls="${urls}$(chain_setting "$c" rpcUrl)
"; done
  status=0
  output="$("$@" 2>&1)" || status=$?
  printf '%s\n' "$output" | RPC_URLS_TO_HIDE="$urls" python3 -c '
import os, sys
text = sys.stdin.read()
for url in sorted(filter(None, os.environ["RPC_URLS_TO_HIDE"].split("\n")), key=len, reverse=True):
    text = text.replace(url, "<rpc url hidden>")
sys.stdout.write(text)'
  return "$status"
}

# predict_addresses: sets PREDICTED_IMPLEMENTATION and PREDICTED_PROXY from the one PREDICTED line that
# PreflightDeployment.predict() logs. Needs no RPC, so forge's output is safe to print when it fails.
predict_addresses() {
  if ! output="$(forge script script/PreflightDeployment.s.sol --sig 'predict()' 2>&1)"; then
    echo "$output" >&2
    fail "forge could not compute the predicted addresses (output above)"
  fi
  found="$(printf '%s\n' "$output" | sed -n 's/^ *PREDICTED implementation=\(0x[0-9a-fA-F]\{40\}\) proxy=\(0x[0-9a-fA-F]\{40\}\) *$/\1 \2/p')"
  if [ -z "$found" ]; then
    echo "$output" >&2
    fail "forge did not print the PREDICTED line (output above)"
  fi
  set -- $found
  PREDICTED_IMPLEMENTATION="$1"; PREDICTED_PROXY="$2"
}

# require_rpc_chain_id <chain id>: fails unless the chain's RPC reports the configured chain id; prints the id.
# cast's stderr is discarded because a connection error echoes the RPC URL, which may carry a key.
require_rpc_chain_id() {
  rpc="$(chain_setting "$1" rpcUrl)"; expected="$(chain_setting "$1" chainId)"
  actual="$(ETH_RPC_URL="$rpc" cast chain-id 2>/dev/null)" || fail "$(chain_label "$1"): the RPC did not answer chain-id"
  [ "$actual" = "$expected" ] || fail "$(chain_label "$1") reports chain id $actual, expected $expected"
  echo "$actual"
}

cmd_preflight() {
  need OWNER; need SALT_LABEL; need DEPLOYER_ADDRESS
  export_chain_env
  rpc_vars="$(rpc_var_names)"; chain_ids="[$(chain_values chainId)]"
  run_hiding_rpc_urls forge script script/PreflightDeployment.s.sol --sig 'run(string[],uint256[])' "$rpc_vars" "$chain_ids"
}

cmd_deploy() {
  chain="${1:-}"; [ -n "$chain" ] || fail "usage: release.sh deploy <chain id>"
  need OWNER; need SALT_LABEL; need DEPLOYER_ADDRESS; need KEYSTORE_ACCOUNT
  rpc="$(chain_setting "$chain" rpcUrl)"
  require_rpc_chain_id "$chain" > /dev/null
  echo "About to BROADCAST to $(chain_label "$chain")"
  echo "  signer (keystore account): $KEYSTORE_ACCOUNT   deployer address: $DEPLOYER_ADDRESS"
  echo "  owner: $OWNER   salt label: $SALT_LABEL"
  printf "Type the chain id (%s) to continue: " "$chain"
  read -r answer || fail "no confirmation received; nothing was sent"
  [ "$answer" = "$chain" ] || fail "confirmation did not match; nothing was sent"
  # forge script ignores ETH_RPC_URL (cast honours it); FOUNDRY_ETH_RPC_URL keeps the URL out of argv.
  # --skip-simulation --slow: forge's local simulation under-prices contract creation on some chains
  # (the factory's CREATE2 runs out of gas on-chain), so each transaction's gas is estimated by the chain
  # itself, and sent only after the previous one is confirmed so the proxy's estimate sees the implementation.
  FOUNDRY_ETH_RPC_URL="$rpc" forge script script/DeploySoloPostLayer.s.sol \
    --account "$KEYSTORE_ACCOUNT" --sender "$DEPLOYER_ADDRESS" --skip-simulation --slow --broadcast
}

cmd_verify() {
  chain="${1:-}"; [ -n "$chain" ] || fail "usage: release.sh verify <chain id>"
  need OWNER; need SALT_LABEL
  id="$(require_rpc_chain_id "$chain")"
  predict_addresses
  impl="$PREDICTED_IMPLEMENTATION"; proxy="$PREDICTED_PROXY"
  args="$(cast abi-encode 'constructor(address,bytes)' "$impl" "$(cast calldata 'initialize(address)' "$OWNER")")"
  failed=0
  for verifier in sourcify etherscan; do
    if [ "$verifier" = etherscan ] && [ -z "${ETHERSCAN_API_KEY:-}" ]; then
      echo "NOTICE: ETHERSCAN_API_KEY is not set; Etherscan verification skipped"
      continue
    fi
    forge verify-contract "$impl" src/SoloPostLayer.sol:SoloPostLayer \
      --chain "$id" --verifier "$verifier" --watch || { echo "FAILED: implementation on $verifier"; failed=1; }
    forge verify-contract "$proxy" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
      --chain "$id" --verifier "$verifier" --constructor-args "$args" --watch \
      || { echo "FAILED: proxy on $verifier"; failed=1; }
  done
  [ "$failed" = 0 ] || fail "one or more verifications failed (see above)"
}

cmd_check() {
  need OWNER; need SALT_LABEL
  export_chain_env
  rpc_vars="$(rpc_var_names)"; chain_ids="[$(chain_values chainId)]"
  run_hiding_rpc_urls forge script script/CheckDeployment.s.sol --sig 'run(string[],uint256[])' "$rpc_vars" "$chain_ids"
}

# Traces are off (-vv) because forge traces would print the RPC URL.
cmd_fork_test() {
  export_chain_env
  RELEASE_FORK_TEST=1 forge test --match-path 'test/fork/*' -vv
}

case "${1:-}" in
  preflight) cmd_preflight ;;
  deploy) shift; cmd_deploy "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  check) cmd_check ;;
  fork-test) cmd_fork_test ;;
  *) fail "usage: release.sh <preflight|deploy <chain id>|verify <chain id>|check|fork-test>" ;;
esac
