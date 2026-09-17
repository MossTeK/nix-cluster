from pathlib import Path
import unittest


class NixOSModuleStaticTests(unittest.TestCase):
    def test_ingress_snippet_paths_are_tmpfiles_managed(self):
        flake = Path(__file__).resolve().parents[1] / "flake.nix"
        text = flake.read_text(encoding="utf-8")

        self.assertIn('"d /run/nix-cluster 0755 ${serviceUser} ${serviceGroup} -"', text)
        self.assertIn('"d ${cfg.ingressRouter.outputDir} 0755 ${serviceUser} ${serviceGroup} -"', text)
        self.assertNotIn("caddy-pre-start", text)
        self.assertNotIn("install -d -m 0755 -o ${serviceUser} -g ${serviceGroup} ${lib.escapeShellArg cfg.ingressRouter.outputDir}", text)

    def test_shared_homes_require_fixed_service_account_ids(self):
        flake = Path(__file__).resolve().parents[1] / "flake.nix"
        text = flake.read_text(encoding="utf-8")

        self.assertIn("serviceAccount.uid = lib.mkOption", text)
        self.assertIn("serviceAccount.gid = lib.mkOption", text)
        self.assertIn("cfg.serviceAccount.uid != null && cfg.serviceAccount.gid != null", text)
        self.assertIn("uid = cfg.serviceAccount.uid;", text)
        self.assertIn("gid = cfg.serviceAccount.gid;", text)

    def test_recovery_ssh_users_have_local_homes(self):
        flake = Path(__file__).resolve().parents[1] / "flake.nix"
        text = flake.read_text(encoding="utf-8")

        self.assertIn("recoverySshUsers = lib.mkOption", text)
        self.assertIn("Every services.nix-cluster.recoverySshUsers entry", text)
        self.assertIn("localAuthorizedKeysOnly = lib.mkOption", text)
        self.assertIn('lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ]', text)
        self.assertIn('home = "/var/lib/nix-cluster-recovery/${name}";', text)
        self.assertIn("openssh.authorizedKeys.keys = userCfg.authorizedKeys;", text)

    def test_nix_cluster_service_cleans_up_child_processes(self):
        flake = Path(__file__).resolve().parents[1] / "flake.nix"
        text = flake.read_text(encoding="utf-8")

        self.assertIn("pids=()", text)
        self.assertIn("trap cleanup TERM INT EXIT", text)
        self.assertIn("kill \"''${pids[@]}\"", text)
        self.assertIn('TimeoutStopSec = "20s"', text)
        self.assertIn("deadline=$((SECONDS + 10))", text)
        self.assertIn('kill -KILL "$pid"', text)
        self.assertIn("wait -n \"''${pids[@]}\"", text)

    def test_app_contracts_generate_runtime_surfaces(self):
        flake = Path(__file__).resolve().parents[1] / "flake.nix"
        text = flake.read_text(encoding="utf-8")

        self.assertIn("appContracts = lib.mkOption", text)
        self.assertIn("clusterAppContracts = lib.mkOption", text)
        self.assertIn("effectiveAppContracts = lib.recursiveUpdate cfg.appContracts cfg.clusterAppContracts", text)
        self.assertIn("contractWorkloads", text)
        self.assertIn("contractRoutes", text)
        self.assertIn("contractTrackedUnits", text)
        self.assertIn("contractUnitLabels", text)
        self.assertIn("effectiveSchedulerWorkloads", text)
        self.assertIn("effectiveIngressRoutes", text)
        self.assertIn("app_contracts = lib.mapAttrs", text)
        self.assertIn("}) effectiveAppContracts;", text)

    def test_monitoring_inventory_is_generated(self):
        flake = Path(__file__).resolve().parents[1] / "flake.nix"
        text = flake.read_text(encoding="utf-8")

        self.assertIn("monitoringTargets = lib.mapAttrs", text)
        self.assertIn("unit_labels = contractUnitLabels", text)
        self.assertIn("targets = monitoringTargets", text)
        self.assertIn("tracked_units = trackedUnits", text)
        self.assertIn('loki.relabel "journal"', text)
        self.assertIn('action = "keep"', text)

    def test_controller_switch_cooldown_is_serialized(self):
        flake = Path(__file__).resolve().parents[1] / "flake.nix"
        text = flake.read_text(encoding="utf-8")

        self.assertIn("controllerSwitchCooldownSeconds = lib.mkOption", text)
        self.assertIn("controller_switch_cooldown_seconds = cfg.update.controllerSwitchCooldownSeconds", text)


if __name__ == "__main__":
    unittest.main()
