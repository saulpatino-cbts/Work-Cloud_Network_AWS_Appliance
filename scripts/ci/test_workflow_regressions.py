"""Offline tests of workflow files and the shell bodies of their safety assertions."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"


class _NoDuplicateKeysLoader(yaml.SafeLoader):
    """SafeLoader that records a repeated mapping key instead of silently keeping the last."""

    duplicates: list

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=True)
            if key in seen:
                self.duplicates.append((key, key_node.start_mark.line + 1))
            seen.add(key)
        return super().construct_mapping(node, deep)


def duplicate_keys(text):
    loader = _NoDuplicateKeysLoader(text)
    loader.duplicates = []
    try:
        loader.get_single_data()
    finally:
        loader.dispose()
    return loader.duplicates


class WorkflowRegressionTests(unittest.TestCase):
    def test_workflow_files_have_no_duplicate_keys(self):
        # GitHub rejects a workflow whose mapping repeats a key: the whole file is
        # invalid, every push fails and the workflow cannot be dispatched.
        files = sorted(WORKFLOWS.glob("*.yml"))
        self.assertTrue(files)
        for path in files:
            with self.subTest(workflow=path.name):
                self.assertEqual(duplicate_keys(path.read_text(encoding="utf-8")), [])

    def test_duplicate_key_detector_catches_a_repeat(self):
        self.assertEqual(duplicate_keys("env:\n  A: 1\n  B: 2\n  A: 3\n"), [("A", 4)])
        self.assertEqual(duplicate_keys("env:\n  A: 1\n  B: 2\n"), [])

    def test_preflight_secret_punctuation_and_placeholder_rejection(self):
        workflow = (WORKFLOWS / "100-validate-prereqs.yml").read_text(encoding="utf-8")
        body = workflow.split("          check_secret() {", 1)[1].split("\n          }", 1)[0]
        function = "check_secret() {" + body + "\n}\n"
        cases = (
            ("synthetic<test>only", 0),
            ("PLACEHOLDER", 1),
            ("Change-Me", 1),
            ("replace_me", 1),
            ("", 1),
        )
        with tempfile.TemporaryDirectory() as directory:
            for value, expected in cases:
                with self.subTest(value=value):
                    result = subprocess.run(
                        ["bash", "-e", "-c", function + 'FAILED=0; check_secret fixture "$FIXTURE"; exit "$FAILED"'],
                        capture_output=True,
                        text=True,
                        timeout=10,
                        env={**os.environ, "FIXTURE": value, "GITHUB_STEP_SUMMARY": str(Path(directory) / "summary")},
                    )
                    self.assertEqual(result.returncode, expected, result.stderr)

    def test_app_tokens_are_scoped_to_one_repository(self):
        # An unscoped App token spans every repository the App is installed on.
        # 230 deliberately targets the upstream core repository; every other
        # token must name its repository. Checked per step on the parsed `with:`.
        found = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
            for job_name, job in (workflow.get("jobs") or {}).items():
                for step in job.get("steps") or []:
                    if not str(step.get("uses", "")).startswith("actions/create-github-app-token@"):
                        continue
                    found += 1
                    with self.subTest(workflow=path.name, job=job_name):
                        self.assertTrue(str((step.get("with") or {}).get("repositories", "")).strip())
        self.assertGreaterEqual(found, 4)


if __name__ == "__main__":
    unittest.main()
