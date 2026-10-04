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

    def test_orientation_red_selects_its_fixed_test_scope(self):
        self.assertEqual(test_scope({"mode": "orientation-red"}, "codex/s5-11-device-presentation"), "orientation-red")

    def test_sidebar_red_is_fixed_to_its_slice_branch(self):
        profile = {"mode": "sidebar-red"}
        self.assertEqual(test_scope(profile, "codex/s5-12-sidebar"), "sidebar-red")
        self.assertEqual(test_scope(profile, "main"), "full")
        self.assertEqual(test_scope(None, "codex/s5-12-sidebar"), "full")
        for branch in ["codex/s5-11-device-presentation", "codex/s5-13-search"]:
            with self.assertRaises(ValueError):
                test_scope(profile, branch)

    def test_orientation_profile_cannot_select_other_slice_tests(self):
        with self.assertRaises(ValueError):
            test_scope({"mode": "orientation-red"}, "codex/s5-10-divider-resize")

    def test_search_red_is_fixed_to_its_slice_branch(self):
        profile = {"mode": "search-red"}
        self.assertEqual(test_scope(profile, "codex/s5-13-search"), "search-red")
        self.assertEqual(test_scope(profile, "main"), "full")
        self.assertEqual(test_scope(None, "codex/s5-13-search"), "full")
        for branch in ["codex/s5-12-sidebar", "codex/s5-14-files"]:
            with self.assertRaises(ValueError):
                test_scope(profile, branch)

    def test_unknown_modes_and_arbitrary_arguments_are_rejected(self):
        for profile in [{"mode": "skip"}, {"mode": "review-red", "args": ["-skip-testing:ZenAgentTests"]}, {}]:
            with self.assertRaises(ValueError):
                test_scope(profile, "codex/s5-10-divider-resize")

    def test_files_red_is_fixed_to_its_slice_branch(self):
        profile = {"mode": "files-red"}
        self.assertEqual(test_scope(profile, "codex/s5-14-files"), "files-red")
        self.assertEqual(test_scope(profile, "main"), "full")
        self.assertEqual(test_scope(None, "codex/s5-14-files"), "full")
        for branch in ["codex/s5-13-search", "codex/s5-15-settings"]:
            with self.assertRaises(ValueError):
                test_scope(profile, branch)
        with self.assertRaises(ValueError):
            test_scope({"mode": "files-red", "args": ["-skip-testing:ZenAgentTests"]}, "codex/s5-14-files")

    def test_resize_diagnostics_are_confined_to_the_resize_branch(self):
        profile = {"mode": "resize-diagnostic"}
        self.assertEqual(test_scope(profile, "codex/s5-10-divider-resize"), "resize-diagnostic")
        self.assertEqual(test_scope(profile, "main"), "full")
        with self.assertRaises(ValueError):
            test_scope(profile, "codex/s5-11-device-presentation")


if __name__ == "__main__":
    unittest.main()
