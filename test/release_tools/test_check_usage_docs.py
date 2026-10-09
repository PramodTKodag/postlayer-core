"""Offline tests for script/check_usage_docs.py. Run: python3 -m unittest discover -s test/release_tools"""
import contextlib
import copy
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_usage_docs", ROOT / "script" / "check_usage_docs.py")
check_usage_docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_usage_docs)


def param(type_, name="", indexed=None, components=None):
    item = {"type": type_, "name": name}
    if indexed is not None:
        item["indexed"] = indexed
    if components is not None:
        item["components"] = components
    return item


def function(name, inputs=(), outputs=()):
    return {"type": "function", "name": name, "inputs": list(inputs), "outputs": list(outputs)}


def event(name, inputs):
    return {"type": "event", "name": name, "inputs": inputs}


def error(name, inputs=()):
    return {"type": "error", "name": name, "inputs": list(inputs)}


POST = param("tuple", components=[param("address", "author"), param("bool", "hidden")])

ABI = [
    {"type": "constructor", "inputs": []},
    function("likePost", [param("uint256", "postId")]),
    function("owner", outputs=[param("address")]),
    function("pendingOwner", outputs=[param("address")]),
    function("postCount", outputs=[param("uint256")]),
    function("getPost", [param("uint256", "postId")], [POST]),
    event("PostHidden", [param("uint256", "postId", True)]),
    event("PostUnhidden", [param("uint256", "postId", True)]),
    event("PostTipped", [param("uint256", "postId", True), param("uint256", "amount", False)]),
    event("OwnershipTransferred", [param("address", "previousOwner", True), param("address", "newOwner", True)]),
    event("Initialized", [param("uint64", "version", False)]),
    error("AlreadyLiked", [param("uint256", "postId"), param("address", "liker")]),
    error("TokenNotAllowed", [param("address", "token")]),
    error("EmptyContentUri"),
    error("NotInitializing"),
]

USAGE = """# Using

## Function reference

| Function | Who |
|---|---|
| `likePost(uint256 postId)` | anyone |
| `owner()` / `pendingOwner()` | anyone |
| `postCount()` returns `uint256` | anyone |
| `getPost(uint256 postId)` returns `Post` | anyone |

## Events

| Event | Fields |
|---|---|
| `PostHidden`, `PostUnhidden` | `uint256 postId` (indexed) |
| `PostTipped` | `uint256 postId` (indexed), `uint256 amount` |
| `OwnershipTransferred` | standard OpenZeppelin event |

```sh
cast logs "PostTipped(uint256 indexed,uint256)"
cast send $PROXY "likePost(uint256)"
cast call $PROXY "postCount()(uint256)"
cast call $PROXY "getPost(uint256)((address,bool))" 1
cast send $TOKEN 'approve(address,uint256)'
cast decode-error $DATA --sig "AlreadyLiked(uint256,address)"
```

## Errors

| Function | Reverts with |
|---|---|
| `likePost` | `AlreadyLiked(uint256 postId, address liker)` |
| `tipPost` | `TokenNotAllowed(address token)`, `EmptyContentUri()` |
| any function taking a `postId` | see `postCount()` |

## Last
"""
README = 'cast send $PROXY "likePost(uint256)"\n'


def problems(usage=USAGE, readme=README, abi=ABI):
    return check_usage_docs.check(abi, usage, readme)


def without(abi, kind, name):
    return [item for item in abi if not (item["type"] == kind and item["name"] == name)]


class CheckUsageDocsCase(unittest.TestCase):
    def assertOneProblem(self, found, fragment):
        self.assertEqual(len(found), 1, found)
        self.assertIn(fragment, found[0])

    def test_matching_docs_pass(self):
        self.assertEqual(problems(), [])

    def test_function_missing_from_docs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("| `postCount()` returns `uint256` | anyone |\n", "")), "postCount is in the ABI but not in the function reference")

    def test_second_function_in_one_cell_is_checked(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`owner()` / `pendingOwner()`", "`owner()`")), "pendingOwner is in the ABI but not in the function reference")

    def test_function_unknown_to_abi(self):
        found = problems(abi=without(ABI, "function", "postCount"))
        self.assertEqual(len(found), 2, found)  # the function reference and the command that calls it
        self.assertIn("postCount is in the function reference but not in the ABI", found[0])

    def test_function_parameter_type_differs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("likePost(uint256 postId)", "likePost(address postId)")), "likePost takes (uint256)")

    def test_event_missing_from_docs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("| `PostTipped` | `uint256 postId` (indexed), `uint256 amount` |\n", "")), "PostTipped is in the ABI but not in the events table")

    def test_second_event_in_one_row_is_checked(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`PostHidden`, `PostUnhidden`", "`PostHidden`")), "PostUnhidden is in the ABI but not in the events table")

    def test_event_unknown_to_abi(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`PostHidden`,", "`PostHidden`, `PostShared`,")), "PostShared is in the events table but not in the ABI")

    def test_event_indexed_flag_differs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`uint256 postId` (indexed), `uint256 amount`", "`uint256 postId`, `uint256 amount`")), "event PostTipped has fields")

    def test_event_field_type_differs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`uint256 amount`", "`uint128 amount`")), "event PostTipped has fields")

    def test_event_fields_replaced_by_prose_are_flagged(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`uint256 postId` (indexed), `uint256 amount`", "the tip")), "event PostTipped lists no fields")

    def test_listed_open_zeppelin_event_needs_no_fields(self):
        self.assertEqual(problems(), [])  # OwnershipTransferred has prose only

    def test_open_zeppelin_event_exemption_is_explicit(self):
        with mock.patch.object(check_usage_docs, "EVENTS_WITHOUT_FIELDS", set()):
            self.assertOneProblem(problems(), "event OwnershipTransferred lists no fields")

    def test_plumbing_event_exemption_is_explicit(self):
        with mock.patch.object(check_usage_docs, "PLUMBING_EVENTS", set()):
            self.assertOneProblem(problems(), "Initialized is in the ABI but not in the events table")

    def test_plumbing_error_exemption_is_explicit(self):
        with mock.patch.object(check_usage_docs, "PLUMBING_ERRORS", set()):
            self.assertOneProblem(problems(), "NotInitializing can be raised")

    def test_error_missing_from_docs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`TokenNotAllowed(address token)`, ", "")), "TokenNotAllowed can be raised but is not in the errors table")

    def test_error_unknown_to_abi(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`EmptyContentUri()`", "`EmptyContentUri()`, `Gone()`")), "Gone is in the errors table but not in the ABI")

    def test_error_listed_without_its_signature(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`TokenNotAllowed(address token)`", "`TokenNotAllowed`")), "error TokenNotAllowed is listed without its signature")

    def test_error_argument_type_differs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`TokenNotAllowed(address token)`", "`TokenNotAllowed(uint256 token)`")), "error TokenNotAllowed takes (address)")

    def test_lowercase_code_in_errors_table_is_not_an_error_name(self):
        self.assertEqual(problems(usage=USAGE.replace("see `postCount()`", "see `postCount()`, `hasLiked(uint256 postId, address account)`")), [])

    def test_command_signature_with_wrong_types(self):
        self.assertOneProblem(problems(readme='cast send $PROXY "likePost(address)"\n'), 'README.md: command uses "likePost(address)"')

    def test_command_signature_for_unknown_function(self):
        self.assertOneProblem(problems(readme='cast send $PROXY "sharePost(uint256)"\n'), "sharePost")

    def test_single_quoted_signature_is_checked(self):
        self.assertOneProblem(problems(readme="cast send $PROXY 'likePost(address)'\n"), "likePost(address)")

    def test_event_command_must_spell_out_indexed(self):
        self.assertOneProblem(problems(usage=USAGE.replace("PostTipped(uint256 indexed,uint256)", "PostTipped(uint256,uint256)")), "PostTipped")

    def test_error_command_signature_is_checked(self):
        self.assertOneProblem(problems(usage=USAGE.replace('"AlreadyLiked(uint256,address)"', '"AlreadyLiked(uint256)"')), "AlreadyLiked")

    def test_return_types_are_checked(self):
        self.assertOneProblem(problems(readme='cast call $PROXY "postCount()(uint128)"\n'), 'returns (uint128) but the ABI has (uint256)')

    def test_return_tuple_field_is_checked(self):
        self.assertOneProblem(problems(readme='cast call $PROXY "getPost(uint256)((address,uint8))"\n'), "getPost")

    def test_return_tuple_with_an_extra_field_is_flagged(self):
        abi = copy.deepcopy(ABI)
        get_post = next(item for item in abi if item.get("name") == "getPost")
        get_post["outputs"][0]["components"].append(param("string", "contentUri"))
        self.assertOneProblem(problems(abi=abi), "getPost")

    def test_event_field_type_change_reaches_the_command_check(self):
        abi = copy.deepcopy(ABI)
        next(item for item in abi if item.get("name") == "PostTipped")["inputs"][1]["type"] = "uint128"
        self.assertEqual(len(problems(abi=abi)), 2)  # the events table and the command both name the old type

    def test_struct_input_is_compared_as_a_tuple(self):
        abi = ABI + [function("setConfig", [param("tuple", "config", components=[param("address"), param("uint256")])])]
        usage = USAGE.replace("| `owner()`", "| `setConfig((address,uint256) config)` | owner |\n| `owner()`")
        self.assertEqual(problems(usage=usage, abi=abi, readme='cast send $P "setConfig((address,uint256))"\n'), [])
        self.assertOneProblem(problems(usage=usage, abi=abi, readme='cast send $P "setConfig((address,uint8))"\n'), "setConfig")

    def test_external_function_is_compared_with_its_fixed_signature(self):
        self.assertOneProblem(problems(readme='cast send $T "approve(address)"\n'), "approve")

    def test_unparseable_signature_is_reported(self):
        self.assertOneProblem(problems(readme='cast send $PROXY "likePost(uint256"\n'), "likePost")

    def test_missing_section_stops_the_check(self):
        with self.assertRaises(SystemExit):
            problems(usage=USAGE.replace("## Events", "## Other"))

    def test_one_cell_table_row_is_named(self):
        with self.assertRaises(SystemExit) as raised:
            problems(usage=USAGE.replace("| `PostHidden`, `PostUnhidden` | `uint256 postId` (indexed) |", "| `PostHidden` |"))
        self.assertIn("one cell", str(raised.exception))


class MainCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.usage = Path(tmp.name) / "USAGE.md"
        self.readme = Path(tmp.name) / "README.md"
        self.usage.write_text(USAGE)
        self.readme.write_text(README)

    def run_main(self, stdin):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = check_usage_docs.main(io.StringIO(stdin), self.usage, self.readme)
        return code, out.getvalue(), err.getvalue()

    def test_matching_docs_exit_zero(self):
        code, out, _ = self.run_main(json.dumps(ABI))
        self.assertEqual(code, 0)
        self.assertIn("match the contract ABI", out)

    def test_drift_exits_one_and_names_the_problem(self):
        self.readme.write_text('cast send $PROXY "likePost(address)"\n')
        code, _, err = self.run_main(json.dumps(ABI))
        self.assertEqual(code, 1)
        self.assertIn("likePost(address)", err)

    def test_input_that_is_not_an_abi_is_refused_with_the_expected_input(self):
        for stdin in ("", "not json", "{}", "[]", '"abi"'):
            with self.subTest(stdin=stdin), self.assertRaises(SystemExit) as raised:
                self.run_main(stdin)
            self.assertIn("forge inspect SoloPostLayer abi --json", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
