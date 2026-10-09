#!/bin/sh
# Offline tests for script/release.sh using stub `cast` and `forge` executables on PATH.
# Run: sh test/release_tools/test_release_sh.sh
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
LOG="$WORK/forge.log"
ENV_LOG="$WORK/forge.env"
OUT="$WORK/out"

# Chain data comes from a fixture file, never from the operator's chains.json or .env.
cat > "$WORK/chains.json" <<'JSON'
{
  "84532": {"chainId": 84532, "name": "Base Sepolia", "explorerUrl": "https://explorer.invalid", "rpcUrl": "http://rpc.file.invalid"},
  "11155111": {"chainId": 11155111, "explorerUrl": "https://explorer2.invalid", "rpcUrl": "http://rpc2.file.invalid"}
}
JSON
# Values a developer's shell or .env may carry must not leak into the tests.
unset CHAIN_84532_RPC_URL CHAIN_84532_ID CHAIN_11155111_RPC_URL CHAIN_11155111_ID RELEASE_FORK_TEST

# cast: logs its call to $STUB_LOG; chain-id answers $STUB_CHAIN_ID, or, when STUB_CAST_FAIL is set, exits 1 after
# echoing the RPC URL on stderr the way a real connection error does; every other subcommand answers a dummy value.
cat > "$WORK/bin/cast" <<'STUB'
#!/bin/sh
case "$1" in
  chain-id)
    echo "cast $*" >> "${STUB_LOG:-/dev/null}"
    if [ -n "${STUB_CAST_FAIL:-}" ]; then echo "Error: error sending request for url (${ETH_RPC_URL})" >&2; exit 1; fi
    echo "${STUB_CHAIN_ID:?}" ;;
  *) echo "cast $*" >> "${STUB_LOG:-/dev/null}"; echo 0x00 ;;
esac
STUB

# forge: records every call's arguments in $STUB_LOG and the chain variables it sees in $STUB_ENV_LOG; predict() prints the PREDICTED line, or fails with a marker when STUB_FORGE_FAIL is set.
cat > "$WORK/bin/forge" <<'STUB'
#!/bin/sh
echo "$*" >> "${STUB_LOG:?}"
# STUB_FORGE_ECHO_RPC: echo the configured RPC URLs the way a provider error does; STUB_FORGE_ECHO_FAIL: then exit 1.
if [ -n "${STUB_FORGE_ECHO_RPC:-}" ]; then
  printf 'provider error for %s and %s\n' "${CHAIN_84532_RPC_URL:-}" "${CHAIN_11155111_RPC_URL:-}" >&2
  [ -z "${STUB_FORGE_ECHO_FAIL:-}" ] || exit 1
fi
echo "base_rpc=${CHAIN_84532_RPC_URL:-} base_id=${CHAIN_84532_ID:-} eth_rpc=${CHAIN_11155111_RPC_URL:-} eth_id=${CHAIN_11155111_ID:-} fork=${RELEASE_FORK_TEST:-} foundry_rpc=${FOUNDRY_ETH_RPC_URL:-}" >> "${STUB_ENV_LOG:?}"
case "$*" in
  *"predict()"*)
    if [ -n "${STUB_FORGE_FAIL:-}" ]; then echo "forge boom: compiler exploded"; exit 1; fi
    echo "Script ran successfully."
    echo "== Logs =="
    echo "  Predicted implementation: 0x1111111111111111111111111111111111111111"
    echo "  PREDICTED implementation=0x1111111111111111111111111111111111111111 proxy=0x2222222222222222222222222222222222222222"
    ;;
esac
STUB
chmod +x "$WORK/bin/cast" "$WORK/bin/forge"

# Per-call stub settings, set and restored explicitly (a prefix assignment on a function call is not portable).
with_chain_id() { STUB_CHAIN_ID="$1"; shift; "$@"; STUB_CHAIN_ID=84532; }
with_chains() { TEST_CHAINS="$1"; shift; "$@"; unset TEST_CHAINS; }
with_forge_failing() { STUB_FORGE_FAIL=1; "$@"; unset STUB_FORGE_FAIL; }
with_cast_failing() { STUB_CAST_FAIL=1; "$@"; unset STUB_CAST_FAIL; }

failures=0
checks=0
pass() { checks=$((checks + 1)); echo "ok   - $1"; }
bad() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }

# release <stdin> <args...>: runs release.sh with the stubs; sets STATUS and OUT (stdout+stderr).
release() {
  input="$1"; shift
  : > "$LOG"; : > "$ENV_LOG"
  env PATH="$WORK/bin:$PATH" STUB_LOG="$LOG" STUB_ENV_LOG="$ENV_LOG" CHAINS_FILE="$WORK/chains.json" LOCAL_CHAINS_OK=1 \
    CHAINS="${TEST_CHAINS:-84532}" \
    OWNER=0x00000000000000000000000000000000000000f1 SALT_LABEL=test \
    DEPLOYER_ADDRESS=0x00000000000000000000000000000000000000d1 KEYSTORE_ACCOUNT=testnet \
    ${STUB_CHAIN_ID:+STUB_CHAIN_ID="$STUB_CHAIN_ID"} ${STUB_FORGE_FAIL:+STUB_FORGE_FAIL="$STUB_FORGE_FAIL"} ${STUB_CAST_FAIL:+STUB_CAST_FAIL="$STUB_CAST_FAIL"} \
    ${STUB_FORGE_ECHO_RPC:+STUB_FORGE_ECHO_RPC="$STUB_FORGE_ECHO_RPC"} ${STUB_FORGE_ECHO_FAIL:+STUB_FORGE_ECHO_FAIL="$STUB_FORGE_ECHO_FAIL"} \
    sh "$ROOT/script/release.sh" "$@" > "$OUT" 2>&1 < "$input"
  STATUS=$?
}

expect_failure() { [ "$STATUS" -ne 0 ] && pass "$1 exits non-zero" || bad "$1 exits non-zero"; }
expect_output() { grep -q -- "$2" "$OUT" && pass "$1" || { bad "$1 (missing '$2')"; sed 's/^/     | /' "$OUT"; }; }
expect_no_call() { grep -q -- "$2" "$LOG" && bad "$1 (forge was called with '$2')" || pass "$1"; }
expect_env() { grep -q -- "$2" "$ENV_LOG" && pass "$1" || { bad "$1 (forge env lacks '$2')"; sed 's/^/     | /' "$ENV_LOG"; }; }
expect_call() { grep -q -- "$2" "$LOG" && pass "$1" || bad "$1 (no forge call with '$2')"; }

printf '84532\n' > "$WORK/confirm_ok"
printf 'nope\n' > "$WORK/confirm_wrong"
printf 'Base Sepolia\n' > "$WORK/confirm_name"
: > "$WORK/eof"

export STUB_CHAIN_ID=84532
unset STUB_FORGE_FAIL STUB_CAST_FAIL

# deploy
release "$WORK/confirm_ok" deploy 84532
[ "$STATUS" -eq 0 ] && pass "deploy with the right confirmation succeeds" || bad "deploy with the right confirmation succeeds"
expect_call "deploy with the right confirmation broadcasts" "--broadcast"
# forge's local simulation under-prices contract creation on some chains (gas limit too low, deploy reverts on-chain); gas must come from the chain itself, one transaction at a time.
expect_call "deploy sizes gas with the chain's own estimate, not forge's local simulation" "--skip-simulation"
expect_call "deploy sends one transaction at a time so each estimate sees the previous deploy" "--slow"
# forge script ignores ETH_RPC_URL; only FOUNDRY_ETH_RPC_URL (or --rpc-url, which would put the URL in argv) points it at the chain.
expect_env "deploy gives forge the chain's RPC URL through FOUNDRY_ETH_RPC_URL" "foundry_rpc=http://rpc.file.invalid"
expect_no_call "deploy never passes the RPC URL in argv" "rpc.file.invalid"

expect_output "deploy banner names the chain id and display name" "About to BROADCAST to chain 84532 (Base Sepolia)"
expect_output "deploy asks for the chain id" "Type the chain id (84532) to continue"
printf '11155111\n' > "$WORK/confirm_eth"
with_chain_id 11155111 release "$WORK/confirm_eth" deploy 11155111
[ "$STATUS" -eq 0 ] && pass "deploy to a chain without a display name succeeds" || bad "deploy to a chain without a display name succeeds"
expect_output "deploy banner shows only the id when there is no display name" "About to BROADCAST to chain 11155111$"

with_chain_id 1 release "$WORK/confirm_ok" deploy 84532
expect_failure "deploy on a chain-id mismatch"
expect_output "deploy names the mismatch" "chain 84532 (Base Sepolia) reports chain id 1, expected 84532"
expect_no_call "deploy on a chain-id mismatch never calls forge" "script"

release "$WORK/confirm_name" deploy 84532
expect_failure "deploy confirmed with the display name instead of the chain id"
expect_output "deploy reports the name as a wrong confirmation" "confirmation did not match"
expect_no_call "deploy confirmed with the display name never broadcasts" "--broadcast"

release "$WORK/confirm_wrong" deploy 84532
expect_failure "deploy with a wrong confirmation"
expect_output "deploy reports the wrong confirmation" "confirmation did not match"
expect_no_call "deploy with a wrong confirmation never broadcasts" "--broadcast"

release "$WORK/eof" deploy 84532
expect_failure "deploy on end of input"
expect_output "deploy reports the missing confirmation" "no confirmation received"
expect_no_call "deploy on end of input never broadcasts" "--broadcast"

# verify
release "$WORK/eof" verify 84532
[ "$STATUS" -eq 0 ] && pass "verify succeeds when the chain id matches" || bad "verify succeeds when the chain id matches"
expect_call "verify verifies the predicted implementation" "verify-contract 0x1111111111111111111111111111111111111111"
expect_call "verify verifies the predicted proxy" "verify-contract 0x2222222222222222222222222222222222222222"

with_chain_id 1 release "$WORK/eof" verify 84532
expect_failure "verify on a chain-id mismatch"
expect_output "verify names the mismatch" "reports chain id 1, expected 84532"
expect_no_call "verify on a chain-id mismatch never verifies" "verify-contract"

with_forge_failing release "$WORK/eof" verify 84532
expect_failure "verify when predict fails"
expect_output "verify surfaces forge's output" "forge boom: compiler exploded"
expect_no_call "verify when predict fails never verifies" "verify-contract"

# a failed chain-id read must not leak the RPC URL, whether it comes from chains.json or from the override
for rpc_url in "" "https://rpc.private.invalid/v2/SECRET-KEY"; do
  if [ -n "$rpc_url" ]; then CHAIN_84532_RPC_URL="$rpc_url"; export CHAIN_84532_RPC_URL; fi
  for command in deploy verify; do
    with_cast_failing release "$WORK/confirm_ok" "$command" 84532
    expect_failure "$command when the RPC does not answer chain-id"
    expect_output "$command names the unreachable chain" "chain 84532 (Base Sepolia): the RPC did not answer chain-id"
    for secret in rpc.file.invalid rpc.private.invalid SECRET-KEY "error sending request"; do
      if grep -q -- "$secret" "$OUT"; then bad "$command output must not contain '$secret'"; else pass "$command output does not contain '$secret'"; fi
    done
    expect_no_call "$command when the RPC does not answer never calls forge" "script\|verify-contract"
  done
done
unset CHAIN_84532_RPC_URL

# check passes chain ids next to the RPC variable names
release "$WORK/eof" check
expect_call "check passes the RPC variable names" "\[CHAIN_84532_RPC_URL\]"
expect_call "check passes the chain ids" "CheckDeployment.s.sol --sig run(string\[\],uint256\[\]) \[CHAIN_84532_RPC_URL\] \[84532\]"

release "$WORK/eof" preflight
expect_call "preflight passes the RPC variable names and chain ids" "PreflightDeployment.s.sol --sig run(string\[\],uint256\[\]) \[CHAIN_84532_RPC_URL\] \[84532\]"

# the RPC URL reaches forge through its environment, never its arguments
expect_env "preflight exports the file's RPC URL to forge" "base_rpc=http://rpc.file.invalid "
release "$WORK/eof" check
expect_env "check exports the file's RPC URL to forge" "base_rpc=http://rpc.file.invalid "
expect_no_call "check never puts the RPC URL in forge's arguments" "rpc.file.invalid"

CHAIN_84532_RPC_URL="https://rpc.private.invalid/v2/SECRET-KEY"; export CHAIN_84532_RPC_URL
release "$WORK/eof" preflight
expect_env "a CHAIN_<id>_RPC_URL override replaces the file's URL for forge" "base_rpc=https://rpc.private.invalid/v2/SECRET-KEY "
expect_no_call "an override is never put in forge's arguments" "SECRET-KEY"
release "$WORK/confirm_ok" deploy 84532
[ "$STATUS" -eq 0 ] && pass "deploy works with an override" || bad "deploy works with an override"
if grep -q "SECRET-KEY" "$OUT"; then bad "deploy output must not print the override URL"; else pass "deploy output does not print the override URL"; fi
CHAIN_84532_RPC_URL="not a url SECRET-KEY"
release "$WORK/eof" preflight
expect_failure "an invalid override"
expect_output "an invalid override is named" "CHAIN_84532_RPC_URL"
if grep -q "SECRET-KEY" "$OUT"; then bad "an invalid override is not printed"; else pass "an invalid override is not printed"; fi
expect_no_call "an invalid override never reaches forge" "script"
unset CHAIN_84532_RPC_URL

# several chains: ids are looked up per chain
with_chains "84532 11155111" release "$WORK/eof" check
expect_call "check passes every chain's id in CHAINS order" "\[CHAIN_84532_RPC_URL,CHAIN_11155111_RPC_URL\] \[84532,11155111\]"
expect_env "check exports every chain's RPC URL" "eth_rpc=http://rpc2.file.invalid "

# unknown chains
release "$WORK/confirm_ok" deploy 1
expect_failure "deploy on an unknown chain"
expect_output "deploy lists the known chains" "known chains: 11155111, 84532"
expect_no_call "deploy on an unknown chain never broadcasts" "--broadcast"
with_chains "84532 1" release "$WORK/eof" preflight
expect_failure "preflight with an unknown chain in CHAINS"
expect_output "preflight lists the known chains" "unknown chain '1'"
expect_no_call "preflight with an unknown chain never calls forge" "script"

# preflight and check mask every configured RPC URL in forge's output, on success and on failure
mask_urls() { # mask_urls <url for 84532> [<url for 11155111>]
  CHAIN_84532_RPC_URL="$1"; export CHAIN_84532_RPC_URL
  [ -z "${2:-}" ] || { CHAIN_11155111_RPC_URL="$2"; export CHAIN_11155111_RPC_URL; }
  for command in preflight check; do
    for outcome in success failure; do
      STUB_FORGE_ECHO_RPC=1; [ "$outcome" = failure ] && STUB_FORGE_ECHO_FAIL=1
      with_chains "${3:-84532}" release "$WORK/eof" $command
      unset STUB_FORGE_ECHO_RPC STUB_FORGE_ECHO_FAIL
      if [ "$outcome" = failure ]; then expect_failure "$command masks on failure"; else
        [ "$STATUS" -eq 0 ] && pass "$command masks on success and exits zero" || bad "$command masks on success and exits zero"; fi
      expect_output "$command shows the placeholder for '$1'" "<rpc url hidden>"
      expect_output "$command keeps forge's other text for '$1'" "provider error for"
      for secret in "$1" "${2:-}"; do
        [ -n "$secret" ] || continue
        if grep -qF -- "$secret" "$OUT"; then bad "$command ($outcome) output must not contain '$secret'"; else pass "$command ($outcome) output does not contain '$secret'"; fi
      done
      if grep -q "KEY\|more-secret\|rpc.file.invalid" "$OUT"; then bad "$command ($outcome) output leaks part of a URL"; else pass "$command ($outcome) output leaks no part of a URL"; fi
    done
  done
  unset CHAIN_84532_RPC_URL CHAIN_11155111_RPC_URL
}
mask_urls "http://rpc.file.invalid"
mask_urls 'https://rpc.priv.invalid/v2/KEY.+*[x]&b=1?c=$d\e|f'
mask_urls 'https://rpc.priv.invalid/v2/KEY1' 'https://rpc.priv2.invalid/KEY2/&' "84532 11155111"
# when one URL is a prefix of another, the longer one is masked whole
mask_urls 'https://rpc.priv.invalid/KEY' 'https://rpc.priv.invalid/KEY/more-secret' "84532 11155111"

# a chain id listed twice is refused by every command that reads CHAINS
for command in preflight check fork-test; do
  with_chains "84532 11155111 84532" release "$WORK/eof" $command
  expect_failure "$command with a repeated chain id in CHAINS"
  expect_output "$command names the repeated chain id" "chain 84532 is listed more than once in CHAINS"
  expect_no_call "$command with a repeated chain id never calls forge" "script\|test"
done

# fork-test exports RPC URL and chain id per chain and opts in
release "$WORK/eof" fork-test
[ "$STATUS" -eq 0 ] && pass "fork-test succeeds" || bad "fork-test succeeds"
expect_call "fork-test runs forge test on the fork tests" "test --match-path test/fork/\* -vv"
expect_env "fork-test exports the RPC URL, chain id and opt-in" "base_rpc=http://rpc.file.invalid base_id=84532 eth_rpc= eth_id= fork=1"
with_chains "84532 11155111" release "$WORK/eof" fork-test
expect_env "fork-test exports every chain in CHAINS" "eth_rpc=http://rpc2.file.invalid eth_id=11155111 fork=1"

# invalid chain names
for name in 'Bad' 'ethereum_sepolia' 'base-sepolia' '../x' 'a.b' '0' '007' '84532x' '1234567890123456789'; do
  for command in deploy verify; do
    release "$WORK/confirm_ok" "$command" "$name"
    expect_failure "$command rejects chain '$name'"
    expect_output "$command explains chain '$name'" "chain '$name' is not a chain id; use e.g. 11155111"
    expect_no_call "$command with chain '$name' never broadcasts" "--broadcast"
    expect_no_call "$command with chain '$name' never verifies" "verify-contract"
    expect_no_call "$command with chain '$name' never calls cast" "^cast "
  done
done
# the longest accepted id (18 digits) passes the early guard and reaches the unknown-chain check
release "$WORK/confirm_ok" deploy 123456789012345678
expect_output "an 18-digit chain id passes the guard" "unknown chain '123456789012345678'"
: > "$LOG"
env PATH="$WORK/bin:$PATH" STUB_LOG="$LOG" STUB_ENV_LOG="$ENV_LOG" CHAINS_FILE="$WORK/chains.json" LOCAL_CHAINS_OK=1 CHAINS="84532 Bad-Name" OWNER=0x1 SALT_LABEL=x DEPLOYER_ADDRESS=0x2 \
  sh "$ROOT/script/release.sh" preflight > "$OUT" 2>&1 < /dev/null
STATUS=$?
expect_failure "preflight rejects a non-id in CHAINS"
expect_output "preflight explains the invalid name" "chain 'Bad-Name' is not a chain id"
expect_no_call "preflight with an invalid name never calls forge" "script"

# an old .env still listing chain names fails clearly instead of being accepted
for command in preflight check fork-test; do
  : > "$LOG"
  env PATH="$WORK/bin:$PATH" STUB_LOG="$LOG" STUB_ENV_LOG="$ENV_LOG" CHAINS_FILE="$WORK/chains.json" LOCAL_CHAINS_OK=1 CHAINS="ethereum_sepolia" OWNER=0x1 SALT_LABEL=x DEPLOYER_ADDRESS=0x2 \
    sh "$ROOT/script/release.sh" $command > "$OUT" 2>&1 < /dev/null
  STATUS=$?
  expect_failure "$command with CHAINS=ethereum_sepolia"
  expect_output "$command asks for a chain id" "chain 'ethereum_sepolia' is not a chain id; use e.g. 11155111"
  expect_no_call "$command with a chain name never calls forge" "script\|test"
done

# CHAINS_FILE is test-only: without the explicit local opt-in every command refuses, before any chain is touched
for command in "preflight" "deploy 84532" "verify 84532" "check" "fork-test"; do
  : > "$LOG"
  env PATH="$WORK/bin:$PATH" STUB_LOG="$LOG" STUB_ENV_LOG="$ENV_LOG" STUB_CHAIN_ID=84532 CHAINS_FILE="$WORK/chains.json" CHAINS=84532 \
    OWNER=0x1 SALT_LABEL=x DEPLOYER_ADDRESS=0x2 KEYSTORE_ACCOUNT=a \
    sh "$ROOT/script/release.sh" $command > "$OUT" 2>&1 < "$WORK/confirm_ok"
  STATUS=$?
  expect_failure "release.sh $command with CHAINS_FILE set and no local opt-in"
  expect_output "release.sh $command explains the CHAINS_FILE refusal" "CHAINS_FILE is test-only"
  expect_output "release.sh $command shows an error: line" "^error: "
  expect_no_call "release.sh $command with CHAINS_FILE never calls forge" "script"
  expect_no_call "release.sh $command with CHAINS_FILE never calls cast" "^cast "
done

# make release-*: the .env guard refuses a CHAINS_FILE line, reading .env with grep only
guard_env() { # guard_env <.env content> -> STATUS/OUT of `make require-release-env` run beside that .env
  mkdir -p "$WORK/guard"; printf '%s' "$1" > "$WORK/guard/.env"
  make -s -C "$WORK/guard" -f "$ROOT/Makefile" require-release-env > "$OUT" 2>&1
  STATUS=$?
}
guard_env 'KEYSTORE_DIR=/keys
CHAINS=84532
'
[ "$STATUS" -eq 0 ] && pass "release guard accepts an .env without CHAINS_FILE" || bad "release guard accepts an .env without CHAINS_FILE"
guard_env 'KEYSTORE_DIR=/keys
# CHAINS_FILE=/tmp/x.json
  # LOCAL_CHAINS_OK=1
MY_CHAINS_FILE=x
'
[ "$STATUS" -eq 0 ] && pass "release guard ignores commented lines and similarly named variables" || bad "release guard ignores commented lines and similarly named variables"
# every spelling that sets CHAINS_FILE or LOCAL_CHAINS_OK is refused, even with an empty value
while IFS= read -r line; do
  guard_env "KEYSTORE_DIR=/keys
$line
"
  expect_failure "release guard on the .env line '$line'"
  expect_output "release guard names the variable for '$line'" "CHAINS_FILE\|LOCAL_CHAINS_OK"
done <<'LINES'
CHAINS_FILE=/tmp/x.json
CHAINS_FILE=
export CHAINS_FILE=/tmp/x.json
  CHAINS_FILE=/tmp/x.json
	CHAINS_FILE=/tmp/x.json
CHAINS_FILE: /tmp/x.json
CHAINS_FILE = /tmp/x.json
export   CHAINS_FILE =/tmp/x.json
LOCAL_CHAINS_OK=1
export LOCAL_CHAINS_OK=1
  LOCAL_CHAINS_OK = 1
LOCAL_CHAINS_OK: 1
LINES

# make release-deploy / release-verify: the CHAIN guard accepts chain ids only (RELEASE=echo keeps docker out of it)
chain_target() { # chain_target <target> <chain> -> STATUS/OUT
  mkdir -p "$WORK/guard"; printf 'KEYSTORE_DIR=/keys\n' > "$WORK/guard/.env"
  make -s -C "$WORK/guard" -f "$ROOT/Makefile" RELEASE=echo "$1" CHAIN="$2" > "$OUT" 2>&1
  STATUS=$?
}
for target in release-deploy release-verify; do
  chain_target "$target" 11155111
  [ "$STATUS" -eq 0 ] && pass "make $target accepts a chain id" || bad "make $target accepts a chain id"
  expect_output "make $target passes the chain id on" "script/release.sh .* 11155111"
  chain_target "$target" 123456789012345678
  [ "$STATUS" -eq 0 ] && pass "make $target accepts an 18-digit chain id" || bad "make $target accepts an 18-digit chain id"
  for bad_chain in '' ethereum_sepolia Base 0 007 84532x 1234567890123456789 '1 2' '1;id'; do
    chain_target "$target" "$bad_chain"
    expect_failure "make $target rejects CHAIN='$bad_chain'"
    expect_output "make $target explains CHAIN='$bad_chain'" "CHAIN must be a chain id"
  done
done

echo "$checks checks, $failures failed"
[ "$failures" -eq 0 ]
