#!/usr/bin/env python3
"""Checks that docs/USAGE.md and the README still describe the compiled SoloPostLayer.

    forge inspect SoloPostLayer abi --json | python3 script/check_usage_docs.py

The contract ABI comes on stdin. The check fails (exit 1, one line per problem) when:
- a function in the ABI is missing from the "Function reference" tables, or a table lists one the ABI does not have,
  or its parameter types differ;
- an event in the ABI is missing from the "Events" table, or the table names an unknown event or different fields;
- an error the contract can raise is missing from the "Errors" table (OpenZeppelin plumbing errors are exempt), or the
  table names an unknown error;
- a quoted signature in a command, such as "tipPost(uint256,address,uint256)", does not match the ABI.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
USAGE = ROOT / "docs" / "USAGE.md"
README = ROOT / "README.md"

# Raised by OpenZeppelin code the guide does not describe call by call.
PLUMBING_EVENTS = {"Initialized"}
PLUMBING_ERRORS = {
    "AddressEmptyCode",
    "ERC1967InvalidImplementation",
    "ERC1967NonPayable",
    "FailedCall",
    "InvalidInitialization",
    "NotInitializing",
    "OwnableInvalidOwner",
    "SafeERC20FailedOperation",
    "UUPSUnauthorizedCallContext",
    "UUPSUnsupportedProxiableUUID",
}
# Functions the guide calls on other contracts, so they are not in the SoloPostLayer ABI.
EXTERNAL_FUNCTIONS = {"approve"}

CODE_SPAN = re.compile(r"`([^`]+)`")
CALL = re.compile(r"(\w+)\((.*)\)")
EVENT_FIELD = re.compile(r"`(\w+)`(?: \((indexed)\))?")
ERROR_NAME = re.compile(r"`([A-Z]\w*)(?:\([^`]*\))?`")
QUOTED_SIGNATURE = re.compile(r'"([A-Za-z_]\w*)\(([^()"]*)\)')


def section(text, title):
    """The body of the `## <title>` section of a Markdown file."""
    match = re.search(rf"^## {re.escape(title)}\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    if not match:
        raise SystemExit(f"docs/USAGE.md has no '## {title}' section")
    return match.group(1)


def table_rows(body):
    """The cells of every data row of the Markdown tables in `body` (header and divider rows dropped)."""
    rows = []
    for line in body.splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if set(cells[0]) <= set("-: ") or "`" not in line:
            continue
        rows.append(cells)
    return rows


def param_types(params):
    """Parameter types of a signature's parameter list; each parameter may be followed by a name."""
    return [param.split()[0] for param in params.split(",") if param.strip()]


def check_functions(abi, usage):
    functions = {item["name"]: [i["type"] for i in item["inputs"]] for item in abi if item["type"] == "function"}
    documented = {}
    for cells in table_rows(section(usage, "Function reference")):
        for span in CODE_SPAN.findall(cells[0]):
            call = CALL.fullmatch(span)
            if call:
                documented[call.group(1)] = param_types(call.group(2))
    problems = [f"function {name} is in the ABI but not in the function reference" for name in functions.keys() - documented.keys()]
    problems += [f"function {name} is in the function reference but not in the ABI" for name in documented.keys() - functions.keys()]
    for name in documented.keys() & functions.keys():
        if documented[name] != functions[name]:
            problems.append(f"function {name} takes ({','.join(functions[name])}) but the function reference lists ({','.join(documented[name])})")
    return problems


def check_events(abi, usage):
    events = {item["name"]: [(i["name"], i["indexed"]) for i in item["inputs"]] for item in abi if item["type"] == "event"}
    documented = set()
    problems = []
    for cells in table_rows(section(usage, "Events")):
        fields = [(name, bool(indexed)) for name, indexed in EVENT_FIELD.findall(cells[1])]
        for name in CODE_SPAN.findall(cells[0]):
            documented.add(name)
            if name in events and fields and fields != events[name]:
                problems.append(f"event {name} has fields {events[name]} but the events table lists {fields}")
    problems += [f"event {name} is in the ABI but not in the events table" for name in events.keys() - documented - PLUMBING_EVENTS]
    problems += [f"event {name} is in the events table but not in the ABI" for name in documented - events.keys()]
    return problems


def check_errors(abi, usage):
    errors = {item["name"] for item in abi if item["type"] == "error"}
    documented = {name for cells in table_rows(section(usage, "Errors")) for name in ERROR_NAME.findall(cells[1])}
    problems = [f"error {name} can be raised but is not in the errors table" for name in errors - documented - PLUMBING_ERRORS]
    problems += [f"error {name} is in the errors table but not in the ABI" for name in documented - errors]
    return problems


def check_quoted_signatures(abi, text, source):
    """Every "name(types)" a command passes to cast must match the ABI; events spell out `indexed`."""
    expected = {}
    for item in abi:
        if item["type"] not in ("function", "event", "error"):
            continue
        marks = [i["type"] + (" indexed" if item["type"] == "event" and i["indexed"] else "") for i in item["inputs"]]
        expected[item["name"]] = ",".join(marks)
    problems = []
    for name, params in QUOTED_SIGNATURE.findall(text):
        if name in EXTERNAL_FUNCTIONS:
            continue
        if name not in expected:
            problems.append(f"{source}: command uses \"{name}(...)\", which is not in the ABI")
        elif params.replace(" ", "") != expected[name].replace(" ", ""):
            problems.append(f"{source}: command uses \"{name}({params})\" but the ABI has ({expected[name]})")
    return problems


def check(abi, usage, readme):
    return (
        check_functions(abi, usage)
        + check_events(abi, usage)
        + check_errors(abi, usage)
        + check_quoted_signatures(abi, usage, "docs/USAGE.md")
        + check_quoted_signatures(abi, readme, "README.md")
    )


def main():
    abi = json.load(sys.stdin)
    problems = sorted(check(abi, USAGE.read_text(), README.read_text()))
    if problems:
        print("docs/USAGE.md or README.md no longer match the contract ABI:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("docs/USAGE.md and README.md match the contract ABI")
    return 0


if __name__ == "__main__":
    sys.exit(main())
