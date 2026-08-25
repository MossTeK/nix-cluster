import unittest
import threading
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
        manager.runner = FakeRunner([1, 1])

        self.assertFalse(manager._switch_in_progress("/repo"))

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


if __name__ == "__main__":
    unittest.main()
