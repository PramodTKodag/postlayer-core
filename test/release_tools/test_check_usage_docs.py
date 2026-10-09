"""Offline tests for script/check_usage_docs.py. Run: python3 -m unittest discover -s test/release_tools"""
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_usage_docs", ROOT / "script" / "check_usage_docs.py")
check_usage_docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_usage_docs)


def param(type_, name="", indexed=None):
    item = {"type": type_, "name": name}
    if indexed is not None:
        item["indexed"] = indexed
    return item


ABI = [
    {"type": "constructor", "inputs": []},
    {"type": "function", "name": "likePost", "inputs": [param("uint256", "postId")]},
    {"type": "function", "name": "postCount", "inputs": []},
    {"type": "event", "name": "PostLiked", "inputs": [param("uint256", "postId", True), param("address", "liker", True)]},
    {"type": "event", "name": "Initialized", "inputs": [param("uint64", "version", False)]},
    {"type": "error", "name": "AlreadyLiked", "inputs": [param("uint256", "postId"), param("address", "liker")]},
    {"type": "error", "name": "NotInitializing", "inputs": []},
]

USAGE = """# Using

## Function reference

| Function | Who |
|---|---|
| `likePost(uint256 postId)` | anyone |
| `postCount()` returns `uint256` | anyone |

## Events

| Event | Fields |
|---|---|
| `PostLiked` | `postId` (indexed), `liker` (indexed) |

```sh
cast logs "PostLiked(uint256 indexed,address indexed)"
cast send $PROXY "likePost(uint256)"
cast send $TOKEN "approve(address,uint256)"
```

## Errors

| Function | Reverts with |
|---|---|
| any function taking a `postId` | `AlreadyLiked(postId, liker)` once, see `postCount()` |

## Last
"""
README = 'cast send $PROXY "likePost(uint256)"\n'


def problems(usage=USAGE, readme=README, abi=ABI):
    return check_usage_docs.check(abi, usage, readme)


class CheckUsageDocsCase(unittest.TestCase):
    def assertOneProblem(self, found, fragment):
        self.assertEqual(len(found), 1, found)
        self.assertIn(fragment, found[0])

    def test_matching_docs_pass(self):
        self.assertEqual(problems(), [])

    def test_function_missing_from_docs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("| `postCount()` returns `uint256` | anyone |\n", "")), "postCount is in the ABI but not in the function reference")

    def test_function_unknown_to_abi(self):
        self.assertOneProblem(problems(abi=[item for item in ABI if item.get("name") != "postCount"]), "postCount is in the function reference but not in the ABI")

    def test_function_parameter_type_differs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("likePost(uint256 postId)", "likePost(address postId)")), "likePost takes (uint256)")

    def test_event_missing_from_docs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("| `PostLiked` | `postId` (indexed), `liker` (indexed) |\n", "")), "PostLiked is in the ABI but not in the events table")

    def test_event_unknown_to_abi(self):
        self.assertOneProblem(problems(usage=USAGE.replace("| `PostLiked` |", "| `PostLiked`, `PostShared` |")), "PostShared is in the events table but not in the ABI")

    def test_event_indexed_flag_differs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`liker` (indexed)", "`liker`")), "event PostLiked has fields")

    def test_plumbing_event_and_error_need_no_docs(self):
        self.assertEqual(problems(), [])

    def test_error_missing_from_docs(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`AlreadyLiked(postId, liker)`", "nothing")), "AlreadyLiked can be raised but is not in the errors table")

    def test_error_unknown_to_abi(self):
        self.assertOneProblem(problems(usage=USAGE.replace("`AlreadyLiked(postId, liker)`", "`AlreadyLiked`, `Gone`")), "Gone is in the errors table but not in the ABI")

    def test_lowercase_code_in_errors_table_is_not_an_error_name(self):
        self.assertEqual(problems(), [])  # USAGE mentions `postCount()` in the errors table

    def test_command_signature_with_wrong_types(self):
        self.assertOneProblem(problems(readme='cast send $PROXY "likePost(address)"\n'), 'README.md: command uses "likePost(address)"')

    def test_command_signature_for_unknown_function(self):
        self.assertOneProblem(problems(readme='cast send $PROXY "sharePost(uint256)"\n'), "sharePost")

    def test_event_command_must_spell_out_indexed(self):
        self.assertOneProblem(problems(usage=USAGE.replace("PostLiked(uint256 indexed,address indexed)", "PostLiked(uint256,address)")), "PostLiked")

    def test_function_call_with_return_types_is_accepted(self):
        self.assertEqual(problems(readme='cast call $PROXY "postCount()(uint256)"\n'), [])

    def test_missing_section_stops_the_check(self):
        with self.assertRaises(SystemExit):
            problems(usage=USAGE.replace("## Events", "## Other"))


if __name__ == "__main__":
    unittest.main()
