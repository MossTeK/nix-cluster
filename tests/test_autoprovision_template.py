import pathlib
import unittest


class AutoprovisionTemplateTests(unittest.TestCase):
    def test_live_iso_without_reinstall_is_recovery_only(self):
        template = pathlib.Path("templates/controllerScript-autoprovision.sh").read_text()
        live_branch = template[
            template.index("# State 2: Live ISO"):
            template.index("# State 3: Base OS")
        ]

        self.assertIn('if [ "$REINSTALL" != "true" ]; then', live_branch)
        self.assertIn("provisioning skipped", live_branch)
        self.assertLess(
            live_branch.index('if [ "$REINSTALL" != "true" ]; then'),
            live_branch.index("provision_live_installer"),
        )


if __name__ == "__main__":
    unittest.main()
