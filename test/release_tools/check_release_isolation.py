#!/usr/bin/env python3
"""Checks, from the resolved Compose file, that the `release` service shares no build state with the other tooling.

What a release deploys must not be influenced by the `tools` container, which runs third-party code (the upgrade
validator with ffi). So `release` must build into its own output and cache paths outside the workspace and must not
mount a named volume (compiler binaries, RPC cache) that any other service mounts.

Runs on the host (it needs `docker compose`), not in the tools container: `make test-release-isolation`.
It prints service and volume names only, never environment values, because the resolved file includes .env.
"""
import json
import subprocess
import sys

WORKSPACE = "/workspace"


def named_volumes(service):
    return {v["source"] for v in service.get("volumes", []) if v["type"] == "volume"}


def main():
    resolved = subprocess.run(
        ["docker", "compose", "--profile", "tools", "config", "--format", "json"],
        check=True, capture_output=True, text=True,
    ).stdout
    services = json.loads(resolved)["services"]
    release = services["release"]
    problems = []

    for variable in ("FOUNDRY_OUT", "FOUNDRY_CACHE_PATH"):
        value = release.get("environment", {}).get(variable, "")
        if not value.startswith("/") or value == WORKSPACE or value.startswith(WORKSPACE + "/"):
            problems.append(f"release must set {variable} to an absolute path outside {WORKSPACE}")

    release_volumes = named_volumes(release)
    for name, service in services.items():
        if name == "release":
            continue
        shared = release_volumes & named_volumes(service)
        if shared:
            problems.append(f"release shares the named volume(s) {sorted(shared)} with the {name} service")

    if problems:
        print("\n".join(f"error: {problem}" for problem in problems), file=sys.stderr)
        return 1
    print("ok   - release builds into its own output and cache paths and shares no named volume with other services")
    return 0


if __name__ == "__main__":
    sys.exit(main())
