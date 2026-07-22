import unittest
from types import SimpleNamespace

from nix_cluster.update import UpdateManager


class FakeRunner:
    def __init__(self, returncodes):
        self.returncodes = list(returncodes)
        self.commands = []

    def run(self, command, **kwargs):
        self.commands.append((list(command), kwargs))
        return SimpleNamespace(returncode=self.returncodes.pop(0), stdout="", stderr="")


class UpdateManagerTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
