#!/usr/bin/env python3
"""Write deployments/<RELEASE_NAME>.json (see .env.example for the variables).

Chain id, display name, explorer and RPC URL of each chain come from chains.json (see chain_config.py), keyed by chain
id; CHAIN_<chain id>_RPC_URL in the environment overrides the RPC URL.

Read back from the chains: the chain id, the proxy owner, the ERC-1967 implementation slot and the code hashes
of the implementation and the proxy.
Taken from this checkout, not from the chains: the deploy transaction list (the forge broadcast file under
broadcast/, which must be the original deploy's, and which is only cross-checked against the predicted
addresses), the git commit and tree state, the build settings in foundry.toml, and the predicted addresses.
RPC URLs are only passed to child processes through the environment and never reach the manifest, stdout or an
argument list.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import chain_config

DEPLOY_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
RELEASE_NAME = re.compile(r"[a-z0-9][a-z0-9._-]*")


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def need(name):
    value = os.environ.get(name, "")
    if not value:
        fail(f"{name} is not set")
    return value


def run(command, env=None, secrets=()):
    """Run a command and return stripped stdout; error text has any secret value masked."""
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        detail = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
        for secret in secrets:
            detail = detail.replace(secret, "<redacted>")
        fail(f"'{' '.join(command[:2])}' failed (exit status {result.returncode}):\n{detail}")
    return result.stdout.strip()


def chain_setting(chain, field):
    try:
        return chain_config.get(chain, field)
    except chain_config.ConfigError as error:
        fail(str(error))


def chain_label(chain):
    """'chain 11155111 (Ethereum Sepolia)', or 'chain 11155111' when the chain has no display name."""
    name = chain_setting(chain, "name")
    return f"chain {chain} ({name})" if name else f"chain {chain}"


def cast(args, rpc_url):
    env = {**os.environ, "ETH_RPC_URL": rpc_url}
    return run(["cast", *args], env=env, secrets=(rpc_url,))


PREDICTED_LINE = re.compile(
    r"^\s*PREDICTED implementation=(0x[0-9a-fA-F]{40}) proxy=(0x[0-9a-fA-F]{40})\s*$", re.MULTILINE
)


def predicted_addresses():
    output = run(["forge", "script", "script/PreflightDeployment.s.sol", "--sig", "predict()"])
    match = PREDICTED_LINE.search(output)
    if not match:
        fail(f"forge did not print the PREDICTED line; output was:\n{output}")
    return match.group(1), match.group(2)


def foundry_default_profile():
    text = Path("foundry.toml").read_text()
    block = re.split(r"^\[(?!profile\.default\])", text.split("[profile.default]", 1)[-1], maxsplit=1, flags=re.MULTILINE)[0]

    def setting(key, pattern):
        match = re.search(rf"^\s*{key}\s*=\s*{pattern}\s*(?:#.*)?$", block, re.MULTILINE)
        if not match:
            fail(f"{key} not found in the default profile of foundry.toml")
        return match.group(1)

    return {
        "solc": setting("solc_version", r'"([^"]+)"'),
        "evmVersion": setting("evm_version", r'"([^"]+)"'),
        "optimizerRuns": int(setting("optimizer_runs", r"(\d+)")),
        "bytecodeHash": setting("bytecode_hash", r'"([^"]+)"'),
    }


def deploy_transactions(chain_id, implementation, proxy):
    """Return the deploy transactions from the original broadcast file, after checking they really deployed."""
    path = Path("broadcast/DeploySoloPostLayer.s.sol") / str(chain_id) / "run-latest.json"
    if not path.is_file():
        fail(
            f"{path} not found. Keep the broadcast file of the original deploy; a re-run of the deploy skips "
            "contracts that already exist and records no creation transactions"
        )
    data = json.loads(path.read_text())
    transactions = data.get("transactions", [])
    if not transactions:
        fail(f"{path} has no transactions; it is not the original deploy's broadcast file")
    receipts = {r["transactionHash"]: r for r in data.get("receipts", [])}
    created = set()
    result = []
    for tx in transactions:
        tx_hash = tx.get("hash")
        receipt = receipts.get(tx_hash)
        if receipt is None:
            fail(f"broadcast transaction {tx_hash} on chain {chain_id} has no receipt")
        if receipt.get("status") != "0x1":
            fail(f"broadcast transaction {tx_hash} on chain {chain_id} did not succeed (status {receipt.get('status')})")
        created.add((tx.get("contractAddress") or "").lower())
        created.add((receipt.get("contractAddress") or "").lower())
        created.update((extra.get("address") or "").lower() for extra in tx.get("additionalContracts", []))
        result.append({"hash": tx_hash, "blockNumber": int(receipt["blockNumber"], 16)})
    for label, address in (("implementation", implementation), ("proxy", proxy)):
        if address.lower() not in created:
            fail(f"the broadcast on chain {chain_id} did not create the predicted {label} {address}")
    return result


def code_hash(address, rpc_url, label):
    code = cast(["code", address], rpc_url)
    if code in ("", "0x"):
        fail(f"{label} has no code at {address}")
    return run(["cast", "keccak", code])


def inspect_chain(chain_id, owner, implementation, proxy):
    label = chain_label(chain_id)
    rpc_url = chain_setting(chain_id, "rpcUrl")
    expected_id = chain_setting(chain_id, "chainId")
    actual_id = cast(["chain-id"], rpc_url)
    if actual_id != expected_id:
        fail(f"{label} reports chain id {actual_id}, expected {expected_id}")

    actual_owner = cast(["call", proxy, "owner()(address)"], rpc_url)
    if actual_owner.lower() != owner.lower():
        fail(f"{label}: proxy owner is {actual_owner}, expected {owner}")
    stored = cast(["storage", proxy, IMPLEMENTATION_SLOT], rpc_url)
    actual_impl = "0x" + stored[-40:]
    if actual_impl.lower() != implementation.lower():
        fail(f"{label}: proxy points at {actual_impl}, expected {implementation}")

    chain = {
        "chainId": int(actual_id),
        "owner": actual_owner,
        "implementationCodeHash": code_hash(implementation, rpc_url, f"{label} implementation"),
        "proxyCodeHash": code_hash(proxy, rpc_url, f"{label} proxy"),
        "deployTransactions": deploy_transactions(actual_id, implementation, proxy),
    }
    name = chain_setting(chain_id, "name")
    if name:
        chain["name"] = name
    explorer = chain_setting(chain_id, "explorerUrl").rstrip("/")
    chain["explorer"] = {
        "implementation": f"{explorer}/address/{implementation}",
        "proxy": f"{explorer}/address/{proxy}",
    }
    return chain


def git_state():
    commit = run(["git", "-c", "safe.directory=/workspace", "rev-parse", "HEAD"])
    status = run(["git", "-c", "safe.directory=/workspace", "status", "--porcelain"])
    return commit, status == ""


def main():
    chains = need("CHAINS").split()
    for chain_id in chains:
        try:
            chain_config.require_chain_id(chain_id)
        except chain_config.ConfigError as error:
            fail(str(error))
    for chain_id in dict.fromkeys(chains):
        if chains.count(chain_id) > 1:
            fail(f"chain {chain_id} is listed more than once in CHAINS")
    owner = need("OWNER")
    salt_label = need("SALT_LABEL")
    release = need("RELEASE_NAME")
    if not RELEASE_NAME.fullmatch(release):
        fail(f"invalid RELEASE_NAME '{release}' (lowercase letters, digits, '-', '.', '_'; must not start with '.' or '-')")

    target = Path(os.environ.get("MANIFEST_DIR") or "deployments") / f"{release}.json"
    if target.exists():
        fail(f"{target} already exists; refusing to overwrite")

    for chain_id in chains:
        chain_setting(chain_id, "chainId")  # fail on a refused, unreadable or invalid chain file before any tool runs

    implementation, proxy = predicted_addresses()
    commit, clean = git_state()
    manifest = {
        "release": release,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "gitCommit": commit,
        "gitTreeClean": clean,
        **foundry_default_profile(),
        "factory": DEPLOY_FACTORY,
        "saltLabel": salt_label,
        "owner": owner,
        "implementation": implementation,
        "proxy": proxy,
        "chains": {chain_id: inspect_chain(chain_id, owner, implementation, proxy) for chain_id in chains},
    }

    if not clean:
        print("warning: the git working tree is not clean; the manifest records gitTreeClean=false", file=sys.stderr)
    write_new_file(target, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {target}")


def write_new_file(target, text):
    """Write `text` to a temporary file and link it into place; fails if `target` exists, never leaves a partial file."""
    target.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile("w", dir=target.parent, prefix=f".{target.name}.", suffix=".tmp", delete=False)
    try:
        with handle:
            handle.write(text)
        try:
            os.link(handle.name, target)
        except FileExistsError:
            fail(f"{target} already exists; refusing to overwrite")
    finally:
        os.unlink(handle.name)


if __name__ == "__main__":
    main()
