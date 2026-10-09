"""Offline tests for script/hide_urls.py. Run: python3 -m unittest discover -s test/release_tools"""
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "script" / "hide_urls.py"


spec = importlib.util.spec_from_file_location("hide_urls", SCRIPT)
hide_urls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hide_urls)


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
        self.assertIn("no-such-command-xyz", result.stderr)

    def test_fails_without_a_command(self):
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage", result.stderr)

    def test_hide_function_hides_urls_in_text(self):
        # the manifest writer uses this, so there is one masking rule
        self.assertEqual(hide_urls.hide("failed (http://localhost/v2/KEY99)"), "failed (<url hidden>)")

    def test_survives_output_that_is_not_utf8_and_keeps_the_status(self):
        child = "import sys; sys.stdout.buffer.write(b'ok https://a/KEY \\xff\\nlater https://b/KEY\\n'); sys.exit(3)"
        result = subprocess.run([sys.executable, str(SCRIPT), sys.executable, "-c", child], capture_output=True)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result.stdout.decode("utf-8"), "ok <url hidden> \ufffd\nlater <url hidden>\n")

    def test_a_command_killed_by_a_signal_gives_128_plus_the_signal(self):
        child = "import os, signal; os.kill(os.getpid(), signal.SIGKILL)"
        result = subprocess.run([sys.executable, str(SCRIPT), sys.executable, "-c", child], capture_output=True)
        self.assertEqual(result.returncode, 128 + signal.SIGKILL)

    def test_a_signal_to_the_filter_reaches_the_command_and_the_filter_waits_for_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "child.pid"
            child = (f"import os, time; open({str(pid_file)!r}, 'w').write(str(os.getpid())); "
                     "print('started', flush=True); time.sleep(30)")
            filter_process = subprocess.Popen([sys.executable, str(SCRIPT), sys.executable, "-c", child],
                                              stdout=subprocess.PIPE, text=True)
            self.assertEqual(filter_process.stdout.readline().strip(), "started")
            child_pid = int(pid_file.read_text())
            filter_process.send_signal(signal.SIGTERM)
            self.assertEqual(filter_process.wait(timeout=10), 128 + signal.SIGTERM)
            time.sleep(0.2)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)  # the command is gone, not orphaned


if __name__ == "__main__":
    unittest.main()
