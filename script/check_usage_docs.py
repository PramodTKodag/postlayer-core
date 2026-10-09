#!/usr/bin/env python3
"""Checks that docs/USAGE.md and the README still describe the compiled SoloPostLayer.

    forge inspect SoloPostLayer abi --json | python3 script/check_usage_docs.py

The contract ABI comes on stdin. The check fails (exit 1, one line per problem) when:
- a function in the ABI is missing from the "Function reference" tables, or a table lists one the ABI does not have,
  or its parameter types differ;
- an event in the ABI is missing from the "Events" table, or the table names an unknown event or lists different
  fields (type, name, indexed);
- an error the contract can raise is missing from the "Errors" table (OpenZeppelin plumbing errors are exempt), is
  listed without its signature, or the table names an unknown error or different argument types;
- a quoted signature in a command, such as "tipPost(uint256,address,uint256)" or
  "getPost(uint256)((address,bool,...))", does not match the ABI: input types, return types (struct fields included)
  and, for events, the indexed fields.
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
    "UUPSUnauthorizedCallContext",
    "UUPSUnsupportedProxiableUUID",
}
# Events the events table may describe in prose ("standard OpenZeppelin events") instead of listing fields.
EVENTS_WITHOUT_FIELDS = {"OwnershipTransferStarted", "OwnershipTransferred", "Upgraded"}
# Functions the guide calls on other contracts, so they are not in the SoloPostLayer ABI.
EXTERNAL_FUNCTIONS = {"approve": "address,uint256"}

ABI_HINT = "expected the contract ABI as a JSON list on stdin, for example: forge inspect SoloPostLayer abi --json | python3 script/check_usage_docs.py"
CODE_SPAN = re.compile(r"`([^`]+)`")
CALL = re.compile(r"(\w+)\((.*)\)")
EVENT_FIELD = re.compile(r"`(\w+(?:\[\])?) (\w+)`(?: \((indexed)\))?")
SIGNATURE_START = re.compile(r"""(["'])([A-Za-z_]\w*)\(""")


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
        if len(cells) < 2:
            raise SystemExit(f"docs/USAGE.md has a table row with one cell: {line}")
        rows.append(cells)
    return rows


def split_top_level(text):
    """Splits a comma separated list, leaving the commas inside parentheses alone."""
    parts, depth, current = [], 0, ""
    for char in text:
        depth += (char == "(") - (char == ")")
        if char == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += char
    if current.strip():
        parts.append(current)
    return [part.strip() for part in parts]


def canonical_type(item):
    """The type of an ABI parameter as cast spells it: a struct is a parenthesised list of its fields."""
    if item["type"].startswith("tuple"):
        return "(" + ",".join(canonical_type(part) for part in item["components"]) + ")" + item["type"][len("tuple") :]
    return item["type"]


def param_types(params):
    """Types of a documented parameter list; each parameter may be followed by a name, `(address,uint256) config`."""
    return [re.sub(r"\s+\w+$", "", param) if param.startswith("(") else param.split(" ")[0] for param in split_top_level(params)]


def join(types):
    return ",".join(types)


def check_functions(abi, usage):
    functions = {item["name"]: [canonical_type(i) for i in item["inputs"]] for item in abi if item["type"] == "function"}
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
            problems.append(f"function {name} takes ({join(functions[name])}) but the function reference lists ({join(documented[name])})")
    return problems


def check_events(abi, usage):
    events = {
        item["name"]: [(canonical_type(i), i["name"], i["indexed"]) for i in item["inputs"]] for item in abi if item["type"] == "event"
    }
    documented = set()
    problems = []
    for cells in table_rows(section(usage, "Events")):
        fields = [(type_, name, bool(indexed)) for type_, name, indexed in EVENT_FIELD.findall(cells[1])]
        for name in CODE_SPAN.findall(cells[0]):
            documented.add(name)
            if name not in events:
                continue
            if not fields and name not in EVENTS_WITHOUT_FIELDS:
                problems.append(f"event {name} lists no fields in the events table")
            elif fields and fields != events[name]:
                problems.append(f"event {name} has fields {events[name]} but the events table lists {fields}")
    problems += [f"event {name} is in the ABI but not in the events table" for name in events.keys() - documented - PLUMBING_EVENTS]
    problems += [f"event {name} is in the events table but not in the ABI" for name in documented - events.keys()]
    return problems


def check_errors(abi, usage):
    errors = {item["name"]: [canonical_type(i) for i in item["inputs"]] for item in abi if item["type"] == "error"}
    documented = {}
    problems = []
    for cells in table_rows(section(usage, "Errors")):
        for span in CODE_SPAN.findall(cells[1]):
            if not span[0].isupper():
                continue
            call = CALL.fullmatch(span)
            if call:
                documented[call.group(1)] = param_types(call.group(2))
            else:
                documented[span] = None
                problems.append(f"error {span} is listed without its signature, for example {span}(address token)")
    problems += [f"error {name} can be raised but is not in the errors table" for name in errors.keys() - documented.keys() - PLUMBING_ERRORS]
    problems += [f"error {name} is in the errors table but not in the ABI" for name in documented.keys() - errors.keys()]
    for name in documented.keys() & errors.keys():
        if documented[name] is not None and documented[name] != errors[name]:
            problems.append(f"error {name} takes ({join(errors[name])}) but the errors table lists ({join(documented[name])})")
    return problems


def balanced(text, start):
    """The text inside the parentheses that open at text[start], and the index after the closing one; None if unclosed."""
    depth = 0
    for index in range(start, len(text)):
        depth += (text[index] == "(") - (text[index] == ")")
        if depth == 0:
            return text[start + 1 : index], index + 1
    return None


def expected_signatures(abi):
    """name -> (input types, output types or None) as cast spells them; events mark indexed fields."""
    expected = {}
    for item in abi:
        if item["type"] not in ("function", "event", "error"):
            continue
        marks = [canonical_type(i) + (" indexed" if item["type"] == "event" and i["indexed"] else "") for i in item["inputs"]]
        outputs = [canonical_type(o) for o in item["outputs"]] if item["type"] == "function" else None
        expected[item["name"]] = (join(marks), outputs)
    return expected


def check_quoted_signatures(abi, text, source):
    """Every "name(types)" or "name(types)(returns)" a command passes to cast must match the ABI."""
    expected = expected_signatures(abi)
    problems = []
    for match in SIGNATURE_START.finditer(text):
        quote, name = match.group(1), match.group(2)
        inputs = balanced(text, match.end() - 1)
        outputs, end = None, None
        if inputs:
            params, end = inputs
            if text.startswith("(", end):
                grouped = balanced(text, end)
                if grouped:
                    outputs, end = grouped
        if not inputs or text[end : end + 1] != quote:
            problems.append(f"{source}: cannot parse the signature that starts with {quote}{name}(")
            continue
        if name in EXTERNAL_FUNCTIONS:
            wanted_inputs, wanted_outputs = EXTERNAL_FUNCTIONS[name], None
        elif name in expected:
            wanted_inputs, wanted_outputs = expected[name]
        else:
            problems.append(f"{source}: command uses {quote}{name}(...){quote}, which is not in the ABI")
            continue
        if params.replace(" ", "") != wanted_inputs.replace(" ", ""):
            problems.append(f"{source}: command uses {quote}{name}({params}){quote} but the ABI has ({wanted_inputs})")
        elif outputs is not None and wanted_outputs is not None and outputs.replace(" ", "") != join(wanted_outputs):
            problems.append(f"{source}: command for {name} returns ({outputs}) but the ABI has ({join(wanted_outputs)})")
    return problems


def check(abi, usage, readme):
    return (
        check_functions(abi, usage)
        + check_events(abi, usage)
        + check_errors(abi, usage)
        + check_quoted_signatures(abi, usage, "docs/USAGE.md")
        + check_quoted_signatures(abi, readme, "README.md")
    )


def load_abi(stream):
    try:
        abi = json.load(stream)
    except json.JSONDecodeError:
        raise SystemExit(ABI_HINT)
    if not isinstance(abi, list) or not abi:
        raise SystemExit(ABI_HINT)
    return abi


def main(stdin=None, usage=USAGE, readme=README):
    abi = load_abi(stdin or sys.stdin)
    problems = sorted(check(abi, usage.read_text(), readme.read_text()))
    if problems:
        print("docs/USAGE.md or README.md no longer match the contract ABI:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print("docs/USAGE.md and README.md match the contract ABI")
    return 0


if __name__ == "__main__":
    sys.exit(main())
