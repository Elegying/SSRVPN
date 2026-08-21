import copy
import json
import unittest
from pathlib import Path

from scripts.verify_main_branch_protection import ProtectionError, verify


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / ".github" / "main-branch-protection.json"


def _actual_from(policy: dict[str, object]) -> dict[str, object]:
    actual = copy.deepcopy(policy)
    for key in (
        "enforce_admins",
        "required_linear_history",
        "allow_force_pushes",
        "allow_deletions",
        "block_creations",
        "required_conversation_resolution",
        "lock_branch",
        "allow_fork_syncing",
    ):
        actual[key] = {"enabled": policy[key]}
    return actual


class MainBranchProtectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.policy = json.loads(POLICY.read_text(encoding="utf-8"))

    def test_exact_policy_is_accepted(self) -> None:
        verify(self.policy, _actual_from(self.policy))

    def test_missing_or_extra_required_check_is_rejected(self) -> None:
        for checks in (
            self.policy["required_status_checks"]["checks"][:-1],
            [
                *self.policy["required_status_checks"]["checks"],
                {"context": "Unexpected", "app_id": 15368},
            ],
        ):
            actual = _actual_from(self.policy)
            actual["required_status_checks"]["checks"] = checks
            with self.assertRaisesRegex(ProtectionError, "required checks"):
                verify(self.policy, actual)

    def test_wrong_check_app_or_weakened_policy_is_rejected(self) -> None:
        wrong_app = _actual_from(self.policy)
        wrong_app["required_status_checks"]["checks"][0]["app_id"] = -1
        with self.assertRaisesRegex(ProtectionError, "required checks"):
            verify(self.policy, wrong_app)

        bypass = _actual_from(self.policy)
        bypass["enforce_admins"]["enabled"] = False
        with self.assertRaisesRegex(ProtectionError, "enforce_admins"):
            verify(self.policy, bypass)


if __name__ == "__main__":
    unittest.main()
