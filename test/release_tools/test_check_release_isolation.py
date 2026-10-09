"""Offline tests for test/release_tools/check_release_isolation.py. Run: python3 -m unittest discover -s test/release_tools"""
import copy
import importlib.util
import io
import json
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "check_release_isolation.py"

spec = importlib.util.spec_from_file_location("check_release_isolation", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def volume(source, target):
    return {"type": "volume", "source": source, "target": target}


def bind(source, target):
    return {"type": "bind", "source": source, "target": target}


GOOD = {
    "services": {
        "tools": {"volumes": [bind("/repo", "/workspace"), volume("svm-cache", "/home/foundry/.svm")]},
        "release": {
            "environment": {
                "FOUNDRY_OUT": "/tmp/release-out",
                "FOUNDRY_CACHE_PATH": "/tmp/release-cache",
                "PYTHONDONTWRITEBYTECODE": "1",
                "PYTHONPYCACHEPREFIX": "/tmp/release-pycache",
            },
            "volumes": [bind("/repo", "/workspace"), volume("release-svm-cache", "/home/foundry/.svm")],
        },
    }
}


def with_release(**changes):
    config = copy.deepcopy(GOOD)
    release = config["services"]["release"]
    environment = changes.pop("environment", {})
    release["environment"].update(environment)
    for key, value in changes.items():
        release[key] = value
    return config


class FindProblemsTest(unittest.TestCase):
    def test_acceptsTheIntendedSetup(self):
        self.assertEqual(checker.find_problems(GOOD), [])

    def test_rejectsOutputInsideTheWorkspace(self):
        problems = checker.find_problems(with_release(environment={"FOUNDRY_OUT": "/workspace/out"}))
        self.assertEqual(len(problems), 1)
        self.assertIn("FOUNDRY_OUT", problems[0])

    def test_rejectsAPathThatEscapesIntoTheWorkspaceWithDotDot(self):
        problems = checker.find_problems(with_release(environment={"FOUNDRY_OUT": "/tmp/../workspace/out"}))
        self.assertEqual(len(problems), 1)

    def test_rejectsAMissingOrRelativePath(self):
        self.assertEqual(len(checker.find_problems(with_release(environment={"FOUNDRY_CACHE_PATH": "cache"}))), 1)
        config = with_release()
        del config["services"]["release"]["environment"]["FOUNDRY_OUT"]
        self.assertEqual(len(checker.find_problems(config)), 1)

    def test_rejectsAVolumeMountedOnTheOutputPath(self):
        config = with_release(volumes=GOOD["services"]["release"]["volumes"] + [volume("shared-out", "/tmp/release-out")])
        self.assertTrue(any("/tmp/release-out" in problem for problem in checker.find_problems(config)))

    def test_rejectsAMountThatCoversTheCachePath(self):
        config = with_release(volumes=GOOD["services"]["release"]["volumes"] + [bind("/somewhere", "/tmp")])
        self.assertTrue(any("FOUNDRY_CACHE_PATH" in problem for problem in checker.find_problems(config)))

    def test_rejectsANamedVolumeSharedWithAnotherService(self):
        config = with_release(volumes=[bind("/repo", "/workspace"), volume("svm-cache", "/home/foundry/.svm")])
        problems = checker.find_problems(config)
        self.assertEqual(len(problems), 1)
        self.assertIn("tools", problems[0])

    def test_rejectsPythonBytecodeSettingsThatReadTheWorkspace(self):
        self.assertEqual(len(checker.find_problems(with_release(environment={"PYTHONDONTWRITEBYTECODE": ""}))), 1)
        problems = checker.find_problems(with_release(environment={"PYTHONPYCACHEPREFIX": "/workspace/script"}))
        self.assertEqual(len(problems), 1)
        self.assertIn("PYTHONPYCACHEPREFIX", problems[0])

    def test_reportsAMissingReleaseService(self):
        problems = checker.find_problems({"services": {"tools": {}}})
        self.assertEqual(len(problems), 1)
        self.assertIn("release", problems[0])


class MainTest(unittest.TestCase):
    def run_main(self, stdin_text):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = checker.main(io.StringIO(stdin_text))
        return status, out.getvalue(), err.getvalue()

    def test_passesTheIntendedSetup(self):
        status, out, err = self.run_main(json.dumps(GOOD))
        self.assertEqual((status, err), (0, ""))
        self.assertTrue(out.startswith("ok"))

    def test_failsWithOneErrorLinePerProblem(self):
        status, _, err = self.run_main(json.dumps(with_release(environment={"FOUNDRY_OUT": "/workspace/out"})))
        self.assertEqual(status, 1)
        self.assertEqual(len(err.strip().splitlines()), 1)
        self.assertTrue(err.startswith("error:"))

    def test_failsWithoutEchoingInputWhenItIsNotJson(self):
        status, out, err = self.run_main("SECRET_KEY=abc")
        self.assertEqual(status, 1)
        self.assertNotIn("SECRET_KEY", out + err)
        self.assertTrue(err.startswith("error:"))


if __name__ == "__main__":
    unittest.main()
