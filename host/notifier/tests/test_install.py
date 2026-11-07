import os
import subprocess
import unittest

from support import NOTIFIER_DIR, IsolatedEnv

SCRIPT = os.path.join(NOTIFIER_DIR, "install.sh")


class InstallScriptTest(IsolatedEnv):
    def run_sh(self, *args, env=None):
        full = dict(os.environ, **(env or {}))
        return subprocess.run(["sh", SCRIPT, *args], capture_output=True, text=True, env=full, timeout=30)

    def test_dry_run_prints_plan_and_writes_nothing(self):
        target = os.path.join(self.dir, "inst")
        plist_dir = os.path.join(self.dir, "agents")
        r = self.run_sh("--dry-run", "--install-dir", target, "--plist-dir", plist_dir)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dry-run", r.stdout)
        self.assertIn(target, r.stdout)
        self.assertIn("dev.helm.notifier.plist", r.stdout)
        self.assertIn("launchctl bootstrap", r.stdout)
        self.assertFalse(os.path.exists(target))
        self.assertFalse(os.path.exists(plist_dir))

    def test_real_run_renders_template_without_loading(self):
        target = os.path.join(self.dir, "inst")
        plist_dir = os.path.join(self.dir, "agents")
        r = self.run_sh("--install-dir", target, "--plist-dir", plist_dir, "--python", "/usr/bin/python3")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("launchctl bootstrap", r.stdout)
        self.assertNotIn("running:", r.stdout)
        plist = os.path.join(plist_dir, "dev.helm.notifier.plist")
        with open(plist) as h:
            text = h.read()
        self.assertNotIn("__", text)
        self.assertIn("<string>dev.helm.notifier</string>", text)
        self.assertIn(target + "/notifier.py", text)
        self.assertEqual(oct(os.stat(target).st_mode & 0o777), "0o700")
        for name in ("notifier.py", "fcm.py", "hlog.py", "config.py", "provision_fcm.py"):
            self.assertEqual(oct(os.stat(os.path.join(target, name)).st_mode & 0o777), "0o600", name)
        for secret in ("fcm-sa.json", "device-tokens.json", "topic"):
            self.assertFalse(os.path.exists(os.path.join(target, secret)))

    def test_idempotent(self):
        target = os.path.join(self.dir, "inst")
        args = ["--install-dir", target, "--plist-dir", os.path.join(self.dir, "a")]
        self.assertEqual(self.run_sh(*args).returncode, 0)
        with open(os.path.join(target, "fcm.py"), "a") as h:
            h.write("\n# local drift\n")
        self.assertEqual(self.run_sh(*args).returncode, 0)
        with open(os.path.join(target, "fcm.py")) as h, open(os.path.join(NOTIFIER_DIR, "fcm.py")) as s:
            self.assertEqual(h.read(), s.read())

    def test_existing_credentials_are_left_alone(self):
        target = os.path.join(self.dir, "inst")
        os.makedirs(target)
        cred = os.path.join(target, "fcm-sa.json")
        with open(cred, "w") as h:
            h.write("keep-me")
        self.run_sh("--install-dir", target, "--plist-dir", os.path.join(self.dir, "a"))
        with open(cred) as h:
            self.assertEqual(h.read(), "keep-me")

    def test_unknown_option_and_bad_value_rejected(self):
        self.assertEqual(self.run_sh("--bogus").returncode, 64)
        self.assertEqual(self.run_sh("--dry-run", "--label", "a|b").returncode, 64)
        self.assertEqual(self.run_sh("--install-dir").returncode, 64)

    def test_template_has_no_owner_specific_content(self):
        with open(os.path.join(NOTIFIER_DIR, "helm-notifier.plist.template")) as h:
            text = h.read()
        for placeholder in ("__LABEL__", "__INSTALL_DIR__", "__PYTHON__"):
            self.assertIn(placeholder, text)
        self.assertNotIn("/Users/", text)


if __name__ == "__main__":
    unittest.main()
