#!/usr/bin/env python3
"""Checks, from the resolved Compose file, that the `release` service keeps its build state apart from `tools`.

What a release deploys must not be influenced by the `tools` container, which runs third-party code (the upgrade
validator with ffi). So `release` must build into its own output and cache paths outside the workspace, must not read
Python bytecode from the workspace, must not have any mount on or over those paths, and must not mount a named volume
(compiler binaries, RPC cache) that any other service mounts.

Out of scope: `release` still bind-mounts the workspace (sources, lib/, foundry.toml, .git) read-write, shared with
`tools`. This check does not cover it; see docs/AUDIT.md. Release from a fresh clone.

Reads `docker compose --profile tools config --format json` on stdin: `make test-release-isolation`. The resolved
file includes the values of .env, so this script never echoes its input; it prints service and variable names only.
"""
import json
import posixpath
import sys

WORKSPACE = "/workspace"
PATH_VARIABLES = ("FOUNDRY_OUT", "FOUNDRY_CACHE_PATH", "PYTHONPYCACHEPREFIX")


def named_volumes(service):
    return {v["source"] for v in service.get("volumes", []) if v["type"] == "volume"}


def is_within(path, directory):
    return path == directory or path.startswith(directory.rstrip("/") + "/")


def find_problems(config):
    services = config.get("services", {})
    release = services.get("release")
    if release is None:
        return ["the compose file has no `release` service"]
    problems = []
    environment = release.get("environment", {})
    mount_targets = [posixpath.normpath(v["target"]) for v in release.get("volumes", [])]

    for variable in PATH_VARIABLES:
        raw = environment.get(variable, "")
        path = posixpath.normpath(raw) if raw else ""
        if not path.startswith("/") or is_within(path, WORKSPACE):
            problems.append(f"release must set {variable} to an absolute path outside {WORKSPACE}")
            continue
        for target in mount_targets:
            if is_within(path, target) or is_within(target, path):
                problems.append(f"release has a mount on {target}, which holds {variable}")

    if environment.get("PYTHONDONTWRITEBYTECODE") != "1":
        problems.append("release must set PYTHONDONTWRITEBYTECODE=1")

    release_volumes = named_volumes(release)
    for name, service in services.items():
        if name == "release":
            continue
        shared = release_volumes & named_volumes(service)
        if shared:
            problems.append(f"release shares the named volume(s) {sorted(shared)} with the {name} service")
    return problems


def main(stdin):
    try:
        config = json.load(stdin)
    except json.JSONDecodeError:
        print("error: stdin is not the JSON printed by `docker compose config --format json`", file=sys.stderr)
        return 1
    problems = find_problems(config)
    if problems:
        print("\n".join(f"error: {problem}" for problem in problems), file=sys.stderr)
        return 1
    print("ok   - release builds into its own paths, has no mount on them and shares no named volume with other services")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.stdin))
