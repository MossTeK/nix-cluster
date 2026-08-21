import time
import unittest

from nix_cluster.config import IngressRouteSettings
from nix_cluster.ingress import render_route_snippet, target_for_route


def route(**overrides):
    values = {
        "name": "portal",
        "enable": True,
        "domain": "portal.example.com",
        "aliases": [],
        "unit": "nix-cluster-portal.service",
        "scheme": "http",
        "port": 8090,
        "health_path": "/",
        "auth": "authentik",
        "authentik_host": "auth.example.com",
        "authentik_port": 9000,
        "extra_config": "",
    }
    values.update(overrides)
    return IngressRouteSettings(**values)


class IngressRouterTests(unittest.TestCase):
    def test_route_targets_healthy_desired_owner(self):
        now = int(time.time())
        target, reason = target_for_route(
            route(),
            {
                "nix-cluster-portal.service": {
                    "desired_owner": "node2",
                    "updated_at": now,
                }
            },
            {
                "observed_at": now,
                "services": {
                    "nix-cluster-portal.service": {
                        "reports": {
                            "node2": {
                                "observed_at": now,
                                "healthy": True,
                            }
                        }
                    }
                },
            },
            {"node2": "192.0.2.22"},
            now,
            45,
        )

        self.assertEqual(target, "http://192.0.2.22:8090")
        self.assertIsNone(reason)

    def test_stale_placement_fails_closed(self):
        now = int(time.time())
        target, reason = target_for_route(
            route(),
            {"nix-cluster-portal.service": {"desired_owner": "node2", "updated_at": now - 100}},
            {"observed_at": now, "services": {}},
            {"node2": "192.0.2.22"},
            now,
            45,
        )

        self.assertIsNone(target)
        self.assertEqual(reason, "stale placement")
        self.assertIn(" 503", render_route_snippet(route(), target, reason))

    def test_unhealthy_owner_fails_closed(self):
        now = int(time.time())
        target, reason = target_for_route(
            route(),
            {"nix-cluster-portal.service": {"desired_owner": "node2", "updated_at": now}},
            {
                "observed_at": now,
                "services": {
                    "nix-cluster-portal.service": {
                        "reports": {
                            "node2": {
                                "observed_at": now,
                                "healthy": False,
                            }
                        }
                    }
                },
            },
            {"node2": "192.0.2.22"},
            now,
            45,
        )

        self.assertIsNone(target)
        self.assertEqual(reason, "owner not healthy")

    def test_authentik_route_uses_same_backend_for_all_paths(self):
        snippet = render_route_snippet(route(), "http://192.0.2.22:8090", None)

        self.assertIn("forward_auth auth.example.com:9000", snippet)
        self.assertIn("to http://192.0.2.22:8090", snippet)
        self.assertNotIn("127.0.0.1:8090", snippet)


if __name__ == "__main__":
    unittest.main()
