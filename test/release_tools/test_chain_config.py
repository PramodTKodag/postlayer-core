"""Offline tests for script/chain_config.py. Run: python3 -m unittest discover -s test/release_tools"""
import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script" / "chain_config.py"
spec = importlib.util.spec_from_file_location("chain_config", SCRIPT)
chain_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chain_config)

ENTRY = {"chainId": 84532, "explorerUrl": "https://sepolia.basescan.org", "rpcUrl": "https://sepolia.base.org"}
OVERRIDE = "https://rpc.example/v2/SECRET-KEY"


class ChainConfigCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, data, name="chains.json"):
        path = Path(self.tmp.name) / name
        path.write_text(data if isinstance(data, str) else json.dumps(data))
        return path

    def entry(self, **changes):
        return {**ENTRY, **changes}

    def assert_config_error(self, call, *fragments, forbidden=()):
        with self.assertRaises(chain_config.ConfigError) as raised:
            call()
        message = str(raised.exception)
        for fragment in fragments:
            self.assertIn(fragment, message)
        for text in forbidden:
            self.assertNotIn(text, message)


class LoadChainsTest(ChainConfigCase):
    def test_loads_a_valid_file(self):
        path = self.write({"84532": ENTRY})
        self.assertEqual(chain_config.load_chains(path), {"84532": ENTRY})

    def test_the_committed_files_are_valid(self):
        for path in (ROOT / "chains.json", ROOT / "script" / "local-chains.json"):
            with self.subTest(path=path.name):
                self.assertTrue(chain_config.load_chains(path))

    def test_rejects_a_missing_file(self):
        self.assert_config_error(lambda: chain_config.load_chains(Path(self.tmp.name) / "nope.json"), "not found")

    def test_rejects_an_unreadable_file_naming_only_the_path(self):
        directory = Path(self.tmp.name)
        non_utf8 = Path(self.tmp.name) / "binary.json"
        non_utf8.write_bytes(b'{"k\xff": 1}')
        for path in (directory, non_utf8):
            with self.subTest(path=path.name):
                self.assert_config_error(lambda: chain_config.load_chains(path), str(path), "could not be read")

    def test_rejects_a_repeated_chain_id(self):
        text = json.dumps({"84532": ENTRY})[:-1] + ", " + json.dumps({"84532": self.entry(chainId=1)})[1:]
        self.assert_config_error(lambda: chain_config.load_chains(self.write(text)), "repeated key '84532'")

    def test_rejects_a_repeated_field(self):
        text = '{"1": {"chainId": 1, "chainId": 2, "explorerUrl": "https://e.example", "rpcUrl": "https://r.example"}}'
        self.assert_config_error(lambda: chain_config.load_chains(self.write(text)), "repeated key 'chainId'")

    def test_rejects_invalid_json(self):
        self.assert_config_error(lambda: chain_config.load_chains(self.write("{")), "not valid JSON")

    def test_rejects_a_number_too_large_to_parse(self):
        text = '{"84532": {"chainId": ' + "9" * 5000 + "}}"
        self.assert_config_error(lambda: chain_config.load_chains(self.write(text)), "not valid JSON")

    def test_rejects_a_non_object_file(self):
        self.assert_config_error(lambda: chain_config.load_chains(self.write([])), "must be a JSON object")

    def test_rejects_keys_that_are_not_chain_ids(self):
        for bad in ("base_sepolia", "Base", "base-sepolia", "", "a b", "0", "01", "-1", "+1", "1.5", "1e3", " 1", "1 ",
                    "1\n", "\u0661", "1" * 19):
            with self.subTest(bad=bad):
                self.assert_config_error(
                    lambda: chain_config.load_chains(self.write({bad: self.entry(chainId=1)})), "is not a chain id", "11155111"
                )

    def test_accepts_the_longest_chain_id(self):
        key = "9" * 18
        self.assertIn(key, chain_config.load_chains(self.write({key: self.entry(chainId=int(key))})))

    def test_rejects_a_chain_id_that_differs_from_its_key(self):
        self.assert_config_error(
            lambda: chain_config.load_chains(self.write({"1": self.entry(chainId=2)})), "'1'", "chainId", "must equal"
        )

    def test_accepts_a_display_name(self):
        for good in ("Base Sepolia", "a", "x_y.z-1", "A" * 40):
            with self.subTest(good=good):
                path = self.write({"84532": self.entry(name=good)})
                self.assertEqual(chain_config.load_chains(path)["84532"]["name"], good)

    def test_rejects_a_bad_display_name(self):
        for bad in ("", "A" * 41, "Base/Sepolia", "Base\nSepolia", "Base\tSepolia", "Bäse", "a;b", 5, None):
            with self.subTest(bad=bad):
                self.assert_config_error(
                    lambda: chain_config.load_chains(self.write({"84532": self.entry(name=bad)})), "name"
                )

    def test_rejects_a_non_object_entry(self):
        self.assert_config_error(lambda: chain_config.load_chains(self.write({"84532": 1})), "84532", "must be an object")

    def test_rejects_missing_and_unknown_fields(self):
        for field in ENTRY:  # name is optional and not part of ENTRY
            with self.subTest(missing=field):
                entry = {k: v for k, v in ENTRY.items() if k != field}
                self.assert_config_error(lambda: chain_config.load_chains(self.write({"84532": entry})), "84532", field)
        self.assert_config_error(
            lambda: chain_config.load_chains(self.write({"84532": self.entry(extra=1)})), "84532", "extra"
        )

    def test_rejects_a_bad_chain_id(self):
        for bad in (0, -1, "84532", 1.5, True, None):
            with self.subTest(bad=bad):
                self.assert_config_error(
                    lambda: chain_config.load_chains(self.write({"84532": self.entry(chainId=bad)})), "chainId"
                )

    def test_rejects_a_bad_url(self):
        for field in ("explorerUrl", "rpcUrl"):
            for bad in ("", "ftp://x.example", "sepolia.base.org", "https://", 5):
                with self.subTest(field=field, bad=bad):
                    self.assert_config_error(
                        lambda: chain_config.load_chains(self.write({"84532": self.entry(**{field: bad})})), field
                    )

    def test_rejects_a_keyed_rpc_url_without_printing_it(self):
        for keyed in ("https://user:pass@rpc.example", "https://token@rpc.example", "https://rpc.example/?apikey=K3Y"):
            with self.subTest(keyed=keyed):
                self.assert_config_error(
                    lambda: chain_config.load_chains(self.write({"84532": self.entry(rpcUrl=keyed)})),
                    "rpcUrl",
                    "must not contain",
                    forbidden=("K3Y", "pass", "token"),
                )


    def test_rejects_a_fragment_or_params_in_an_rpc_url(self):
        for bad in ("https://rpc.example/#frag", "https://rpc.example/path;key=K3Y", "https://rpc.example/;K3Y"):
            with self.subTest(bad=bad):
                self.assert_config_error(
                    lambda: chain_config.load_chains(self.write({"84532": self.entry(rpcUrl=bad)})),
                    "rpcUrl",
                    "must not contain",
                    forbidden=("K3Y",),
                )

    def test_rejects_credentials_query_and_fragment_in_an_explorer_url(self):
        for bad in ("https://u:p@scan.example", "https://tok@scan.example", "https://scan.example/?k=K3Y", "https://scan.example/#f"):
            with self.subTest(bad=bad):
                self.assert_config_error(
                    lambda: chain_config.load_chains(self.write({"84532": self.entry(explorerUrl=bad)})),
                    "explorerUrl",
                    "must not contain",
                    forbidden=("K3Y",),
                )

    def test_rejects_whitespace_and_control_characters_in_every_url(self):
        for field in ("explorerUrl", "rpcUrl"):
            for bad in ("https://rpc.example/a b", " https://rpc.example", "https://rpc.example\n", "https://rpc.example/\ta", "https://rpc.example/\x00", "https://rpc.example/\x7f"):
                with self.subTest(field=field, bad=bad):
                    self.assert_config_error(
                        lambda: chain_config.load_chains(self.write({"84532": self.entry(**{field: bad})})), field
                    )


class ChainsFileTest(ChainConfigCase):
    def test_defaults_to_the_committed_chains_json(self):
        self.assertEqual(chain_config.chains_file({}), ROOT / "chains.json")

    def test_refuses_chains_file_without_the_local_opt_in(self):
        for environ in ({"CHAINS_FILE": "x.json"}, {"CHAINS_FILE": "x.json", "LOCAL_CHAINS_OK": ""},
                        {"CHAINS_FILE": "x.json", "LOCAL_CHAINS_OK": "0"}, {"CHAINS_FILE": "x.json", "LOCAL_CHAINS_OK": "yes"}):
            with self.subTest(environ=environ):
                self.assert_config_error(lambda: chain_config.chains_file(environ), "CHAINS_FILE is test-only")

    def test_get_refuses_chains_file_without_the_local_opt_in(self):
        path = self.write({"84532": ENTRY})
        self.assert_config_error(
            lambda: chain_config.get("84532", "chainId", {"CHAINS_FILE": str(path)}), "CHAINS_FILE is test-only"
        )

    def test_accepts_chains_file_with_the_local_opt_in(self):
        environ = {"CHAINS_FILE": "x.json", "LOCAL_CHAINS_OK": "1"}
        self.assertEqual(chain_config.chains_file(environ), Path("x.json"))

    def test_an_empty_chains_file_is_unset(self):
        self.assertEqual(chain_config.chains_file({"CHAINS_FILE": ""}), ROOT / "chains.json")


class GetTest(ChainConfigCase):
    def setUp(self):
        super().setUp()
        self.path = self.write({"84532": ENTRY, "11155111": self.entry(chainId=11155111)})

    def get(self, chain, field, environ=None):
        return chain_config.get(chain, field, environ or {}, self.path)

    def test_returns_file_values_as_text(self):
        self.assertEqual(self.get("84532", "chainId"), "84532")
        self.assertEqual(self.get("84532", "explorerUrl"), ENTRY["explorerUrl"])
        self.assertEqual(self.get("84532", "rpcUrl"), ENTRY["rpcUrl"])

    def test_rejects_whitespace_in_an_rpc_url_override(self):
        self.assert_config_error(
            lambda: self.get("84532", "rpcUrl", {"CHAIN_84532_RPC_URL": "https://rpc.example/a b"}),
            "CHAIN_84532_RPC_URL",
        )

    def test_env_override_wins_for_the_rpc_url_only(self):
        environ = {"CHAIN_84532_RPC_URL": OVERRIDE, "CHAIN_84532_ID": "1", "CHAIN_84532_EXPLORER_URL": "https://x.example"}
        self.assertEqual(self.get("84532", "rpcUrl", environ), OVERRIDE)
        self.assertEqual(self.get("84532", "chainId", environ), "84532")
        self.assertEqual(self.get("84532", "explorerUrl", environ), ENTRY["explorerUrl"])

    def test_override_applies_to_its_own_chain_only(self):
        self.assertEqual(self.get("11155111", "rpcUrl", {"CHAIN_84532_RPC_URL": OVERRIDE}), ENTRY["rpcUrl"])

    def test_empty_override_is_ignored(self):
        self.assertEqual(self.get("84532", "rpcUrl", {"CHAIN_84532_RPC_URL": ""}), ENTRY["rpcUrl"])

    def test_invalid_override_fails_without_printing_it(self):
        for bad in ("not a url", "ftp://rpc.example/SECRET-KEY", "https://"):
            with self.subTest(bad=bad):
                self.assert_config_error(
                    lambda: self.get("84532", "rpcUrl", {"CHAIN_84532_RPC_URL": bad}),
                    "CHAIN_84532_RPC_URL",
                    forbidden=("SECRET-KEY", bad),
                )

    def test_returns_the_name_or_empty_text(self):
        path = self.write({"84532": self.entry(name="Base Sepolia"), "11155111": self.entry(chainId=11155111)})
        self.assertEqual(chain_config.get("84532", "name", {}, path), "Base Sepolia")
        self.assertEqual(chain_config.get("11155111", "name", {}, path), "")

    def test_unknown_chain_lists_the_known_chain_ids(self):
        self.assert_config_error(lambda: self.get("1", "chainId"), "unknown chain '1'", "11155111, 84532")

    def test_a_chain_name_is_not_a_chain_id(self):
        for bad in ("ethereum_sepolia", "nope", "", "0", "007", "1" * 19, "84532 ", "84532\n"):
            with self.subTest(bad=bad):
                self.assert_config_error(
                    lambda: self.get(bad, "chainId"), f"chain '{bad}' is not a chain id; use e.g. 11155111"
                )

    def test_a_chain_name_is_not_accepted_as_an_override_prefix(self):
        self.assertEqual(self.get("84532", "rpcUrl", {"BASE_SEPOLIA_RPC_URL": OVERRIDE}), ENTRY["rpcUrl"])

    def test_unknown_field_is_rejected(self):
        self.assert_config_error(lambda: self.get("84532", "owner"), "unknown field 'owner'", "chainId")


class CommandLineTest(ChainConfigCase):
    def run_cli(self, *args, env=None):
        base = {"PATH": "/usr/bin:/bin"}
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env={**base, **(env or {})}
        )

    def test_get_prints_the_value(self):
        path = self.write({"84532": ENTRY})
        result = self.run_cli("get", "84532", "chainId", env={"CHAINS_FILE": str(path), "LOCAL_CHAINS_OK": "1"})
        self.assertEqual((result.returncode, result.stdout), (0, "84532\n"))

    def test_get_uses_the_override(self):
        path = self.write({"84532": ENTRY})
        result = self.run_cli("get", "84532", "rpcUrl", env={"CHAINS_FILE": str(path), "LOCAL_CHAINS_OK": "1", "CHAIN_84532_RPC_URL": OVERRIDE})
        self.assertEqual(result.stdout, OVERRIDE + "\n")

    def test_default_file_is_the_committed_chains_json(self):
        result = self.run_cli("get", "84532", "chainId")
        self.assertEqual((result.returncode, result.stdout), (0, "84532\n"))

    def test_errors_go_to_stderr_with_exit_status_1(self):
        path = self.write({"84532": ENTRY})
        result = self.run_cli("get", "1", "chainId", env={"CHAINS_FILE": str(path), "LOCAL_CHAINS_OK": "1"})
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertTrue(result.stderr.startswith("error: unknown chain '1'"))

    def test_cli_refuses_chains_file_without_the_local_opt_in(self):
        path = self.write({"84532": ENTRY})
        result = self.run_cli("get", "84532", "chainId", env={"CHAINS_FILE": str(path)})
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertTrue(result.stderr.startswith("error: CHAINS_FILE is test-only"))

    def test_a_chain_name_is_refused_on_the_command_line(self):
        result = self.run_cli("get", "ethereum_sepolia", "chainId")
        self.assertEqual((result.returncode, result.stdout), (1, ""))
        self.assertIn("error: chain 'ethereum_sepolia' is not a chain id; use e.g. 11155111", result.stderr)

    def test_usage_error(self):
        result = self.run_cli("get", "84532")
        self.assertEqual(result.returncode, 1)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
