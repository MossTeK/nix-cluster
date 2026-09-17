import time
import unittest
import subprocess
import tempfile
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from nix_cluster.config import IngressRouteSettings
from nix_cluster.ingress import IngressRouter, render_route_snippet, route_status_for_unit, target_for_route


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
    def test_route_targets_healthy_stable_active_owner(self):
        now = int(time.time())
        target, reason = target_for_route(
            route(),
            {
                "nix-cluster-portal.service": {
                    "desired_owner": "node2",
                    "active_owner": "node2",
                    "phase": "stable",
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

    def test_activating_placement_fails_closed(self):
        now = int(time.time())
        target, reason = target_for_route(
            route(),
            {
                "nix-cluster-portal.service": {
                    "desired_owner": "node3",
                    "active_owner": "node2",
                    "target_owner": "node3",
                    "phase": "activating",
                    "updated_at": now,
                }
            },
            {"observed_at": now, "services": {}},
            {"node2": "192.0.2.22", "node3": "192.0.2.23"},
            now,
            45,
        )

        self.assertIsNone(target)
        self.assertEqual(reason, "placement activating")

    def test_stale_placement_fails_closed(self):
        now = int(time.time())
        target, reason = target_for_route(
            route(),
            {"nix-cluster-portal.service": {"desired_owner": "node2", "active_owner": "node2", "phase": "stable", "updated_at": now - 100}},
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
            {"nix-cluster-portal.service": {"desired_owner": "node2", "active_owner": "node2", "phase": "stable", "updated_at": now}},
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
        self.assertEqual(reason, "owner unhealthy")

    def test_versioned_route_requires_matching_active_owner_lease(self):
        now = int(time.time())
        placement = {"desired_owner": "node4", "active_owner": "node2", "phase": "stable", "generation": 7, "updated_at": now}
        state = {"observed_at": now, "services": {"nix-cluster-portal.service": {"reports": {"node2": {"observed_at": now, "healthy": True}}}}}
        target, reason = target_for_route(
            route(), {"nix-cluster-portal.service": placement}, state, {"node2": "192.0.2.22"}, now, 45,
            {"nix-cluster-portal.service": {"host": "node4", "generation": 7}},
        )
        self.assertIsNone(target)
        self.assertEqual(reason, "ownership lease owner mismatch")

    def test_stale_owner_report_exposes_precise_route_reason(self):
        now = int(time.time())
        placement = {"desired_owner": "node2", "active_owner": "node2", "phase": "stable", "generation": 1, "updated_at": now}
        state = {"observed_at": now, "services": {"nix-cluster-portal.service": {"reports": {"node2": {"observed_at": now - 100, "healthy": True}}}}}

        target, reason = target_for_route(
            route(), {"nix-cluster-portal.service": placement}, state, {"node2": "192.0.2.22"}, now, 45,
            {"nix-cluster-portal.service": {"host": "node2", "generation": 1}},
        )
        status = route_status_for_unit(
            "nix-cluster-portal.service",
            {"nix-cluster-portal.service": placement},
            state,
            {"node2": "192.0.2.22"},
            now,
            45,
            {"nix-cluster-portal.service": {"host": "node2", "generation": 1}},
        )

        self.assertIsNone(target)
        self.assertEqual(reason, "owner report stale")
        self.assertFalse(status["usable"])
        self.assertFalse(status["health_fresh"])

    def test_missing_ownership_lease_is_not_usable(self):
        now = int(time.time())
        placement = {"desired_owner": "node2", "active_owner": "node2", "phase": "stable", "generation": 1, "updated_at": now}
        state = {"observed_at": now, "services": {"nix-cluster-portal.service": {"reports": {"node2": {"observed_at": now, "healthy": True}}}}}

        status = route_status_for_unit(
            "nix-cluster-portal.service",
            {"nix-cluster-portal.service": placement},
            state,
            {"node2": "192.0.2.22"},
            now,
            45,
            {},
        )

        self.assertFalse(status["lease_valid"])
        self.assertFalse(status["usable"])
        self.assertEqual(status["route_reason"], "ownership lease missing")

    def test_authentik_route_uses_same_backend_for_all_paths(self):
        snippet = render_route_snippet(route(), "http://192.0.2.22:8090", None)

        self.assertIn("forward_auth auth.example.com:9000", snippet)
        self.assertIn("to http://192.0.2.22:8090", snippet)
        self.assertNotIn("127.0.0.1:8090", snippet)

    def test_reload_skips_when_caddy_is_inactive(self):
        router = object.__new__(IngressRouter)
        router.router = SimpleNamespace(reload_timeout_seconds=20, reload_backoff_seconds=30, reload_lock_path="/tmp/unused.lock")
        router.logger = SimpleNamespace(info=lambda *a: None, warning=lambda *a: None, error=lambda *a: None)
        router.reload_backoff_until = 0.0

        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 3)) as run:
            router.reload_caddy()

        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0], ["systemctl", "is-active", "--quiet", "caddy.service"])

    def test_reload_timeout_enters_backoff_and_skips_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            router = object.__new__(IngressRouter)
            router.router = SimpleNamespace(
                reload_timeout_seconds=1,
                reload_backoff_seconds=30,
                reload_lock_path=str(Path(directory) / "reload.lock"),
            )
            router.logger = SimpleNamespace(info=lambda *a: None, warning=lambda *a: None, error=lambda *a: None)
            router.reload_backoff_until = 0.0

            calls = [
                subprocess.CompletedProcess(["systemctl"], 0),
                subprocess.TimeoutExpired(["sudo", "-n", "systemctl", "reload", "caddy.service"], 1),
            ]

            def fake_run(*args, **kwargs):
                result = calls.pop(0)
                if isinstance(result, Exception):
                    raise result
                return result

            with patch("subprocess.run", side_effect=fake_run) as run:
                router.reload_caddy()
                self.assertGreater(router.reload_backoff_until, time.monotonic())
                router.reload_caddy()

            self.assertEqual(run.call_count, 2)

    def test_reload_lock_prevents_pileups(self):
        with tempfile.TemporaryDirectory() as directory:
            lock_path = Path(directory) / "reload.lock"
            lock_path.touch()
            router = object.__new__(IngressRouter)
            router.router = SimpleNamespace(reload_timeout_seconds=20, reload_backoff_seconds=30, reload_lock_path=str(lock_path))
            router.logger = SimpleNamespace(info=lambda *a: None, warning=lambda *a: None, error=lambda *a: None)
            router.reload_backoff_until = 0.0

            with lock_path.open("w", encoding="utf-8") as lock_file:
                import fcntl

                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as run:
                    router.reload_caddy()

            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0], ["systemctl", "is-active", "--quiet", "caddy.service"])

    def test_reconcile_writes_route_status_and_reloads_changed_healthy_route(self):
        now = int(time.time())
        with tempfile.TemporaryDirectory() as directory:
            router = object.__new__(IngressRouter)
            router.router = SimpleNamespace(
                output_dir=str(Path(directory) / "caddy.d"),
                status_path=str(Path(directory) / "routes.json"),
                stale_after_seconds=45,
                node_addresses={"node2": "192.0.2.22"},
                routes={"portal": route()},
            )
            router.config = SimpleNamespace(ha=SimpleNamespace(scheduler=SimpleNamespace(ownership_lease_enable=True)))
            router.last_digest = ""
            router.last_route_states = {}
            router.logger = SimpleNamespace(info=lambda *a: None, warning=lambda *a: None, error=lambda *a: None)
            router.load_placements = lambda: {"nix-cluster-portal.service": {"active_owner": "node2", "phase": "stable", "generation": 1, "updated_at": now}}
            router.load_cluster_state = lambda: {"observed_at": now, "services": {"nix-cluster-portal.service": {"reports": {"node2": {"observed_at": now, "healthy": True}}}}}
            router.load_ownership = lambda: {"nix-cluster-portal.service": {"host": "node2", "generation": 1}}
            router.validate_caddy = lambda: (True, "")
            reloads = []
            router.reload_caddy = lambda: reloads.append("reload")

            self.assertTrue(router.reconcile_once())

            snippet = (Path(directory) / "caddy.d" / "portal.caddy").read_text(encoding="utf-8")
            status = json.loads((Path(directory) / "routes.json").read_text(encoding="utf-8"))
            self.assertIn("to http://192.0.2.22:8090", snippet)
            self.assertEqual(status["routes"][0]["target"], "http://192.0.2.22:8090")
            self.assertTrue(status["routes"][0]["routable"])
            self.assertEqual(reloads, ["reload"])

    def test_reconcile_writes_503_status_without_reload_when_snippet_unchanged(self):
        now = int(time.time())
        with tempfile.TemporaryDirectory() as directory:
            router = object.__new__(IngressRouter)
            router.router = SimpleNamespace(
                output_dir=str(Path(directory) / "caddy.d"),
                status_path=str(Path(directory) / "routes.json"),
                stale_after_seconds=45,
                node_addresses={"node2": "192.0.2.22"},
                routes={"portal": route()},
            )
            router.config = SimpleNamespace(ha=SimpleNamespace(scheduler=SimpleNamespace(ownership_lease_enable=True)))
            router.last_digest = ""
            router.last_route_states = {}
            router.logger = SimpleNamespace(info=lambda *a: None, warning=lambda *a: None, error=lambda *a: None)
            router.load_placements = lambda: {"nix-cluster-portal.service": {"active_owner": "node2", "phase": "stable", "generation": 1, "updated_at": now}}
            router.load_cluster_state = lambda: {"observed_at": now, "services": {"nix-cluster-portal.service": {"reports": {"node2": {"observed_at": now, "healthy": True}}}}}
            router.load_ownership = lambda: {}
            router.validate_caddy = lambda: (True, "")
            reloads = []
            router.reload_caddy = lambda: reloads.append("reload")

            self.assertTrue(router.reconcile_once())
            self.assertFalse(router.reconcile_once())

            snippet = (Path(directory) / "caddy.d" / "portal.caddy").read_text(encoding="utf-8")
            status = json.loads((Path(directory) / "routes.json").read_text(encoding="utf-8"))
            self.assertIn("ownership lease missing", snippet)
            self.assertFalse(status["routes"][0]["routable"])
            self.assertEqual(status["routes"][0]["reason"], "ownership lease missing")
            self.assertEqual(reloads, ["reload"])

    def test_failed_validation_rolls_back_snippet_and_skips_reload(self):
        now = int(time.time())
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory) / "caddy.d"
            output_dir.mkdir()
            snippet_path = output_dir / "portal.caddy"
            snippet_path.write_text('respond "old" 503\n', encoding="utf-8")
            router = object.__new__(IngressRouter)
            router.router = SimpleNamespace(
                output_dir=str(output_dir),
                status_path=str(Path(directory) / "routes.json"),
                stale_after_seconds=45,
                node_addresses={"node2": "192.0.2.22"},
                routes={"portal": route()},
            )
            router.config = SimpleNamespace(ha=SimpleNamespace(scheduler=SimpleNamespace(ownership_lease_enable=True)))
            router.last_digest = ""
            router.last_route_states = {}
            router.logger = SimpleNamespace(info=lambda *a: None, warning=lambda *a: None, error=lambda *a: None)
            router.load_placements = lambda: {"nix-cluster-portal.service": {"active_owner": "node2", "phase": "stable", "generation": 1, "updated_at": now}}
            router.load_cluster_state = lambda: {"observed_at": now, "services": {"nix-cluster-portal.service": {"reports": {"node2": {"observed_at": now, "healthy": True}}}}}
            router.load_ownership = lambda: {"nix-cluster-portal.service": {"host": "node2", "generation": 1}}
            router.validate_caddy = lambda: (False, "bad caddy")
            reloads = []
            router.reload_caddy = lambda: reloads.append("reload")

            self.assertFalse(router.reconcile_once())

            status = json.loads((Path(directory) / "routes.json").read_text(encoding="utf-8"))
            self.assertEqual(snippet_path.read_text(encoding="utf-8"), 'respond "old" 503\n')
            self.assertEqual(status["routes"][0]["validation"], "failed")
            self.assertEqual(status["routes"][0]["validation_reason"], "bad caddy")
            self.assertEqual(reloads, [])


if __name__ == "__main__":
    unittest.main()
