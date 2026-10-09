"""Offline tests for script/write_release_manifest.py. Run: python3 -m unittest discover -s test/release_tools"""
import contextlib
import importlib.util
import io
import json
import os
import tempfile
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))  # the writer imports chain_config from its own directory
spec = importlib.util.spec_from_file_location("write_release_manifest", ROOT / "script" / "write_release_manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)

IMPLEMENTATION = "0x00000000000000000000000000000000000000a1"
PROXY = "0x00000000000000000000000000000000000000b2"
CHAIN_ID = 31337


def receipt(tx_hash, status="0x1", block="0x10", contract=None):
    return {"transactionHash": tx_hash, "status": status, "blockNumber": block, "contractAddress": contract}


def broadcast(transactions, receipts):
    return {"transactions": transactions, "receipts": receipts}


def creation(tx_hash, address):
    return {"hash": tx_hash, "contractAddress": address.lower(), "additionalContracts": []}


GOOD = broadcast(
    [creation("0x1", IMPLEMENTATION), creation("0x2", PROXY.upper().replace("0X", "0x"))],
    [receipt("0x1"), receipt("0x2", block="0x11")],
)


class RunMasksUrlsTest(unittest.TestCase):
    """A failing command's error text never shows a URL, whatever spelling the tool prints (cast normalizes the host and port)."""

    def failing(self, stderr_text):
        code = f"import sys; sys.stderr.write({stderr_text!r}); sys.exit(1)"
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            manifest.run([sys.executable, "-c", code])
        return err.getvalue()

    def test_a_url_printed_in_normalized_form_is_hidden(self):
        # configured as http://LocalHost:80/v2/KEY99, printed by cast as http://localhost/v2/KEY99
        shown = self.failing("error sending request for url (http://localhost/v2/KEY99)")
        self.assertNotIn("KEY99", shown)
        self.assertIn("<url hidden>", shown)
        self.assertIn("exit status 1", shown)


class InWorkdir(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous = os.getcwd()
        os.chdir(self.tmp.name)
        self.addCleanup(os.chdir, self.previous)

    def expect_failure(self, call, *fragments):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
            call()
        self.assertEqual(raised.exception.code, 1)
        for fragment in fragments:
            self.assertIn(fragment, stderr.getvalue())
        return stderr.getvalue()


class DeployTransactionsTest(InWorkdir):
    def write(self, data, chain_id=CHAIN_ID):
        path = Path("broadcast/DeploySoloPostLayer.s.sol") / str(chain_id) / "run-latest.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(data))

    def call(self):
        return manifest.deploy_transactions(CHAIN_ID, IMPLEMENTATION, PROXY)

    def test_returns_hash_and_block_of_each_transaction(self):
        self.write(GOOD)
        self.assertEqual(self.call(), [{"hash": "0x1", "blockNumber": 16}, {"hash": "0x2", "blockNumber": 17}])

    def test_fails_when_broadcast_file_is_missing(self):
        self.expect_failure(self.call, "not found", "original deploy")

    def test_fails_when_broadcast_has_no_transactions(self):
        self.write(broadcast([], []))
        self.expect_failure(self.call, "no transactions")

    def test_fails_when_a_transaction_has_no_receipt(self):
        self.write(broadcast(GOOD["transactions"], [receipt("0x1")]))
        self.expect_failure(self.call, "0x2", "no receipt")

    def test_fails_when_a_receipt_did_not_succeed(self):
        self.write(broadcast(GOOD["transactions"], [receipt("0x1"), receipt("0x2", status="0x0")]))
        self.expect_failure(self.call, "0x2", "did not succeed")

    def test_fails_when_implementation_was_not_created(self):
        self.write(broadcast([creation("0x2", PROXY)], [receipt("0x2")]))
        self.expect_failure(self.call, "predicted implementation")

    def test_fails_when_proxy_was_not_created(self):
        self.write(broadcast([creation("0x1", IMPLEMENTATION)], [receipt("0x1")]))
        self.expect_failure(self.call, "predicted proxy")

    def test_created_address_may_come_from_additional_contracts_or_the_receipt(self):
        transactions = [
            {"hash": "0x1", "contractAddress": None, "additionalContracts": [{"address": IMPLEMENTATION}]},
            {"hash": "0x2", "contractAddress": None, "additionalContracts": []},
        ]
        self.write(broadcast(transactions, [receipt("0x1"), receipt("0x2", contract=PROXY)]))
        self.assertEqual([tx["hash"] for tx in self.call()], ["0x1", "0x2"])


class SettingsAndNamesTest(InWorkdir):
    def test_foundry_default_profile_reads_the_default_profile_only(self):
        Path("foundry.toml").write_text(
            '[profile.default]\nsolc_version = "0.8.37"\nevm_version = "shanghai" # comment\n'
            'optimizer_runs = 200\nbytecode_hash = "none"\n\n[profile.ci]\noptimizer_runs = 999\n'
        )
        self.assertEqual(
            manifest.foundry_default_profile(),
            {"solc": "0.8.37", "evmVersion": "shanghai", "optimizerRuns": 200, "bytecodeHash": "none"},
        )

    def test_missing_setting_fails_with_its_name(self):
        Path("foundry.toml").write_text('[profile.default]\nsolc_version = "0.8.37"\n')
        self.expect_failure(manifest.foundry_default_profile, "evm_version")

    def test_predicted_addresses_parses_only_the_machine_line(self):
        output = f"Predicted proxy: 0xdead\nPREDICTED implementation={IMPLEMENTATION} proxy={PROXY}\n"
        with mock.patch.object(manifest, "run", return_value=output):
            self.assertEqual(manifest.predicted_addresses(), (IMPLEMENTATION, PROXY))

    def test_predicted_addresses_fails_without_the_machine_line(self):
        with mock.patch.object(manifest, "run", return_value=f"Predicted proxy: {PROXY}\n"):
            self.expect_failure(manifest.predicted_addresses, "PREDICTED line")

    def run_main(self, *fragments, **overrides):
        env = {"CHAINS": "84532", "OWNER": "0x1", "SALT_LABEL": "x", "RELEASE_NAME": "testnet-0.1.0",
               "MANIFEST_DIR": "out"}
        env.update(overrides)
        with mock.patch.dict(os.environ, env, clear=True):
            return self.expect_failure(manifest.main, *fragments)

    def test_anything_but_a_chain_id_is_rejected(self):
        for bad in ("ethereum_sepolia", "Base", "base-sepolia", "../x", "0", "007", "1" * 19, "1.5", "-1"):
            with self.subTest(bad=bad):
                self.run_main(f"chain '{bad}' is not a chain id; use e.g. 11155111", CHAINS=bad)
                self.run_main(f"chain '{bad}' is not a chain id; use e.g. 11155111", CHAINS=f"84532 {bad}")

    def test_a_repeated_chain_id_is_rejected_before_any_work(self):
        with mock.patch.object(manifest, "predicted_addresses", side_effect=AssertionError("must not run")):
            self.run_main("chain 84532 is listed more than once in CHAINS", CHAINS="84532 11155111 84532")

    def test_chain_file_is_refused_without_the_local_opt_in_before_any_work(self):
        with mock.patch.object(manifest, "predicted_addresses", side_effect=AssertionError("must not run")), \
             mock.patch.object(manifest, "cast", side_effect=AssertionError("must not run")):
            self.run_main("error: CHAINS_FILE is test-only", CHAINS_FILE="chains.json")

    def test_an_unreadable_chain_file_is_a_clean_error_before_any_work(self):
        Path("dir.json").mkdir()
        Path("binary.json").write_bytes(b"\xff\xfe")
        for name in ("dir.json", "binary.json"):
            with self.subTest(name=name), \
                 mock.patch.object(manifest, "predicted_addresses", side_effect=AssertionError("must not run")):
                self.run_main(f"error: chain file {name} could not be read", CHAINS_FILE=name, LOCAL_CHAINS_OK="1")

    def test_invalid_release_names_are_rejected(self):
        for bad in (".hidden", "-flag", "a/b", "UPPER", "a b"):
            with self.subTest(bad=bad):
                self.run_main("invalid RELEASE_NAME", RELEASE_NAME=bad)

    def test_existing_manifest_is_refused_before_any_work(self):
        Path("out").mkdir()
        Path("out/testnet-0.1.0.json").write_text("{}")
        with mock.patch.object(manifest, "predicted_addresses", side_effect=AssertionError("must not run")):
            self.run_main("refusing to overwrite")
        self.assertEqual(Path("out/testnet-0.1.0.json").read_text(), "{}")


class InspectChainTest(InWorkdir):
    FILE_RPC = "https://rpc.file.invalid"
    OVERRIDE_RPC = "https://rpc.override.invalid/v2/SECRET-KEY"

    def setUp(self):
        super().setUp()
        Path("chains.json").write_text(json.dumps({
            "84532": {"chainId": 84532, "name": "Base Sepolia", "explorerUrl": "https://sepolia.basescan.org/", "rpcUrl": self.FILE_RPC},
        }))
        patcher = mock.patch.dict(os.environ, {"CHAINS_FILE": "chains.json", "LOCAL_CHAINS_OK": "1"}, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.rpc_urls = []

    def fake_cast(self, chain_id="84532", owner=PROXY):
        def cast(args, rpc_url):
            self.rpc_urls.append(rpc_url)
            return {"chain-id": chain_id, "call": owner, "storage": "0x" + "0" * 24 + IMPLEMENTATION[2:]}[args[0]]
        return cast

    def inspect(self, **cast_options):
        with mock.patch.object(manifest, "cast", self.fake_cast(**cast_options)), \
             mock.patch.object(manifest, "code_hash", return_value="0xhash"), \
             mock.patch.object(manifest, "deploy_transactions", return_value=[]):
            return manifest.inspect_chain("84532", PROXY, IMPLEMENTATION, PROXY)

    def test_chain_id_and_explorer_come_from_the_chain_file(self):
        chain = self.inspect()
        self.assertEqual(chain["chainId"], 84532)
        self.assertEqual(chain["explorer"], {
            "implementation": f"https://sepolia.basescan.org/address/{IMPLEMENTATION}",
            "proxy": f"https://sepolia.basescan.org/address/{PROXY}",
        })

    def test_the_display_name_is_recorded_when_present(self):
        self.assertEqual(self.inspect()["name"], "Base Sepolia")

    def test_no_name_key_when_the_chain_has_none(self):
        Path("chains.json").write_text(json.dumps({
            "84532": {"chainId": 84532, "explorerUrl": "https://sepolia.basescan.org", "rpcUrl": self.FILE_RPC},
        }))
        self.assertNotIn("name", self.inspect())

    def test_rpc_url_comes_from_the_file_and_is_not_recorded(self):
        chain = self.inspect()
        self.assertEqual(set(self.rpc_urls), {self.FILE_RPC})
        self.assertNotIn(self.FILE_RPC, json.dumps(chain))

    def test_rpc_override_wins_and_is_not_recorded(self):
        os.environ["CHAIN_84532_RPC_URL"] = self.OVERRIDE_RPC
        chain = self.inspect()
        self.assertEqual(set(self.rpc_urls), {self.OVERRIDE_RPC})
        self.assertNotIn("SECRET-KEY", json.dumps(chain))

    def test_chain_id_mismatch_fails(self):
        self.expect_failure(lambda: self.inspect(chain_id="1"), "chain 84532 (Base Sepolia) reports chain id 1, expected 84532")

    def test_unknown_chain_fails_with_the_known_chains(self):
        self.expect_failure(lambda: manifest.inspect_chain("1", PROXY, IMPLEMENTATION, PROXY), "unknown chain '1'", "84532")


class MainTest(InWorkdir):
    def test_the_manifest_chains_are_keyed_by_chain_id(self):
        Path("chains.json").write_text(json.dumps({
            "84532": {"chainId": 84532, "name": "Base Sepolia", "explorerUrl": "https://sepolia.basescan.org", "rpcUrl": "https://rpc.file.invalid"},
        }))
        env = {"CHAINS": "84532", "OWNER": PROXY, "SALT_LABEL": "x", "RELEASE_NAME": "testnet-0.1.0", "MANIFEST_DIR": "out",
               "CHAINS_FILE": "chains.json", "LOCAL_CHAINS_OK": "1"}
        with mock.patch.dict(os.environ, env, clear=True), \
             mock.patch.object(manifest, "predicted_addresses", return_value=(IMPLEMENTATION, PROXY)), \
             mock.patch.object(manifest, "git_state", return_value=("abc", True)), \
             mock.patch.object(manifest, "foundry_default_profile", return_value={}), \
             mock.patch.object(manifest, "inspect_chain", return_value={"chainId": 84532, "name": "Base Sepolia"}), \
             contextlib.redirect_stdout(io.StringIO()):
            manifest.main()
        written = json.loads(Path("out/testnet-0.1.0.json").read_text())
        self.assertEqual(set(written["chains"]), {"84532"})


class WriteNewFileTest(InWorkdir):
    def test_writes_content_and_leaves_no_temporary_file(self):
        target = Path("dir/m.json")
        manifest.write_new_file(target, "hello")
        self.assertEqual(target.read_text(), "hello")
        self.assertEqual([p.name for p in Path("dir").iterdir()], ["m.json"])

    def test_refuses_to_overwrite_and_cleans_up(self):
        target = Path("m.json")
        target.write_text("original")
        self.expect_failure(lambda: manifest.write_new_file(target, "new"), "refusing to overwrite")
        self.assertEqual(target.read_text(), "original")
        self.assertEqual([p.name for p in Path(".").iterdir()], ["m.json"])

    def test_failure_while_writing_leaves_no_target(self):
        target = Path("m.json")
        with mock.patch("os.link", side_effect=OSError("boom")), self.assertRaises(OSError):
            manifest.write_new_file(target, "x")
        self.assertEqual(list(Path(".").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
