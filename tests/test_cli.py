import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from nix_cluster import cli
from nix_cluster.config import IngressRouteSettings


class FakeEtcd:
    def __init__(self, prefixes=None, keys=None):
        self.prefixes = prefixes or {}
        self.keys = keys or {}
        self.writes = {}

    def get_prefix(self, prefix):
        return self.prefixes.get(prefix, {})

    def get_key(self, key):
        value = self.keys.get(key)
        if value is None:
            return None
        return {"value": value}

    def put_json(self, key, payload):
        self.writes[key] = payload


def config():
    return SimpleNamespace(
        ha=SimpleNamespace(
            runtime_store=SimpleNamespace(type="etcd", endpoint="http://127.0.0.1:2379", stale_after_seconds=45),
            scheduler=SimpleNamespace(
                placement_prefix="/nix-cluster/scheduler/placement",
                request_prefix="/nix-cluster/scheduler/requests",
                managed_units=["demo.service", "solo.service"],
                app_groups={"demo": ["demo.service", "demo-db.service"]},
                resource_interval_seconds=15,
            ),
        ),
        ingress_router=SimpleNamespace(
            routes={
                "demo": IngressRouteSettings(
                    name="demo",
                    enable=True,
                    domain="demo.example.com",
                    aliases=[],
                    unit="demo.service",
                    scheme="http",
                    port=8080,
                    health_path="/",
                    auth="none",
                    authentik_host="",
                    authentik_port=0,
                    extra_config="",
                )
            }
        ),
    )


class CliTests(unittest.TestCase):
    def test_inventory_groups_units_and_domain(self):
        now = int(time.time())
        etcd = FakeEtcd(
            prefixes={
                "/nix-cluster/scheduler/placement": {
                    "/nix-cluster/scheduler/placement/demo.service": {
                        "active_owner": "node2",
                        "desired_owner": "node2",
                        "phase": "stable",
                    },
                    "/nix-cluster/scheduler/placement/demo-db.service": {
                        "active_owner": "node2",
                        "desired_owner": "node2",
                        "phase": "stable",
                    },
                }
            },
            keys={
                "/nix-cluster/cluster-state": {
                    "services": {
                        "demo.service": {
                            "candidate_nodes": ["node2", "node4"],
                            "reports": {"node2": {"healthy": True, "observed_at": now}},
                        },
                        "demo-db.service": {
                            "candidate_nodes": ["node2", "node4"],
                            "reports": {"node2": {"healthy": True, "observed_at": now}},
                        },
                    }
                }
            },
        )

        apps = {app.name: app for app in cli.build_inventory(config(), etcd)}

        self.assertEqual(apps["demo"].domains, ["demo.example.com"])
        self.assertEqual(apps["demo"].active_owner, "node2")
        self.assertTrue(apps["demo"].healthy)

    def test_validate_move_requires_every_group_unit_on_target(self):
        now = int(time.time())
        etcd = FakeEtcd(
            keys={
                "/nix-cluster/cluster-state": {
                    "resources": {"node4": {"observed_at": now, "schedulable": True}},
                    "services": {
                        "demo.service": {
                            "reports": {"node4": {"observed_at": now, "load_state": "loaded"}}
                        }
                    },
                }
            }
        )

        units, errors = cli.validate_move(config(), "demo", "node4", etcd, now)

        self.assertEqual(units, ["demo.service", "demo-db.service"])
        self.assertIn("target node does not report unit: demo-db.service", errors)

    def test_request_move_writes_one_request_per_unit(self):
        now = int(time.time())
        etcd = FakeEtcd(
            keys={
                "/nix-cluster/cluster-state": {
                    "resources": {"node4": {"observed_at": now, "schedulable": True}},
                    "services": {
                        "demo.service": {"reports": {"node4": {"observed_at": now, "load_state": "loaded"}}},
                        "demo-db.service": {"reports": {"node4": {"observed_at": now, "load_state": "loaded"}}},
                    },
                }
            }
        )

        with patch("builtins.print"):
            code = cli.request_move(config(), etcd, "demo", "node4", "test", dry_run=False)

        self.assertEqual(code, 0)
        self.assertEqual(sorted(etcd.writes), [
            "/nix-cluster/scheduler/requests/demo-db.service",
            "/nix-cluster/scheduler/requests/demo.service",
        ])
        self.assertEqual(etcd.writes["/nix-cluster/scheduler/requests/demo.service"]["target_owner"], "node4")


if __name__ == "__main__":
    unittest.main()
