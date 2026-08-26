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
        self.assertIn("wait -n \"''${pids[@]}\"", text)


if __name__ == "__main__":
    unittest.main()
