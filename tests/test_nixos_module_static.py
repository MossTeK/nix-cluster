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


if __name__ == "__main__":
    unittest.main()
