import unittest
from types import SimpleNamespace

from nix_cluster.ha import HEALTHY_ACTIVE_STATES, ClusterMonitor, LocalRecoveryMonitor, WorkerReconciler, _payload_digest


class SchedulerTests(unittest.TestCase):
    def test_activating_units_are_not_considered_healthy(self):
        self.assertNotIn("activating", HEALTHY_ACTIVE_STATES)

    def test_payload_digest_ignores_observed_at_for_write_suppression(self):
        first = {
            "host": "node4",
            "unit": "demo.service",
            "load_state": "loaded",
            "active_state": "active",
            "sub_state": "running",
            "healthy": True,
            "observed_at": 100,
        }
        second = dict(first)
        second["observed_at"] = 115

        self.assertEqual(_payload_digest(first), _payload_digest(second))

    def test_unhealthy_current_owner_moves_to_next_schedulable_node(self):
        monitor = ClusterMonitor.__new__(ClusterMonitor)
        monitor.previous_targets = {}
        monitor.config = SimpleNamespace(
            ha=SimpleNamespace(
                scheduler=SimpleNamespace(default_strategy="prefer-current-healthy")
            )
        )

        target = monitor.choose_desired_owner(
            "demo.service",
            ["node2", "node4"],
            [],
            {
                "node2": {
                    "observed_at": 100,
                    "schedulable": True,
                    "controller_reachable": True,
                    "memory_available_bytes": 16,
                    "state_dir_free_bytes": 16,
                    "load_1_per_cpu": 0.1,
                },
                "node4": {
                    "observed_at": 100,
                    "schedulable": True,
                    "controller_reachable": True,
                    "memory_available_bytes": 8,
                    "state_dir_free_bytes": 8,
                    "load_1_per_cpu": 0.2,
                },
            },
            reports={
                "node2": {"healthy": False, "load_state": "loaded", "active_state": "failed"},
                "node4": {"healthy": False, "load_state": "loaded", "active_state": "inactive"},
            },
            current_owner="node2",
            now=100,
            stale_after=30,
        )

        self.assertEqual(target, "node4")

    def test_node_detail_omits_processes_and_includes_safe_resource_data(self):
        reconciler = WorkerReconciler.__new__(WorkerReconciler)
        reconciler.hostname = "node2"
        reconciler.collect_uptime_seconds = lambda: 42.0
        reconciler.collect_disk_snapshots = lambda: [
            {"filesystem": "/dev/root", "mount": "/", "size": 100, "used": 25, "available": 75, "used_percent": 25.0}
        ]

        detail = reconciler.build_node_detail(
            {
                "cpu_count": 4,
                "load_1": 0.5,
                "load_5": 0.25,
                "load_15": 0.1,
                "load_1_per_cpu": 0.125,
                "memory_total_bytes": 1000,
                "memory_available_bytes": 600,
                "schedulable": True,
                "controller_reachable": True,
            },
            {
                "demo.service": {
                    "desired_owner": "node2",
                    "desired_local": True,
                    "active_local": True,
                    "has_placement": True,
                    "last_action": "noop",
                    "last_action_reason": "already_desired_state",
                    "last_action_success": True,
                    "status_after": {
                        "load_state": "loaded",
                        "active_state": "active",
                        "sub_state": "running",
                        "healthy": True,
                        "exec_main_pid": "123",
                    },
                }
            },
            100,
        )

        self.assertEqual(detail["hostname"], "node2")
        self.assertEqual(detail["processes"], [])
        self.assertEqual(detail["cpu"]["used_percent"], 12.5)
        self.assertEqual(detail["memory"]["used"], 400)
        self.assertEqual(detail["services"][0]["main_pid"], 123)

    def test_local_recovery_starts_failed_loaded_unit(self):
        monitor = LocalRecoveryMonitor.__new__(LocalRecoveryMonitor)
        monitor.hostname = "node1"
        monitor.config = SimpleNamespace(local_recovery=SimpleNamespace(dry_run=False))
        monitor.logger = SimpleNamespace(
            warning=lambda *args, **kwargs: None,
            info=lambda *args, **kwargs: None,
            error=lambda *args, **kwargs: None,
        )
        commands = []

        def fake_run(command):
            commands.append(command)
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        monitor.run_command = fake_run
        recovered = monitor.recover_unit(
            "NetworkManager.service",
            {
                "load_state": "loaded",
                "active_state": "inactive",
                "sub_state": "dead",
                "result": "success",
            },
        )

        self.assertTrue(recovered)
        self.assertEqual(commands, [
            ["sudo", "systemctl", "reset-failed", "NetworkManager.service"],
            ["sudo", "systemctl", "start", "NetworkManager.service"],
        ])

    def test_reconciler_does_not_stop_service_when_desired_owner_is_missing(self):
        reconciler = WorkerReconciler.__new__(WorkerReconciler)
        reconciler.hostname = "node1"
        commands = []
        reconciler.run_command = lambda command: commands.append(command)

        action = reconciler.reconcile_unit(
            "portal.service",
            has_placement=True,
            desired_owner=None,
            status_before={
                "load_state": "loaded",
                "active_state": "active",
            },
        )

        self.assertEqual(action["action"], "noop")
        self.assertEqual(action["reason"], "desired_owner_missing")
        self.assertEqual(commands, [])

    def test_local_recovery_does_not_start_missing_unit(self):
        monitor = LocalRecoveryMonitor.__new__(LocalRecoveryMonitor)
        monitor.hostname = "node1"
        monitor.config = SimpleNamespace(local_recovery=SimpleNamespace(dry_run=False))
        monitor.logger = SimpleNamespace(
            warning=lambda *args, **kwargs: None,
            info=lambda *args, **kwargs: None,
            error=lambda *args, **kwargs: None,
        )
        commands = []
        monitor.run_command = lambda command: commands.append(command)

        recovered = monitor.recover_unit(
            "missing.service",
            {
                "load_state": "not-found",
                "active_state": "inactive",
                "sub_state": "dead",
            },
        )

        self.assertFalse(recovered)
        self.assertEqual(commands, [])


if __name__ == "__main__":
    unittest.main()
