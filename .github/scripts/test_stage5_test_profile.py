import unittest
from stage5_test_profile import test_scope


class ProfileGuardTests(unittest.TestCase):
    def test_main_and_other_branches_always_include_ui(self):
        for branch in ["main", "codex/other", "feature/s5-resize"]:
            self.assertEqual(test_scope({"mode": "review-red"}, branch), "full")

    def test_no_profile_uses_full_suite_on_stage5(self):
        self.assertEqual(test_scope(None, "codex/s5-10-divider-resize"), "full")

    def test_only_explicit_review_red_can_select_unit_tests(self):
        self.assertEqual(test_scope({"mode": "review-red"}, "codex/s5-10-divider-resize"), "review-red")

    def test_unknown_modes_and_arbitrary_arguments_are_rejected(self):
        for profile in [{"mode": "skip"}, {"mode": "review-red", "args": ["-skip-testing:ZenAgentTests"]}, {}]:
            with self.assertRaises(ValueError):
                test_scope(profile, "codex/s5-10-divider-resize")

    def test_resize_diagnostics_are_confined_to_the_resize_branch(self):
        profile = {"mode": "resize-diagnostic"}
        self.assertEqual(test_scope(profile, "codex/s5-10-divider-resize"), "resize-diagnostic")
        self.assertEqual(test_scope(profile, "main"), "full")
        with self.assertRaises(ValueError):
            test_scope(profile, "codex/s5-11-device-presentation")


if __name__ == "__main__":
    unittest.main()
