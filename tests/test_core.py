import json, os, subprocess, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import kraken_cooler as k


class Core(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        k.CONFIG_DIR, k.PROFILE_DIR = d, d + "/profiles"
        k.ACTIVE_FILE, k.SETTINGS_FILE = d + "/profile", d + "/config.toml"

    def test_validate_rejects_bad_input(self):
        self.assertTrue(k.validate(10, [[30, 50]]))              # pump below device minimum
        self.assertTrue(k.validate(80, [[30, 50], [30, 60]]))    # duplicate temperature
        self.assertTrue(k.validate(80, [[10, 50]]))              # below 20 C
        self.assertTrue(k.validate(80, [[30, 120]]))             # duty > 100
        self.assertTrue(k.validate(80, [[20 + i, 50] for i in range(11)]))  # 11 points
        self.assertEqual(k.validate(80, [[28, 40], [45, 100]]), [])

    def test_interp_matches_device_clamping(self):
        fan = [[30, 20], [40, 60]]
        self.assertEqual(k.interp(fan, 25), 20)
        self.assertEqual(k.interp(fan, 35), 40)
        self.assertEqual(k.interp(fan, 59), 60)

    def test_warnings_use_configurable_thresholds(self):
        self.assertEqual(k.warnings(80, [[28, 40], [45, 100]]), [])
        self.assertEqual(len(k.warnings(30, [[28, 40], [50, 50]])), 2)
        open(k.SETTINGS_FILE, "w").write("[warn]\nfan_min = 30\npump_min = 20\n")
        self.assertEqual(k.warnings(30, [[28, 40], [50, 50]]), [])

    def test_save_load_delete_roundtrip(self):
        k.save_profile("mine", 70, [[25, 30], [50, 90]])
        self.assertEqual(k.load_profile("mine")["fan"], [[25, 30], [50, 90]])
        self.assertIn("mine", k.list_profiles())
        k.set_active("mine"); k.delete_profile("mine")
        self.assertNotIn("mine", k.list_profiles())

    def test_builtin_protected_and_names_safe(self):
        with self.assertRaises(ValueError): k.save_profile("balanced", 80, [[30, 50]])
        with self.assertRaises(ValueError): k.delete_profile("quiet")
        with self.assertRaises(ValueError): k.save_profile("../evil", 80, [[30, 50]])
        with self.assertRaises(ValueError): k.save_profile("bad", 10, [[30, 50]])  # nothing written
        self.assertNotIn("bad", k.list_profiles())

    def test_builtins_are_valid(self):
        for n, p in k.BUILTIN.items():
            self.assertEqual(k.validate(p["pump"], p["fan"]), [], n)


if __name__ == "__main__":
    unittest.main()
