import unittest
import subprocess
import tempfile
import threading
import time
from types import SimpleNamespace

from nix_cluster import ha as ha_module
from nix_cluster.ha import HEALTHY_ACTIVE_STATES, ClusterMonitor, LocalRecoveryMonitor, WorkerReconciler, _payload_digest


class SchedulerTests(unittest.TestCase):
    def monitor_with_stable_policy(self):
        monitor = ClusterMonitor.__new__(ClusterMonitor)
        monitor.previous_targets = {}
        monitor.config = SimpleNamespace(ha=SimpleNamespace(scheduler=SimpleNamespace(
            default_strategy="prefer-current-healthy",
            ownership_lease_enable=True,
            failure_threshold=3,
            recovery_threshold=2,
            minimum_owner_seconds=300,
            transition_timeout_seconds=120,
            target_cooldown_seconds=300,
        )))
        return monitor

    def test_stale_report_with_live_lease_retains_owner(self):
        monitor = self.monitor_with_stable_policy()
        state = monitor.advance_placement(
            "demo.service",
            {"desired_owner": "node2", "active_owner": "node2", "generation": 1, "phase": "stable", "updated_at": 100},
            ["node4"], [], ["node4"],
            {"node2": {"observed_at": 40, "healthy": True}},
            {"host": "node2", "generation": 1},
            100, 30,
        )
        self.assertEqual(state["desired_owner"], "node2")
        self.assertEqual(state["failure_count"], 0)
        self.assertEqual(state["phase"], "stable")

    def test_three_fresh_failures_begin_handoff(self):
        monitor = self.monitor_with_stable_policy()
        placement = {"desired_owner": "node2", "active_owner": "node2", "generation": 1, "phase": "stable", "updated_at": 100}
        for now in (100, 115, 130):
            placement.update(monitor.advance_placement(
                "demo.service", placement, ["node2", "node4"], [], ["node4", "node2"],
                {"node2": {"observed_at": now, "healthy": False}},
                {"host": "node2", "generation": 1}, now, 45,
            ))
        self.assertEqual(placement["desired_owner"], "node4")
        self.assertEqual(placement["active_owner"], "node2")
        self.assertEqual(placement["phase"], "deactivating")
        self.assertEqual(placement["generation"], 2)

    def test_operator_request_begin_handoff_without_failure(self):
        monitor = self.monitor_with_stable_policy()
        state = monitor.advance_placement(
            "demo.service",
            {"desired_owner": "node2", "active_owner": "node2", "generation": 1, "phase": "stable", "updated_at": 100},
            ["node2", "node4"], ["node2"], ["node4", "node2"],
            {
                "node2": {"observed_at": 100, "healthy": True},
                "node4": {"observed_at": 100, "healthy": False},
            },
            {"host": "node2", "generation": 1},
            100, 45,
            requested_target="node4",
        )

        self.assertEqual(state["desired_owner"], "node4")
        self.assertEqual(state["active_owner"], "node2")
        self.assertEqual(state["target_owner"], "node4")
        self.assertEqual(state["phase"], "deactivating")
        self.assertEqual(state["generation"], 2)

    def test_move_request_expires_before_handoff(self):
        monitor = self.monitor_with_stable_policy()
        target, update = monitor.move_request_target(
            "demo.service",
            {"status": "pending", "target_owner": "node4", "expires_at": 99},
            ["node4"],
            100,
        )

        self.assertIsNone(target)
        self.assertEqual(update["status"], "expired")

    def test_target_requires_lease_and_two_healthy_reports(self):
        monitor = self.monitor_with_stable_policy()
        placement = {
            "desired_owner": "node4", "active_owner": "node2", "target_owner": "node4",
            "generation": 2, "phase": "activating", "phase_started_at": 100,
        }
        for now in (110, 125):
            placement.update(monitor.advance_placement(
                "demo.service", placement, ["node2", "node4"], ["node4"], ["node4", "node2"],
                {"node4": {"observed_at": now, "healthy": True}},
                {"host": "node4", "generation": 2}, now, 45,
            ))
        self.assertEqual(placement["active_owner"], "node4")
        self.assertEqual(placement["phase"], "stable")

    def test_timed_out_transition_recovers_when_target_has_matching_lease(self):
        monitor = self.monitor_with_stable_policy()
        state = monitor.advance_placement(
            "demo.service",
            {
                "desired_owner": "node4", "active_owner": "node2", "target_owner": "node4",
                "generation": 2, "phase": "awaiting-fence", "phase_started_at": 1,
            },
            ["node2", "node4"], ["node4"], ["node4", "node2"],
            {"node4": {"observed_at": 500, "healthy": True}},
            {"host": "node4", "generation": 2}, 500, 45,
        )
        self.assertEqual(state["phase"], "verifying")
        self.assertEqual(state["success_count"], 1)

    def test_policy_excludes_overloaded_node_and_prefers_declared_node(self):
        monitor = self.monitor_with_stable_policy()
        policy = SimpleNamespace(
            preferred_nodes=["node4", "node2"],
            minimum_memory_available_bytes=2_000,
            maximum_load_per_cpu=2.0,
            require_healthy_state_storage=False,
        )
        monitor.config.ha.scheduler.unit_policies = {"demo.service": policy}
        records = {
            "node2": {"observed_at": 100, "schedulable": True, "controller_reachable": True, "memory_available_bytes": 1_000, "state_dir_free_bytes": 10_000, "load_1_per_cpu": 10.0},
            "node4": {"observed_at": 100, "schedulable": True, "controller_reachable": True, "memory_available_bytes": 4_000, "state_dir_free_bytes": 10_000, "load_1_per_cpu": 0.5},
        }
        ranked = monitor.rank_nodes_by_resources(["node2", "node4"], records, service="demo.service", now=100, stale_after=45)
        self.assertEqual(ranked, ["node4", "node2"])
        self.assertFalse(monitor.resource_record_meets_policy("demo.service", records["node2"], 100, 45))

    def test_storage_health_requires_three_fresh_successes(self):
        reconciler = WorkerReconciler.__new__(WorkerReconciler)
        reconciler.hostname = "example-node"
        reconciler.storage_healthy_observations = 0
        with tempfile.TemporaryDirectory() as probe_path:
            reconciler.config = SimpleNamespace(ha=SimpleNamespace(scheduler=SimpleNamespace(
                storage_health=SimpleNamespace(
                    enable=True,
                    command=[],
                    required_mounts=[],
                    probe_path=probe_path,
                    timeout_seconds=1,
                    healthy_observation_threshold=3,
                )
            )))
            first = reconciler.collect_storage_health(100)
            second = reconciler.collect_storage_health(101)
            third = reconciler.collect_storage_health(102)

        self.assertEqual(first["state_storage_health"], "recovering")
        self.assertEqual(second["state_storage_health"], "recovering")
        self.assertEqual(third["state_storage_health"], "healthy")
        self.assertTrue(third["state_storage_healthy"])

    def test_storage_probe_error_is_unknown_and_resets_recovery(self):
        reconciler = WorkerReconciler.__new__(WorkerReconciler)
        reconciler.hostname = "example-node"
        reconciler.storage_healthy_observations = 2
        reconciler.config = SimpleNamespace(ha=SimpleNamespace(scheduler=SimpleNamespace(
            storage_health=SimpleNamespace(
                enable=True,
                command=[],
                required_mounts=[],
                probe_path="/definitely/not/a/real/path",
                timeout_seconds=1,
                healthy_observation_threshold=3,
            )
        )))

        result = reconciler.collect_storage_health(100)

        self.assertEqual(result["state_storage_health"], "unknown")
        self.assertFalse(result["state_storage_healthy"])
        self.assertEqual(result["state_storage_healthy_observations"], 0)

    def test_required_storage_health_never_defaults_missing_state_to_healthy(self):
        monitor = self.monitor_with_stable_policy()
        monitor.config.ha.scheduler.unit_policies = {
            "demo.service": SimpleNamespace(
                preferred_nodes=[],
                minimum_memory_available_bytes=0,
                maximum_load_per_cpu=0.0,
                require_healthy_state_storage=True,
            )
        }
        resource = {"observed_at": 100, "schedulable": True}

        self.assertFalse(monitor.resource_record_meets_policy("demo.service", resource, 100, 45))

    def test_confirmed_storage_failure_initiates_handoff(self):
        monitor = self.monitor_with_stable_policy()
        state = monitor.advance_placement(
            "demo.service",
            {
                "desired_owner": "node-a",
                "active_owner": "node-a",
                "generation": 1,
                "phase": "stable",
                "updated_at": 100,
            },
            ["node-a", "node-b"],
            ["node-a", "node-b"],
            ["node-b", "node-a"],
            {
                "node-a": {"observed_at": 100, "healthy": True},
                "node-b": {"observed_at": 100, "healthy": True},
            },
            {"host": "node-a", "generation": 1},
            100,
            45,
            {
                "node-a": {
                    "observed_at": 100,
                    "schedulable": False,
                    "node_schedulable_configured": True,
                    "state_storage_health": "unhealthy",
                },
                "node-b": {
                    "observed_at": 100,
                    "schedulable": True,
                    "node_schedulable_configured": True,
                    "state_storage_health": "healthy",
                },
            },
        )

        self.assertEqual(state["desired_owner"], "node-b")
        self.assertEqual(state["target_owner"], "node-b")
        self.assertEqual(state["phase"], "deactivating")
        self.assertEqual(state["generation"], 2)

    def test_transient_store_failure_does_not_stop_before_local_lease_deadline(self):
        reconciler = WorkerReconciler.__new__(WorkerReconciler)
        reconciler.lease_lock = threading.Lock()
        reconciler.owned_leases = {"demo.service": {"deadline": time.monotonic() + 60}}
        stopped = []
        reconciler.fail_closed_stop = lambda units, reason: stopped.extend(units)
        reconciler.stop_expired_leases("TimeoutError")
        self.assertEqual(stopped, [])

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

    def test_reconciler_command_timeout_returns_failed_process(self):
        reconciler = WorkerReconciler.__new__(WorkerReconciler)

        original_run = ha_module.subprocess.run
        original_timeout = ha_module.RECONCILER_COMMAND_TIMEOUT_SECONDS

        def fake_run(command, **kwargs):
            self.assertEqual(kwargs["timeout"], 1)
            raise subprocess.TimeoutExpired(command, timeout=1, output="partial")

        try:
            ha_module.RECONCILER_COMMAND_TIMEOUT_SECONDS = 1
            ha_module.subprocess.run = fake_run
            result = reconciler.run_command(["sudo", "systemctl", "start", "hung.service"])
        finally:
            ha_module.subprocess.run = original_run
            ha_module.RECONCILER_COMMAND_TIMEOUT_SECONDS = original_timeout

        self.assertEqual(result.returncode, 124)
        self.assertIn("timed out", result.stderr)
        self.assertEqual(result.stdout, "partial")

    def test_reconciler_starts_desired_unit_without_blocking(self):
        reconciler = WorkerReconciler.__new__(WorkerReconciler)
        reconciler.hostname = "node2"
        reconciler.config = SimpleNamespace(
            ha=SimpleNamespace(scheduler=SimpleNamespace(reconciler_dry_run=False))
        )
        reconciler.logger = SimpleNamespace(
            warning=lambda *args, **kwargs: None,
            info=lambda *args, **kwargs: None,
        )
        commands = []

        def fake_run(command):
            commands.append(command)
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        reconciler.run_command = fake_run
        action = reconciler.reconcile_unit(
            "vaultwarden.service",
            has_placement=True,
            desired_owner="node2",
            status_before={
                "load_state": "loaded",
                "active_state": "inactive",
            },
        )

        self.assertEqual(action["action"], "start")
        self.assertEqual(action["reason"], "applied")
        self.assertEqual(commands, [["sudo", "systemctl", "--no-block", "start", "vaultwarden.service"]])

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
