import unittest

from nix_cluster.config import RuntimeConfig


class RuntimeConfigTests(unittest.TestCase):
    def test_managed_units_default_to_ownership_leases_for_legacy_configs(self):
        config = RuntimeConfig.from_raw(
            "/tmp/nix-cluster-runtime-config.json",
            {
                "ha": {
                    "scheduler": {
                        "managed_units": ["demo.service"],
                    },
                },
            },
        )

        self.assertTrue(config.ha.scheduler.ownership_lease_enable)

    def test_explicit_ownership_lease_opt_out_is_preserved(self):
        config = RuntimeConfig.from_raw(
            "/tmp/nix-cluster-runtime-config.json",
            {
                "ha": {
                    "scheduler": {
                        "managed_units": ["demo.service"],
                        "ownership_lease_enable": False,
                    },
                },
            },
        )

        self.assertFalse(config.ha.scheduler.ownership_lease_enable)

    def test_empty_scheduler_does_not_enable_ownership_leases(self):
        config = RuntimeConfig.from_raw(
            "/tmp/nix-cluster-runtime-config.json",
            {
                "ha": {
                    "scheduler": {},
                },
            },
        )

        self.assertFalse(config.ha.scheduler.ownership_lease_enable)


if __name__ == "__main__":
    unittest.main()
