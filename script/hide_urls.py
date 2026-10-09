#!/usr/bin/env python3
"""Runs a command and prints its combined output with every URL replaced by <url hidden>; exits with its status.

    hide_urls.py <command> [args...]

Forge echoes the RPC URL in provider errors, and the URL may carry an API key. It prints the URL normalized (host
lowercased, default port dropped), so matching the configured string is not enough; every scheme://... token is hidden.
Output is streamed line by line; stdin stays attached to the command.
"""
import re
import subprocess
import sys

URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>]+")
TRAILING_PUNCTUATION = ").,;]}"


def hide(match):
    url = match.group(0)
    kept = url.rstrip(TRAILING_PUNCTUATION)
    return "<url hidden>" + url[len(kept):]


def main(command):
    if not command:
        print("usage: hide_urls.py <command> [args...]", file=sys.stderr)
        return 2
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except OSError as error:
        print(f"error: cannot run {command[0]}: {error.strerror}")
        return 127
    for line in process.stdout:
        sys.stdout.write(URL.sub(hide, line))
        sys.stdout.flush()
    return process.wait()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
