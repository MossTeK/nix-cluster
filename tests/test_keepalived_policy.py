import pathlib
import unittest


class KeepalivedPolicyTests(unittest.TestCase):
    def test_keepalived_policy_options_are_declared_and_exported(self):
        flake = pathlib.Path("flake.nix").read_text()

        for option in [
            "allowedNodeRoles",
            "allowedHaRoles",
            "failWhenIneligible",
            "allowed_node_roles",
            "allowed_ha_roles",
            "fail_when_ineligible",
        ]:
            self.assertIn(option, flake)

    def test_keepalived_policy_has_strict_assertion(self):
        flake = pathlib.Path("flake.nix").read_text()

        self.assertIn("cfg.apps.keepalived.failWhenIneligible", flake)
        self.assertIn("cfg.placement.nodeRole cfg.apps.keepalived.allowedNodeRoles", flake)
        self.assertIn("cfg.placement.haRole cfg.apps.keepalived.allowedHaRoles", flake)


if __name__ == "__main__":
    unittest.main()
