"""Offline tests for script/hide_urls.py. Run: python3 -m unittest discover -s test/release_tools"""
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "script" / "hide_urls.py"


def run(stdout="", stderr="", status=0):
    """Runs a child that writes `stdout` and `stderr` and exits with `status`, through hide_urls.py."""
    child = f"import sys; sys.stdout.write({stdout!r}); sys.stderr.write({stderr!r}); sys.exit({status})"
    return subprocess.run([sys.executable, str(SCRIPT), sys.executable, "-c", child], capture_output=True, text=True)


def hide(text):
    return run(stdout=text).stdout


class HideUrlsCase(unittest.TestCase):
    def test_hides_a_url_with_a_key_in_the_path(self):
        self.assertEqual(hide("failed: https://eth-sepolia.g.alchemy.com/v2/SECRETKEY\n"), "failed: <url hidden>\n")

    def test_hides_a_url_inside_parentheses_and_keeps_the_parenthesis(self):
        self.assertEqual(hide("error sending request for url (http://localhost/v2/KEY99)\n"),
                         "error sending request for url (<url hidden>)\n")

    def test_hides_a_url_whatever_its_host_case_or_port(self):
        # forge prints the host lowercased and without a default port, so the configured string never matches literally
        for url in ("http://LocalHost:80/v2/KEY", "http://localhost/v2/KEY", "https://rpc.example:8545/KEY?apikey=KEY#KEY"):
            self.assertEqual(hide(f"url ({url})\n"), "url (<url hidden>)\n")

    def test_hides_every_url_on_a_line_and_other_schemes(self):
        self.assertEqual(hide("a https://one/KEY1 b wss://two/KEY2, c\n"), "a <url hidden> b <url hidden>, c\n")

    def test_hides_a_url_with_special_characters(self):
        self.assertEqual(hide("u https://rpc.priv.invalid/v2/KEY.+*[x]&b=1?c=$d\\e|f end\n"), "u <url hidden> end\n")

    def test_keeps_text_without_a_url_unchanged(self):
        text = "Script ran successfully.\n  Predicted proxy: 0x2222222222222222222222222222222222222222\n"
        self.assertEqual(hide(text), text)

    def test_keeps_a_missing_final_newline_missing(self):
        self.assertEqual(hide("Enter password: https://x/KEY"), "Enter password: <url hidden>")

    def test_hides_urls_in_the_error_stream_and_shows_it_on_stdout(self):
        result = run(stderr="boom https://x/KEY\n")
        self.assertEqual((result.stdout, result.stderr), ("boom <url hidden>\n", ""))

    def test_exits_with_the_status_of_the_command(self):
        self.assertEqual(run(stdout="x\n", status=7).returncode, 7)
        self.assertEqual(run(stdout="x\n", status=0).returncode, 0)

    def test_fails_when_the_command_does_not_exist(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "no-such-command-xyz"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no-such-command-xyz", result.stdout)

    def test_fails_without_a_command(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage", result.stderr)


if __name__ == "__main__":
    unittest.main()
