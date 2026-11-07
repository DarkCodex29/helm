import base64
import json
import os
import stat
import subprocess
import unittest
from unittest import mock

from support import FIXTURES, IsolatedEnv

import fcm


def b64d(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class PayloadShapeTest(unittest.TestCase):
    def test_message_shape(self):
        msg = fcm.build_message("tok", "Title", "Body", data={"n": 3, "s": "x"}, tag="w1:p1")
        self.assertEqual(msg, {
            "token": "tok",
            "notification": {"title": "Title", "body": "Body"},
            "data": {"n": "3", "s": "x"},
            "android": {"priority": "high", "notification": {
                "click_action": "FLUTTER_NOTIFICATION_CLICK", "tag": "w1:p1"}},
        })

    def test_no_tag_no_data(self):
        msg = fcm.build_message("tok", "T", "B")
        self.assertEqual(msg["data"], {})
        self.assertNotIn("tag", msg["android"]["notification"])


class SendTest(IsolatedEnv):
    def setUp(self):
        super().setUp()
        with open(os.path.join(FIXTURES, "service-account.fake.json")) as h:
            os.environ["HELM_NOTIFIER_CREDENTIALS"] = self.write("sa.json", h.read())
        fcm._cached.update({"token": "cached-access", "expires_at": 9e12})

    def test_send_posts_v1_payload_with_bearer(self):
        seen = {}

        class Resp:
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return b'{"name": "projects/p/messages/1"}'

        def fake_urlopen(req, timeout=None):
            seen["url"], seen["body"] = req.full_url, json.loads(req.data)
            seen["auth"] = req.get_header("Authorization")
            return Resp()

        with mock.patch("netsafe.urlopen", fake_urlopen):
            name = fcm.send("tok", "T", "B", data={"k": "v"}, tag="p", validate_only=True)
        self.assertEqual(name, "projects/p/messages/1")
        self.assertEqual(seen["url"], "https://fcm.googleapis.com/v1/projects/fake-project-0000/messages:send")
        self.assertEqual(seen["auth"], "Bearer cached-access")
        self.assertTrue(seen["body"]["validate_only"])
        self.assertEqual(seen["body"]["message"]["token"], "tok")

    def test_non_json_response_is_a_runtime_error(self):
        class Resp:
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return b"<html>502</html>"
        with mock.patch("netsafe.urlopen", lambda req, timeout=None: Resp()), \
             self.assertRaises(RuntimeError):
            fcm.send("tok", "T", "B")

    def test_non_https_url_is_refused(self):
        import urllib.request
        with self.assertRaises(RuntimeError):
            fcm._request_json(urllib.request.Request("file:///etc/hosts"))

    def test_missing_credentials_raise_without_leaking_content(self):
        os.environ["HELM_NOTIFIER_CREDENTIALS"] = os.path.join(self.dir, "nope.json")
        with self.assertRaises(RuntimeError):
            fcm.send("tok", "T", "B")

    def test_malformed_credentials_raise_runtime_error(self):
        os.environ["HELM_NOTIFIER_CREDENTIALS"] = self.write("bad.json", "{not json")
        with self.assertRaises(RuntimeError):
            fcm.send("tok", "T", "B")


class JwtSigningTest(IsolatedEnv):
    ACCOUNT = {"client_email": "fake-sa@fake-project-0000.example.invalid",
               "private_key": "FAKE-NOT-A-REAL-KEY-MATERIAL"}

    def test_openssl_invoked_with_sha256_sign_and_pem_path(self):
        calls = []

        def fake_run(argv, input=None, capture_output=False, **kw):
            calls.append((argv, input))
            return subprocess.CompletedProcess(argv, 0, stdout=b"\x01\x02sig", stderr=b"")

        with mock.patch("subprocess.run", fake_run):
            assertion = fcm.build_assertion(self.ACCOUNT, "key.pem", 1000)
        self.assertEqual(calls[0][0], ["openssl", "dgst", "-sha256", "-sign", "key.pem"])
        header, claims, signature = assertion.split(".")
        self.assertEqual(calls[0][1], (header + "." + claims).encode())
        self.assertEqual(json.loads(b64d(header)), {"alg": "RS256", "typ": "JWT"})
        self.assertEqual(json.loads(b64d(claims)), {
            "iss": self.ACCOUNT["client_email"], "scope": fcm.SCOPE,
            "aud": fcm.TOKEN_URL, "iat": 1000, "exp": 4600})
        self.assertEqual(b64d(signature), b"\x01\x02sig")

    def test_openssl_failure_raises(self):
        def fake_run(argv, input=None, capture_output=False, **kw):
            return subprocess.CompletedProcess(argv, 1, stdout=b"", stderr=b"boom")
        with mock.patch("subprocess.run", fake_run), self.assertRaises(RuntimeError):
            fcm.build_assertion(self.ACCOUNT, "key.pem", 1000)

    def _run_with_pem(self, outcome, account=None):
        """Run the signer with a fake openssl; return what it observed."""
        account = account or self.ACCOUNT
        seen = {}

        def fake_run(argv, input=None, capture_output=False, **kw):
            pem = argv[-1]
            seen.update(argv=argv, kw=kw, pem=pem,
                        mode=stat.S_IMODE(os.stat(pem).st_mode),
                        dir_mode=stat.S_IMODE(os.stat(os.path.dirname(pem)).st_mode))
            with open(pem) as h:
                seen["content"] = h.read()
            if outcome == "timeout":
                raise subprocess.TimeoutExpired(argv, kw.get("timeout"))
            code = 0 if outcome == "ok" else 1
            return subprocess.CompletedProcess(argv, code, stdout=b"sig", stderr=b"boom")

        with mock.patch("subprocess.run", fake_run):
            try:
                with fcm._private_key_pem(account) as pem:
                    fcm._sign_rs256(b"msg", pem)
                seen["error"] = None
            except RuntimeError as exc:
                seen["error"] = exc
        return seen

    def test_pem_is_private_temp_and_removed_after_success(self):
        seen = self._run_with_pem("ok")
        self.assertIsNone(seen["error"])
        self.assertEqual(seen["mode"], 0o600)
        self.assertEqual(seen["dir_mode"], 0o700)
        self.assertEqual(seen["content"], self.ACCOUNT["private_key"])
        self.assertFalse(os.path.exists(seen["pem"]))
        self.assertFalse(os.path.exists(os.path.dirname(seen["pem"])))

    def test_pem_is_removed_after_openssl_failure(self):
        seen = self._run_with_pem("fail")
        self.assertIsInstance(seen["error"], RuntimeError)
        self.assertFalse(os.path.exists(seen["pem"]))

    def test_openssl_timeout_is_a_clear_error_without_key_material(self):
        seen = self._run_with_pem("timeout")
        self.assertIsInstance(seen["error"], RuntimeError)
        self.assertIn("timed out", str(seen["error"]))
        self.assertNotIn(self.ACCOUNT["private_key"], str(seen["error"]))
        self.assertFalse(os.path.exists(seen["pem"]))

    def test_openssl_runs_with_a_timeout_and_no_key_in_argv(self):
        seen = self._run_with_pem("ok")
        self.assertIsNotNone(seen["kw"].get("timeout"))
        self.assertLessEqual(seen["kw"]["timeout"], 30)
        for arg in seen["argv"]:
            self.assertNotIn(self.ACCOUNT["private_key"], arg)

    def test_a_preexisting_pem_is_never_reused(self):
        stale = os.path.join(self.dir, "fcm-sa.pem")
        with open(stale, "w") as h:
            h.write("STALE-LOOSE-PEM")
        os.chmod(stale, 0o644)
        seen = self._run_with_pem("ok")
        self.assertEqual(seen["content"], self.ACCOUNT["private_key"])
        self.assertNotEqual(seen["pem"], stale)

    def test_redirect_to_http_is_refused(self):
        import urllib.request
        import netsafe
        handler = netsafe.HttpsOnlyRedirect()
        req = urllib.request.Request("https://example.invalid/a", data=b"x", method="POST")
        with self.assertRaises(RuntimeError):
            handler.redirect_request(req, None, 302, "Found", {}, "http://example.invalid/b")
        ok = handler.redirect_request(req, None, 302, "Found", {}, "https://example.invalid/b")
        self.assertIsNotNone(ok)

    def test_access_token_mints_through_mocked_openssl_and_http(self):
        fcm._cached.update({"token": None, "expires_at": 0})
        os.environ["HELM_NOTIFIER_CREDENTIALS"] = self.write("sa.json", json.dumps(self.ACCOUNT))

        class Resp:
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return b'{"access_token": "minted-access-token", "expires_in": 3600}'

        sent = {}

        def fake_urlopen(req, timeout=None):
            sent["url"], sent["body"] = req.full_url, req.data.decode()
            return Resp()

        def fake_run(argv, input=None, capture_output=False, **kw):
            return subprocess.CompletedProcess(argv, 0, stdout=b"sig", stderr=b"")

        with mock.patch("subprocess.run", fake_run), mock.patch("netsafe.urlopen", fake_urlopen):
            self.assertEqual(fcm.access_token(), "minted-access-token")
            self.assertEqual(fcm.access_token(), "minted-access-token")  # cached
        self.assertEqual(sent["url"], fcm.TOKEN_URL)
        self.assertIn("jwt-bearer", sent["body"])
        fcm._cached.update({"token": None, "expires_at": 0})


class TokenFileTest(IsolatedEnv):
    def load(self, text=None):
        if text is not None:
            os.environ["HELM_NOTIFIER_TOKENS"] = self.write("tokens.json", text)
        return fcm.device_tokens()

    def test_fixture_loads(self):
        with open(os.path.join(FIXTURES, "device-tokens.fake.json")) as h:
            self.assertEqual(len(self.load(h.read())), 2)

    def test_missing_file(self):
        self.assertEqual(fcm.device_tokens(), [])

    def test_empty_file(self):
        self.assertEqual(self.load(""), [])

    def test_malformed_json(self):
        self.assertEqual(self.load("{oops"), [])

    def test_wrong_shapes(self):
        for text in ("[]", "null", '{"tokens": "abc"}', '{"tokens": {"a": 1}}', '{"other": 1}'):
            self.assertEqual(self.load(text), [], text)

    def test_junk_entries_dropped_and_duplicates_collapse(self):
        self.assertEqual(self.load('{"tokens": ["a", "", "  ", 5, null, "a", " b "]}'), ["a", "b"])

    def test_path_comes_from_env(self):
        os.environ["HELM_NOTIFIER_TOKENS"] = self.write("elsewhere.json", '{"tokens": ["z"]}')
        self.assertEqual(fcm.device_tokens(), ["z"])


if __name__ == "__main__":
    unittest.main()
