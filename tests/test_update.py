import unittest
import threading
import tempfile
from types import SimpleNamespace

from nix_cluster import update as update_module
from nix_cluster.update import UpdateManager


class FakeRunner:
    def __init__(self, returncodes):
        self.returncodes = list(returncodes)
        self.commands = []

    def run(self, command, **kwargs):
        self.commands.append((list(command), kwargs))
        return SimpleNamespace(returncode=self.returncodes.pop(0), stdout="", stderr="")


class UpdateManagerTests(unittest.TestCase):
    def tearDown(self):
        with update_module.PENDING_LOCK:
            update_module.PENDING_TRIGGER_ID = None

    def test_switch_in_progress_when_systemd_unit_active(self):
        manager = UpdateManager.__new__(UpdateManager)
        manager.runner = FakeRunner([0])

        self.assertTrue(manager._switch_in_progress("/repo"))
        self.assertEqual(manager.runner.commands[0][0], [
            "systemctl",
            "is-active",
            "--quiet",
            "nixos-rebuild-switch-to-configuration.service",
        ])

    def test_switch_in_progress_when_process_exists(self):
        manager = UpdateManager.__new__(UpdateManager)
        manager.runner = FakeRunner([1, 0])

        self.assertTrue(manager._switch_in_progress("/repo"))
        self.assertEqual(manager.runner.commands[1][0], ["pgrep", "-f", "switch-to-configuration switch"])

    def test_switch_not_in_progress(self):
        manager = UpdateManager.__new__(UpdateManager)
        manager.runner = FakeRunner([1, 1, 1])

        self.assertFalse(manager._switch_in_progress("/repo"))

    def test_recent_controller_switch_blocks_followup_rebuild(self):
        with tempfile.TemporaryDirectory() as state_dir:
            manager = UpdateManager.__new__(UpdateManager)
            manager.runtime_config = SimpleNamespace(
                is_controller=True,
                directories=SimpleNamespace(state=state_dir),
                update=SimpleNamespace(controller_switch_cooldown_seconds=300),
            )
            manager.hostname = "node1"
            manager._record_controller_switch_success("first")

            self.assertTrue(manager._controller_switch_in_cooldown())

    def test_worker_ignores_controller_switch_cooldown(self):
        manager = UpdateManager.__new__(UpdateManager)
        manager.runtime_config = SimpleNamespace(
            is_controller=False,
            update=SimpleNamespace(controller_switch_cooldown_seconds=300),
        )

        self.assertFalse(manager._controller_switch_in_cooldown())

    def test_post_update_refresh_restarts_and_verifies_unit_mount(self):
        calls = []

        class RefreshManager(UpdateManager):
            def _run_command(self, command, cwd, stage):
                calls.append((stage, command))
                if stage == "REFRESH-PID-nix-cluster-portal.service":
                    return "1234"
                if stage == "REFRESH-MOUNT-nix-cluster-portal.service":
                    return "/var/lib/nix-cluster-portal/fleet /home/nix-cluster/homelab-fleet zfs"
                return ""

        manager = RefreshManager.__new__(RefreshManager)
        manager.runtime_config = SimpleNamespace(
            post_update_refresh=SimpleNamespace(
                enable=True,
                units=[
                    SimpleNamespace(
                        unit="nix-cluster-portal.service",
                        restart=True,
                        verify_paths=["/var/lib/nix-cluster-portal/fleet"],
                        required_paths=["/var/lib/nix-cluster-portal/fleet/resources/apps/installed.json"],
                    )
                ],
            )
        )

        manager._refresh_post_update_units("/repo")

        self.assertIn(
            ("REFRESH-RESTART-nix-cluster-portal.service", ["sudo", "-n", "systemctl", "restart", "nix-cluster-portal.service"]),
            calls,
        )
        self.assertIn(
            (
                "REFRESH-PATH-nix-cluster-portal.service",
                [
                    "sudo",
                    "-n",
                    "nsenter",
                    "-t",
                    "1234",
                    "-m",
                    "--",
                    "test",
                    "-e",
                    "/var/lib/nix-cluster-portal/fleet/resources/apps/installed.json",
                ],
            ),
            calls,
        )

    def test_post_update_refresh_rejects_deleted_bind_mount(self):
        class RefreshManager(UpdateManager):
            def _run_command(self, command, cwd, stage):
                if stage == "REFRESH-PID-nix-cluster-portal.service":
                    return "1234"
                if stage == "REFRESH-MOUNT-nix-cluster-portal.service":
                    return "/var/lib/nix-cluster-portal/fleet zroot/home[/nix-cluster/homelab-fleet//deleted] zfs"
                return ""

        manager = RefreshManager.__new__(RefreshManager)
        manager.runtime_config = SimpleNamespace(
            post_update_refresh=SimpleNamespace(
                enable=True,
                units=[
                    SimpleNamespace(
                        unit="nix-cluster-portal.service",
                        restart=False,
                        verify_paths=["/var/lib/nix-cluster-portal/fleet"],
                        required_paths=[],
                    )
                ],
            )
        )

        with self.assertRaisesRegex(RuntimeError, "deleted source"):
            manager._refresh_post_update_units("/repo")

    def test_trigger_during_update_is_queued_and_replayed(self):
        test_case = self
        started = threading.Event()
        queued = threading.Event()
        triggers = []
        results = []
        errors = []

        class QueuedUpdateManager(UpdateManager):
            def _perform_update_once(self, trigger_id):
                triggers.append(trigger_id)
                if trigger_id == "first":
                    started.set()
                    test_case.assertTrue(queued.wait(timeout=2))
                return f"done:{trigger_id}"

        manager = QueuedUpdateManager.__new__(QueuedUpdateManager)

        def run_first_update():
            try:
                results.append(manager.perform_update("first"))
            except Exception as exc:
                errors.append(exc)

        worker = threading.Thread(target=run_first_update)
        worker.start()
        self.assertTrue(started.wait(timeout=2))

        self.assertEqual(manager.perform_update("second"), "QUEUED: update already in progress")
        queued.set()
        worker.join(timeout=2)

        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(results, ["done:first\ndone:second"])
        self.assertEqual(triggers, ["first", "second"])

    def test_controller_rebuilds_when_reset_advances_to_queued_commit(self):
        class ResetAdvanceManager(UpdateManager):
            def _fetch(self, repo_dir, stage):
                calls.append(("fetch", stage))

            def _get_changed_files(self, repo_dir):
                return []

            def _should_rebuild(self, files):
                return any(path.startswith("flake.lock") for path in files)

            def _write_controller_script(self, script):
                return "/tmp/controller.sh"

            def _reset(self, repo_dir, stage):
                calls.append(("reset", stage))

            def _rev_parse(self, repo_dir, ref, stage):
                return reset_heads.pop(0)

            def _get_changed_files_between(self, repo_dir, old_ref, new_ref):
                return ["flake.lock"]

            def _sync_declared_secrets(self, repo_dir):
                return False

            def _switch_in_progress(self, repo_dir):
                return False

            def _controller_switch_in_cooldown(self):
                return False

            def _record_controller_switch_success(self, trigger_id):
                calls.append(("record-switch", trigger_id))

            def _run_command(self, command, cwd, stage):
                calls.append(("run", stage, command))
                return ""

        manager = ResetAdvanceManager.__new__(ResetAdvanceManager)
        manager.runtime_config = SimpleNamespace(
            repo_dir="/repo",
            is_controller=True,
            controller_script="echo controller",
            update=SimpleNamespace(commands=["echo rebuild"], controller_switch_cooldown_seconds=300),
            post_update_refresh=SimpleNamespace(enable=False, units=[]),
        )
        manager.hostname = "node1"
        calls = []
        reset_heads = ["old", "new"]

        result = manager._perform_update_once("queued")

        self.assertEqual(result, "")
        self.assertIn(("run", "REBUILD", ["bash", "-c", "echo rebuild"]), calls)
        self.assertIn(("record-switch", "queued"), calls)


if __name__ == "__main__":
    unittest.main()
