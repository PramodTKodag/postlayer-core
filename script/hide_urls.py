#!/usr/bin/env python3
"""Runs a command and prints its combined output with every URL replaced by <url hidden>; exits with its status.

    hide_urls.py <command> [args...]

Forge echoes the RPC URL in provider errors, and the URL may carry an API key. It prints the URL normalized (host
lowercased, default port dropped), so matching the configured string is not enough; every scheme://... token is hidden.
A host printed without a scheme is not recognised. Output is streamed line by line and stdin stays attached to the
command. SIGINT and SIGTERM are passed on to the command, and the filter always waits for it, so the command is never
left running unattended. A command ended by a signal gives 128 plus the signal number.
"""
import re
import signal
import subprocess
import sys

URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>]+")
TRAILING_PUNCTUATION = ").,;]}"


def _mask(match):
    url = match.group(0)
    kept = url.rstrip(TRAILING_PUNCTUATION)
    return "<url hidden>" + url[len(kept):]


def hide(text):
    """`text` with every scheme://... URL replaced by <url hidden>."""
    return URL.sub(_mask, text)


def main(command):
    if not command:
        print("usage: hide_urls.py <command> [args...]", file=sys.stderr)
        return 2
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"error: cannot run {command[0]}: {error.strerror}", file=sys.stderr)
        return 127
    for forwarded in (signal.SIGINT, signal.SIGTERM):
        signal.signal(forwarded, lambda number, frame: process.send_signal(number))
    try:
        for line in process.stdout:
            sys.stdout.write(hide(line))
            sys.stdout.flush()
    finally:
        status = process.wait()
    return 128 - status if status < 0 else status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
