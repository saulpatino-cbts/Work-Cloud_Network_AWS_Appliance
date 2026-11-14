"""Offline synthetic-plan regression tests; no Terraform or cloud execution."""

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


GUARD = Path(__file__).with_name("refuse_destructive_plan.py")
PROTECTED_TYPES = "aws_cloudwatch_log_group,aws_db_instance,aws_s3_bucket"
DATABASE = "module.data.aws_db_instance.postgres"


class DestructivePlanTests(unittest.TestCase):
    def run_guard(self, address, resource_type, actions, *, types=PROTECTED_TYPES, addresses=()):
        plan = {
            "resource_changes": [
                {"address": address, "type": resource_type, "change": {"actions": actions}}
            ]
        }
        return subprocess.run(
            [sys.executable, str(GUARD)],
            input=json.dumps(plan),
            text=True,
            capture_output=True,
            timeout=10,
            env={
                **os.environ,
                "PROTECTED_RESOURCE_TYPES": types,
                "PROTECTED_RESOURCE_ADDRESSES": ",".join(addresses),
            },
        )

    def test_protected_type_delete_and_replacement_refused(self):
        for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
            with self.subTest(actions=actions):
                result = self.run_guard(DATABASE, "aws_db_instance", actions)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(DATABASE, result.stderr)

    def test_protected_type_update_allowed(self):
        self.assertEqual(self.run_guard(DATABASE, "aws_db_instance", ["update"]).returncode, 0)

    def test_protected_type_forget_allowed(self):
        # A `removed { lifecycle { destroy = false } }` block plans as "forget":
        # the object leaves state and survives, so the guard must let it through
        # (the retired worker's log group leaves state this way, core R-016).
        address = "module.observability.aws_cloudwatch_log_group.worker"
        result = self.run_guard(address, "aws_cloudwatch_log_group", ["forget"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unprotected_type_delete_allowed(self):
        result = self.run_guard("module.network.aws_flow_log.this", "aws_flow_log", ["delete"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_exact_address_protection(self):
        result = self.run_guard(DATABASE, "aws_db_instance", ["delete"], types="aws_s3_bucket", addresses=(DATABASE,))
        self.assertEqual(result.returncode, 1)
        self.assertIn(DATABASE, result.stderr)

    def test_address_only_configuration(self):
        self.assertEqual(self.run_guard(DATABASE, "aws_db_instance", ["delete"], types="", addresses=(DATABASE,)).returncode, 1)

    def test_empty_configuration_refused(self):
        self.assertEqual(self.run_guard("anything", "anything", ["delete"], types="", addresses=()).returncode, 1)

    def test_quoted_instance_keys_fail_closed(self):
        for address in ('module.data.aws_db_instance.this["east,west"]', 'module.data.aws_db_instance.this["east"]'):
            with self.subTest(address=address):
                result = self.run_guard(address, "aws_db_instance", ["delete"], addresses=(address,))
                self.assertEqual(result.returncode, 1)
                self.assertIn("does not support quoted instance keys", result.stderr)


if __name__ == "__main__":
    unittest.main()
