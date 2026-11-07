import logging.handlers
import os
import stat
import unittest
from unittest import mock

import config
import hlog
from support import IsolatedEnv

FAKE_DEVICE_ID = "fakeDeviceAAAAAAAA:APA91bFAKEFAKEFAKEFAKEFAKE0001"  # noqa: S105


class LoggingBase(IsolatedEnv):
    def setUp(self):
        super().setUp()
        self._umask = os.umask(0o022)
        self.addCleanup(os.umask, self._umask)
        self.addCleanup(hlog._secrets.clear)
        self.path = os.path.join(self.dir, "n.log")
        os.environ["HELM_NOTIFIER_LOG"] = self.path
        hlog.setup()
        self.addCleanup(self._close)

    def _close(self):
        for h in list(hlog._logger.handlers):
            hlog._logger.removeHandler(h)
            h.close()

    def read(self):
        for h in hlog._logger.handlers:
            h.flush()
        with open(self.path) as handle:
            return handle.read()


class RedactionTest(LoggingBase):
    def test_registered_secret_never_reaches_the_file(self):
        hlog.register_secret("super-secret-value")
        hlog.log("failed with super-secret-value inside")
        self.assertNotIn("super-secret-value", self.read())
        self.assertIn(hlog.REDACTED, self.read())

    def test_token_shaped_strings_are_scrubbed_without_registration(self):
        hlog.log("send failed for " + FAKE_DEVICE_ID)
        self.assertNotIn("APA91b", self.read())
        self.assertNotIn(FAKE_DEVICE_ID[-8:], self.read())

    def test_bearer_and_pem_are_scrubbed(self):
        hlog.log("Authorization: Bearer ya29.abc-DEF_123")
        hlog.log("key -----BEGIN PRIVATE KEY-----\nMIIFAKE\n-----END PRIVATE KEY-----")
        text = self.read()
        self.assertNotIn("ya29", text)
        self.assertNotIn("MIIFAKE", text)

    def test_percent_args_are_scrubbed_too(self):
        hlog.register_secret("super-secret-value")
        hlog._logger.info("x %s", "super-secret-value")
        self.assertNotIn("super-secret-value", self.read())

    def test_clip_truncates_and_flattens(self):
        self.assertEqual(hlog.clip("a\nb"), "a b")
        out = hlog.clip("x" * 500)
        self.assertEqual(len(out), hlog.TEXT_LIMIT)

    def test_loading_tokens_registers_them(self):
        import fcm
        opaque = "opaque.token.with.dots.1234"  # not matched by the shape regex
        os.environ["HELM_NOTIFIER_TOKENS"] = self.write("t.json", '{"tokens": ["' + opaque + '"]}')
        hlog.log("before load " + opaque)
        self.assertIn(opaque, self.read())
        fcm.device_tokens()
        hlog.log("after load " + opaque)
        self.assertNotIn("after load " + opaque, self.read())

    def test_notification_body_is_not_logged_by_delivery(self):
        import notifier
        long_body = "SECRET-BODY-" + "z" * 200
        with mock.patch.object(notifier.devices, "device_tokens", return_value=["tok-aaaaaaaa"]), \
             mock.patch.object(notifier.fcm, "send"):
            notifier.deliver("Proj · claude needs you", long_body, "5", "w", {})
        self.assertNotIn("SECRET-BODY", self.read())
        self.assertIn("pushed[fcm x1, ntfy x0]", self.read())

    def test_failed_send_log_has_no_token_fragment(self):
        import notifier
        device = "tok-ZZZZ1234abcd5678"  # noqa: S105
        with mock.patch.object(notifier.devices, "device_tokens", return_value=[device]), \
             mock.patch.object(notifier.fcm, "send", side_effect=OSError("down")), \
             mock.patch.object(notifier, "push"):
            notifier.deliver("T", "B", "5", "w", {})
        text = self.read()
        self.assertNotIn("abcd5678", text)
        self.assertIn("device 1/1", text)

    def test_clipped_title_never_leaks_a_secret_fragment(self):
        import notifier
        secret = "opaque.title.secret/ABCDEFGHIJKLMNOP0123456789xyz"  # noqa: S105
        hlog.register_secret(secret)
        title = secret + " · claude is done"
        with mock.patch.object(notifier.devices, "device_tokens", return_value=["tok-aaaaaaaa"]), \
             mock.patch.object(notifier.fcm, "send"):
            notifier.deliver(title, "b", "5", "w", {})
        with mock.patch.object(notifier.devices, "device_tokens", return_value=[]), \
             mock.patch("netsafe.urlopen"):
            os.environ["HELM_NOTIFIER_TOPIC"] = "some-topic-zzzz"
            notifier.push(title, "b")
        text = self.read()
        self.assertIn("pushed[fcm x1, ntfy x0]", text)
        self.assertIn("pushed[ntfy", text)
        for i in range(len(secret) - 7):
            self.assertNotIn(secret[i:i + 8], text, secret[i:i + 8])

    def test_clip_scrubs_before_truncating(self):
        hlog.register_secret("abcdefghij" * 6)
        out = hlog.clip("x" + "abcdefghij" * 6)
        self.assertNotIn("abcdefgh", out)

    def test_ntfy_topic_is_never_logged(self):
        import notifier
        os.environ["HELM_NOTIFIER_TOPIC"] = "private-topic-name"
        with mock.patch("netsafe.urlopen", side_effect=OSError("private-topic-name")):
            notifier.push("T", "B")
        self.assertNotIn("private-topic-name", self.read())


class RotationTest(LoggingBase):
    def handler(self):
        return next(h for h in hlog._logger.handlers
                    if isinstance(h, logging.handlers.RotatingFileHandler))

    def test_rotation_is_configured_1mb_x3(self):
        h = self.handler()
        self.assertEqual((h.maxBytes, h.backupCount), (1000000, 3))

    def test_log_file_is_0600_even_under_a_permissive_umask(self):
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_setup_tightens_preexisting_log_and_backups(self):
        self._close()
        for name in ("n.log", "n.log.1", "n.log.3"):
            path = os.path.join(self.dir, name)
            with open(path, "w") as h:
                h.write("old\n")
            os.chmod(path, 0o644)
        hlog.setup()
        for name in ("n.log", "n.log.1", "n.log.3"):
            mode = stat.S_IMODE(os.stat(os.path.join(self.dir, name)).st_mode)
            self.assertEqual(mode, 0o600, name)

    def test_setup_sets_umask_077(self):
        os.umask(0o022)
        hlog.setup()
        current = os.umask(0o022)
        self.assertEqual(current, 0o077)

    def test_rotation_happens_and_backups_are_capped_and_private(self):
        h = self.handler()
        h.maxBytes = 500
        for i in range(200):
            hlog.log(f"line {i} {'x' * 50}")
        names = sorted(n for n in os.listdir(self.dir) if n.startswith("n.log"))
        self.assertEqual(names, ["n.log", "n.log.1", "n.log.2", "n.log.3"])
        for n in names:
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.dir, n)).st_mode), 0o600, n)

    def test_setup_twice_does_not_stack_handlers(self):
        hlog.setup()
        hlog.setup()
        self.assertEqual(len(hlog._logger.handlers), 1)

    def test_unwritable_path_falls_back_to_stderr(self):
        with mock.patch("sys.stderr"):
            hlog.setup(os.path.join(self.path, "child", "x.log"))  # parent is a file
        self.assertIsInstance(hlog._logger.handlers[0], logging.StreamHandler)
        self.assertNotIsInstance(hlog._logger.handlers[0], logging.FileHandler)

    def test_log_path_comes_from_env(self):
        self.assertEqual(config.log_path(), self.path)


class ConfigTest(IsolatedEnv):
    def test_defaults_derive_from_install_dir(self):
        self.assertEqual(config.credentials_path(), os.path.join(self.dir, "fcm-sa.json"))
        self.assertEqual(config.tokens_path(), os.path.join(self.dir, "device-tokens.json"))
        self.assertEqual(config.log_path(), os.path.join(self.dir, "notifier.log"))

    def test_default_install_dir_is_home_helm_notifier(self):
        del os.environ["HELM_NOTIFIER_DIR"]
        self.assertEqual(config.install_dir(), os.path.expanduser("~/helm-notifier"))

    def test_topic_missing_is_empty_not_a_crash(self):
        self.assertEqual(config.topic(), "")

    def test_topic_file_and_env_override(self):
        self.write("topic", "from-file\n")
        self.assertEqual(config.topic(), "from-file")
        os.environ["HELM_NOTIFIER_TOPIC"] = "from-env"
        self.assertEqual(config.topic(), "from-env")


if __name__ == "__main__":
    unittest.main()
