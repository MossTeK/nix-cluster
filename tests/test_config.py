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

    def test_unsafe_legacy_managed_units_are_rejected(self):
        config = RuntimeConfig.from_raw(
            "/tmp/nix-cluster-runtime-config.json",
            {
                "ha": {
                    "scheduler": {
                        "managed_units": [
                            "demo.service",
                            "nix-cluster.service",
                            "caddy.service",
                            "cloudflared.service",
                            "keepalived.service",
                            "NetworkManager.service",
                            "authentik-server.service",
                            "postgresql.service",
                        ],
                    },
                },
            },
        )

        self.assertEqual(config.ha.scheduler.managed_units, ["demo.service"])
        self.assertEqual(
            config.ha.scheduler.rejected_managed_units,
            [
                "nix-cluster.service",
                "caddy.service",
                "cloudflared.service",
                "keepalived.service",
                "NetworkManager.service",
                "authentik-server.service",
                "postgresql.service",
            ],
        )

    def test_controller_switch_cooldown_defaults_to_five_minutes(self):
        config = RuntimeConfig.from_raw(
            "/tmp/nix-cluster-runtime-config.json",
            {
                "update": {},
            },
        )

        self.assertEqual(config.update.controller_switch_cooldown_seconds, 300)

    def test_enabled_workloads_define_managed_units_and_groups(self):
        config = RuntimeConfig.from_raw(
            "/tmp/nix-cluster-runtime-config.json",
            {
                "ha": {
                    "scheduler": {
                        "workloads": {
                            "notes": {"units": ["outline.service"], "group": "office"},
                            "disabled": {"enable": False, "units": ["disabled.service"]},
                        },
                    },
                },
            },
        )

        self.assertEqual(config.ha.scheduler.managed_units, ["outline.service"])
        self.assertEqual(config.ha.scheduler.app_groups, {"office": ["outline.service"]})

    def test_app_contracts_are_exposed_to_runtime_tools(self):
        config = RuntimeConfig.from_raw(
            "/tmp/nix-cluster-runtime-config.json",
            {
                "app_contracts": {
                    "notes": {
                        "enable": True,
                        "units": ["outline.service", "outline-redis.service"],
                        "primary_unit": "outline.service",
                        "port": 3000,
                        "domain": "notes.example.com",
                        "route_name": "notes",
                        "shared_state": {
                            "required": True,
                            "root": "/srv/nix-cluster/apps/outline",
                            "mounts": ["/srv/nix-cluster"],
                        },
                        "placement": {
                            "ha": True,
                            "preferred_nodes": ["node2"],
                            "require_healthy_state_storage": True,
                        },
                    },
                },
            },
        )

        contract = config.app_contracts["notes"]
        self.assertTrue(contract.enable)
        self.assertEqual(contract.primary_unit, "outline.service")
        self.assertEqual(contract.port, 3000)
        self.assertEqual(contract.shared_state_root, "/srv/nix-cluster/apps/outline")
        self.assertEqual(contract.preferred_nodes, ["node2"])


if __name__ == "__main__":
    unittest.main()
