import unittest
from types import SimpleNamespace

from nix_cluster.ha import ClusterMonitor, WorkerReconciler


class SchedulerTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
