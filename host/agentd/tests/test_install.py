import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "install.sh")
KNOWN_TOKEN = "".join(["tok", "-canary-", "do-not-print"])


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="agentd test ")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.bin = os.path.join(self.tmp, "fakebin")
        self.log = os.path.join(self.tmp, "calls")
        os.makedirs(self.bin)
        os.makedirs(self.log)
        self.base = os.path.join(self.tmp, "base dir")
        self.plist_dir = os.path.join(self.tmp, "agents")
        self.pi_dir = os.path.join(self.tmp, "nvm bin")
        os.makedirs(self.pi_dir)
        self.pi = self.fake("pi", dir=self.pi_dir)
        self.fake("tailscale", body='[ "$1 $2" = "ip -4" ] && printf "100.64.0.7\\n100.64.0.8\\n"')
        self.fake("dart", body='out=; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done; printf "bin" > "$out"')
        self.fake("launchctl")

    def fake(self, name, body="", dir=None):
        dir = dir or self.bin
        path = os.path.join(dir, name)
        with open(path, "w") as h:
            # One record per call: argc, then each argument on its own line.
            h.write(f'#!/bin/sh\n{{ printf "%s\\n" "$#"; for a in "$@"; do printf "%s\\n" "$a"; done; }} >> "{self.log}/{name}"\n{body}\n')
        os.chmod(path, 0o700)
        return path

    def calls(self, name):
        path = os.path.join(self.log, name)
        if not os.path.exists(path):
            return []
        with open(path) as h:
            lines = h.read().splitlines()
        out = []
        while lines:
            n = int(lines.pop(0))
            out.append(lines[:n])
            lines = lines[n:]
        return out

    def run_sh(self, *args, path=None):
        env = dict(os.environ)
        env["PATH"] = (path if path is not None else self.bin + ":" + self.pi_dir + ":/usr/bin:/bin")
        env.pop("HELM_AGENTD_DIR", None)
        return subprocess.run(
            ["/bin/sh", SCRIPT, "--base-dir", self.base, "--plist-dir", self.plist_dir, *args],
            capture_output=True, text=True, env=env, timeout=60)

    def plist(self):
        with open(os.path.join(self.plist_dir, "dev.helm.agentd.plist"), "rb") as h:
            return plistlib.load(h)

    def test_dry_run_writes_nothing_and_prints_plan(self):
        r = self.run_sh("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dry-run", r.stdout)
        self.assertIn("dart compile exe", r.stdout)
        self.assertIn("100.64.0.7:7480", r.stdout)
        self.assertIn("launchctl bootstrap", r.stdout)
        self.assertFalse(os.path.exists(self.base))
        self.assertFalse(os.path.exists(self.plist_dir))
        self.assertEqual(self.calls("dart"), [])
        self.assertEqual(self.calls("launchctl"), [])

    def test_real_run_renders_valid_plist(self):
        r = self.run_sh()
        self.assertEqual(r.returncode, 0, r.stderr)
        p = self.plist()
        self.assertEqual(p["Label"], "dev.helm.agentd")
        self.assertEqual(p["ProgramArguments"], [
            os.path.join(self.base, "bin", "helm-agentd"),
            "--host", "100.64.0.7", "--port", "7480",
            "--pi", self.pi,
            "--session-dir", os.path.join(self.base, "sessions"),
            "--token-file", os.path.join(self.base, "token"),
        ])
        self.assertEqual(p["EnvironmentVariables"]["PATH"], self.pi_dir + ":/usr/bin:/bin:/usr/sbin:/sbin")
        self.assertEqual(p["Umask"], 63)
        self.assertTrue(p["KeepAlive"])
        self.assertEqual(p["ThrottleInterval"], 10)
        self.assertTrue(p["RunAtLoad"])
        self.assertEqual(p["StandardOutPath"], os.path.join(self.base, "agentd.out"))
        self.assertEqual(self.calls("launchctl"), [])
        self.assertNotIn("running:", r.stdout)
        self.assertEqual(len(self.calls("dart")), 1)
        self.assertEqual(self.calls("dart")[0][:2], ["compile", "exe"])

    def test_load_calls_launchctl_with_three_args(self):
        r = self.run_sh("--load")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.calls("launchctl")
        self.assertEqual(len(calls), 1)
        plist = os.path.join(self.plist_dir, "dev.helm.agentd.plist")
        self.assertIn(" ", plist)
        self.assertEqual(calls[0], ["bootstrap", f"gui/{os.getuid()}", plist])

    def test_dart_receives_separate_arguments(self):
        self.assertEqual(self.run_sh().returncode, 0)
        args = self.calls("dart")[0]
        binary = os.path.join(self.base, "bin", "helm-agentd")
        self.assertEqual(len(args), 5)
        self.assertEqual(args[:2], ["compile", "exe"])
        self.assertTrue(args[2].endswith("packages/helm_agentd/bin/helm_agentd.dart"), args[2])
        self.assertEqual(args[3:], ["-o", binary + ".tmp"])

    def test_explicit_pi_and_port_and_host(self):
        other = self.fake("mypi", dir=self.pi_dir)
        r = self.run_sh("--pi", other, "--port", "9000", "--host", "100.100.0.1")
        self.assertEqual(r.returncode, 0, r.stderr)
        args = self.plist()["ProgramArguments"]
        self.assertEqual(args[2:7], ["100.100.0.1", "--port", "9000", "--pi", other])
        self.assertEqual(self.calls("tailscale"), [])

    def test_non_tailnet_host_refused_without_flag(self):
        for host in ("192.168.1.5", "100.63.0.1", "100.128.0.1", "8.8.8.8"):
            r = self.run_sh("--host", host)
            self.assertNotEqual(r.returncode, 0, host)
            self.assertIn("allow-non-tailnet", r.stderr)
        self.assertFalse(os.path.exists(self.plist_dir))
        r = self.run_sh("--host", "192.168.1.5", "--allow-non-tailnet")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_loopback_allowed(self):
        self.assertEqual(self.run_sh("--host", "127.0.0.1").returncode, 0)

    def test_all_interfaces_always_refused(self):
        for extra in ((), ("--allow-non-tailnet",)):
            r = self.run_sh("--host", ".".join(["0"] * 4), *extra)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("all interfaces", r.stderr)
        self.assertFalse(os.path.exists(self.plist_dir))

    def test_malformed_host_refused(self):
        for host in ("100.64.0", "100.64.0.256", "abc", "100.64.0.1.2", "100.64.*.1"):
            r = self.run_sh("--host", host, "--allow-non-tailnet")
            self.assertNotEqual(r.returncode, 0, host)

    def assert_refused_nothing_written(self, r, label):
        self.assertNotEqual(r.returncode, 0, label)
        self.assertTrue(r.stderr.strip(), label)
        self.assertFalse(os.path.exists(self.base), label)
        self.assertFalse(os.path.exists(self.plist_dir), label)
        self.assertEqual(self.calls("dart"), [], label)

    def test_non_canonical_ipv4_refused(self):
        bad = ("100.64.0.1.", ".100.64.0.1", "100.064.0.1", "100.64.0.01",
               "100.64.0.1.2", "100.64.0", "100.64.0.1 ", " 100.64.0.1",
               "100. 64.0.1", "100.64.0.1\n", "myhost.example", "::1",
               "fd7a:115c:a1e0::1", "100..64.1")
        for host in bad:
            r = self.run_sh("--host", host, "--allow-non-tailnet")
            self.assert_refused_nothing_written(r, repr(host))
            self.assertIn("invalid IPv4", r.stderr, repr(host))

    def test_empty_explicit_host_is_usage_error(self):
        r = self.run_sh("--host", "")
        self.assert_refused_nothing_written(r, "empty")
        self.assertEqual(r.returncode, 64)
        self.assertEqual(self.calls("tailscale"), [])

    def test_tailscale_non_canonical_output_refused(self):
        for out in ("100.64.0.1.", "100.064.0.1", "fd7a:115c:a1e0::1", "myhost", "100.64.0"):
            self.fake("tailscale", body=f'printf "%s\\n" "{out}"')
            r = self.run_sh()
            self.assert_refused_nothing_written(r, out)
            self.assertIn("invalid IPv4", r.stderr, out)

    def test_tailscale_only_first_line_used(self):
        self.fake("tailscale", body='printf "100.64.0.7\\nfd7a::1\\n"')
        self.assertEqual(self.run_sh().returncode, 0)
        self.assertIn("100.64.0.7", self.plist()["ProgramArguments"])

    def test_tailscale_resolved_ip_is_validated(self):
        self.fake("tailscale", body='printf "192.168.9.9\\n"')
        r = self.run_sh()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Tailscale range", r.stderr)

    def test_missing_tailscale_fails_clearly(self):
        os.remove(os.path.join(self.bin, "tailscale"))
        r = self.run_sh(path=self.bin + ":/usr/bin:/bin")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("tailscale", r.stderr)
        self.assertFalse(os.path.exists(self.plist_dir))

    def test_tailscale_without_address_fails_clearly(self):
        self.fake("tailscale", body="exit 1")
        r = self.run_sh()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no IPv4", r.stderr)

    def test_missing_pi_fails_clearly(self):
        os.remove(self.pi)
        r = self.run_sh()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("pi", r.stderr)
        self.assertFalse(os.path.exists(self.plist_dir))

    def test_pi_must_be_executable_and_absolute(self):
        plain = os.path.join(self.pi_dir, "plain")
        open(plain, "w").close()
        self.assertNotEqual(self.run_sh("--pi", plain).returncode, 0)
        self.assertNotEqual(self.run_sh("--pi", "pi").returncode, 0)

    def test_special_characters_refused(self):
        for bad in ("a&b", "a<b"):
            r = self.run_sh("--base-dir", os.path.join(self.tmp, bad))
            self.assertNotEqual(r.returncode, 0, bad)

    def test_control_characters_refused_per_source(self):
        for ctl in ("\n", "\t", "\r", "\x01"):
            cases = {
                "base-dir": ("--base-dir", os.path.join(self.tmp, "b" + ctl + "x")),
                "label": ("--label", "dev.x" + ctl + "y"),
                "plist-dir": ("--plist-dir", os.path.join(self.tmp, "p" + ctl + "x")),
                "host": ("--host", "100.64.0.1" + ctl),
            }
            for name, args in cases.items():
                r = subprocess.run(
                    ["/bin/sh", SCRIPT, "--base-dir", self.base, "--plist-dir", self.plist_dir]
                    + [a for a in args],
                    capture_output=True, text=True, timeout=60,
                    env={"PATH": self.bin + ":" + self.pi_dir + ":/usr/bin:/bin"})
                self.assertNotEqual(r.returncode, 0, (name, ctl))
                self.assertFalse(os.path.exists(self.base) and name != "base-dir", (name, ctl))
                self.assertFalse(os.path.exists(os.path.join(self.tmp, "b" + ctl + "x")), (name, ctl))
                self.assertFalse(os.path.exists(os.path.join(self.tmp, "p" + ctl + "x")), (name, ctl))
                self.assertFalse(os.path.exists(self.plist_dir), (name, ctl))
            weird = self.fake("p" + ctl + "i", dir=self.pi_dir)
            r = self.run_sh("--pi", weird)
            self.assertNotEqual(r.returncode, 0, ("pi", ctl))
            self.assertFalse(os.path.exists(self.plist_dir), ("pi", ctl))
            self.assertFalse(os.path.exists(self.base), ("pi", ctl))
            self.assertEqual(self.calls("dart"), [])

    def test_modes(self):
        r = self.run_sh()
        self.assertEqual(r.returncode, 0, r.stderr)
        for d in (self.base, os.path.join(self.base, "bin"), os.path.join(self.base, "sessions")):
            self.assertEqual(mode(d), 0o700, d)
        self.assertEqual(mode(os.path.join(self.base, "bin", "helm-agentd")), 0o700)
        for f in ("agentd.out", "agentd.err"):
            self.assertEqual(mode(os.path.join(self.base, f)), 0o600, f)
        self.assertFalse(os.path.exists(os.path.join(self.base, "token")))

    def test_loose_preexisting_files_tightened(self):
        os.makedirs(self.base)
        os.chmod(self.base, 0o750)
        out = os.path.join(self.base, "agentd.out")
        with open(out, "w") as h:
            h.write("x")
        os.chmod(out, 0o644)
        self.assertEqual(self.run_sh().returncode, 0)
        self.assertEqual(mode(self.base), 0o700)
        self.assertEqual(mode(out), 0o600)

    def test_idempotent(self):
        self.assertEqual(self.run_sh().returncode, 0)
        with open(os.path.join(self.plist_dir, "dev.helm.agentd.plist"), "rb") as h:
            first = h.read()
        r = self.run_sh()
        self.assertEqual(r.returncode, 0, r.stderr)
        with open(os.path.join(self.plist_dir, "dev.helm.agentd.plist"), "rb") as h:
            self.assertEqual(h.read(), first)
        self.assertEqual(mode(os.path.join(self.base, "bin", "helm-agentd")), 0o700)

    def test_token_never_printed(self):
        os.makedirs(self.base)
        os.chmod(self.base, 0o700)
        token = os.path.join(self.base, "token")
        with open(token, "w") as h:
            h.write(KNOWN_TOKEN)
        os.chmod(token, 0o600)
        for args in (("--dry-run",), (), ("--load",)):
            r = self.run_sh(*args)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn(KNOWN_TOKEN, r.stdout + r.stderr)
            self.assertIn(token, r.stdout)
        with open(token) as h:
            self.assertEqual(h.read(), KNOWN_TOKEN)
        self.assertEqual(mode(token), 0o600)

    def test_compile_failure_is_reported_and_leaves_no_binary(self):
        self.fake("dart", body="exit 1")
        r = self.run_sh()
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.base, "bin", "helm-agentd")))
        self.assertFalse(os.path.exists(self.plist_dir))

    def test_unknown_option(self):
        self.assertEqual(self.run_sh("--bogus").returncode, 64)


if __name__ == "__main__":
    unittest.main()
