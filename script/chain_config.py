#!/usr/bin/env python3
"""Chain settings for the release tooling.

chains.json (repo root; $CHAINS_FILE swaps it only together with LOCAL_CHAINS_OK=1, for the local flow and tests) holds the public, non-secret data of every chain:
    { "<chain id>": { "chainId": <int, equal to the key>, "name": "<display name, optional>",
                      "explorerUrl": "<url>", "rpcUrl": "<public url>" } }
The chain id is the only identifier; `name` is for messages only. The RPC URL can be replaced per chain with the
environment variable CHAIN_<chain id>_RPC_URL, for a private or paid endpoint. The file must never hold a key, so a URL with credentials, a query string or a fragment
(rpcUrl also: ';' params) is rejected, as is any whitespace or control character in a URL.

    chain_config.py get <chain id> <chainId|name|explorerUrl|rpcUrl>

Error messages never contain a URL taken from the environment.
"""
import json
import os
import re
import sys
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

CHAIN_ID = re.compile(r"[1-9][0-9]{0,17}")  # explicit digits: \d would also match non-ASCII digits
DISPLAY_NAME = re.compile(r"[A-Za-z0-9 _.-]{1,40}")
REQUIRED_FIELDS = ("chainId", "explorerUrl", "rpcUrl")
FIELDS = ("chainId", "name", "explorerUrl", "rpcUrl")
DEFAULT_FILE = Path(__file__).resolve().parent.parent / "chains.json"


class ConfigError(Exception):
    pass


def chains_file(environ):
    """The chain file to read: chains.json, or $CHAINS_FILE when the local flow or a test opted in with LOCAL_CHAINS_OK=1."""
    override = environ.get("CHAINS_FILE")
    if not override:
        return DEFAULT_FILE
    if environ.get("LOCAL_CHAINS_OK") != "1":
        raise ConfigError(
            "CHAINS_FILE is test-only and is refused in a real release; unset it (check .env) so chains.json is used"
        )
    return Path(override)


def _http_url(value):
    """Return the parsed URL if `value` is an http(s) URL with a host and no whitespace or control character, else None."""
    if not isinstance(value, str) or any(c.isspace() or unicodedata.category(c) == "Cc" for c in value):
        return None
    try:
        parts = urlsplit(value)
        parts.port  # raises ValueError for a malformed port
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    return parts


def _carries_secret(value, parts):
    """True if the URL has credentials, a query string or a fragment (even an empty `?` or `#`)."""
    return parts.username is not None or parts.password is not None or "?" in value or "#" in value


def require_chain_id(chain):
    """Return `chain` if it is a chain id (digits, no leading zero, at most 18); a chain name is refused with a hint."""
    if not CHAIN_ID.fullmatch(chain):
        raise ConfigError(f"chain '{chain}' is not a chain id; use e.g. 11155111")
    return chain


def _validate_entry(chain_id, entry):
    require_chain_id(chain_id)
    if not isinstance(entry, dict):
        raise ConfigError(f"chain '{chain_id}' must be an object")
    missing = [field for field in REQUIRED_FIELDS if field not in entry]
    unknown = [field for field in entry if field not in FIELDS]
    if missing:
        raise ConfigError(f"chain '{chain_id}' is missing {', '.join(missing)}")
    if unknown:
        raise ConfigError(f"chain '{chain_id}' has unknown field(s) {', '.join(unknown)}")
    declared_id = entry["chainId"]
    if isinstance(declared_id, bool) or not isinstance(declared_id, int) or declared_id <= 0:
        raise ConfigError(f"chain '{chain_id}': chainId must be a positive integer")
    if str(declared_id) != chain_id:
        raise ConfigError(f"chain '{chain_id}': chainId must equal its key, found {declared_id}")
    if "name" in entry and not (isinstance(entry["name"], str) and DISPLAY_NAME.fullmatch(entry["name"])):
        raise ConfigError(f"chain '{chain_id}': name must be 1-40 letters, digits, spaces, '_', '.' or '-'")
    explorer = _http_url(entry["explorerUrl"])
    if explorer is None:
        raise ConfigError(f"chain '{chain_id}': explorerUrl must be an http(s) URL without whitespace")
    if _carries_secret(entry["explorerUrl"], explorer):
        raise ConfigError(f"chain '{chain_id}': explorerUrl must not contain credentials, a query string or a fragment")
    rpc = _http_url(entry["rpcUrl"])
    if rpc is None:
        raise ConfigError(f"chain '{chain_id}': rpcUrl must be an http(s) URL without whitespace")
    if _carries_secret(entry["rpcUrl"], rpc) or ";" in entry["rpcUrl"]:
        raise ConfigError(
            f"chain '{chain_id}': rpcUrl must not contain credentials, a query string, a fragment or ';' params; "
            f"chains.json is public, set CHAIN_{chain_id}_RPC_URL in .env for a keyed endpoint"
        )


def _reject_repeated_keys(pairs):
    """json object_pairs_hook: a repeated key would silently let the last value win, so refuse it."""
    keys = [key for key, _ in pairs]
    for key in keys:
        if keys.count(key) > 1:
            raise ConfigError(f"repeated key {key!r}")
    return dict(pairs)


def load_chains(path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        raise ConfigError(f"chain file {path} not found") from None
    except (OSError, UnicodeDecodeError):
        raise ConfigError(f"chain file {path} could not be read") from None
    try:
        chains = json.loads(text, object_pairs_hook=_reject_repeated_keys)
    except ValueError:  # JSONDecodeError, and the int-too-large error a huge chainId literal raises
        raise ConfigError(f"chain file {path} is not valid JSON") from None
    except ConfigError as error:
        raise ConfigError(f"chain file {path} has a {error}") from None
    if not isinstance(chains, dict):
        raise ConfigError(f"chain file {path} must be a JSON object keyed by chain id")
    for chain_id, entry in chains.items():
        _validate_entry(chain_id, entry)
    return chains


def get(chain, field, environ=None, path=None):
    """Return `field` of `chain` as text ("" for an absent optional name). rpcUrl is replaced by CHAIN_<chain>_RPC_URL when set and non-empty."""
    environ = os.environ if environ is None else environ
    require_chain_id(chain)
    chains = load_chains(path or chains_file(environ))
    if chain not in chains:
        raise ConfigError(f"unknown chain '{chain}' (known chains: {', '.join(sorted(chains)) or 'none'})")
    if field not in FIELDS:
        raise ConfigError(f"unknown field '{field}' (one of {', '.join(FIELDS)})")
    if field == "rpcUrl":
        variable = f"CHAIN_{chain}_RPC_URL"
        override = environ.get(variable, "")
        if override:
            if _http_url(override) is None:
                raise ConfigError(f"{variable} is not a valid http(s) URL")
            return override
    return str(chains[chain].get(field, ""))


def main(argv):
    if len(argv) != 4 or argv[1] != "get":
        print(f"usage: chain_config.py get <chain id> <{'|'.join(FIELDS)}>", file=sys.stderr)
        return 1
    try:
        print(get(argv[2], argv[3]))
    except ConfigError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
