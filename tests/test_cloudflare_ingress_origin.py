import pathlib
import unittest


class CloudflareIngressOriginTests(unittest.TestCase):
    def test_tunnel_origin_is_separate_from_app_vip(self):
        template = pathlib.Path("templates/main.tf").read_text()

        self.assertIn('variable "vip_address"', template)
        self.assertIn('variable "ingress_origin_address"', template)
        self.assertIn("var.ingress_origin_address", template)
        self.assertNotIn('service  = "http://${var.vip_address}:80"', template)

    def test_setup_hydrates_ingress_origin_with_vip_compatibility_default(self):
        setup = pathlib.Path("src/setup.sh").read_text()

        self.assertIn("CF_INGRESS_ORIGIN", setup)
        self.assertIn('CF_INGRESS_ORIGIN="$CF_TUNNEL_VIP"', setup)
        self.assertIn("INGRESS_ORIGIN_ADDRESS_PLACEHOLDER", setup)


if __name__ == "__main__":
    unittest.main()
