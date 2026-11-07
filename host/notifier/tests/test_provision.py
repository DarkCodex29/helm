import io
import json
import unittest
import urllib.error
from contextlib import redirect_stderr
from unittest import mock

from support import IsolatedEnv

import hlog
import provision_fcm


def http_error(code, body):
    return urllib.error.HTTPError("https://x.invalid/", code, "err", {}, io.BytesIO(body))


class ProvisionErrorOutputTest(IsolatedEnv):
    def call_failing(self, code, body):
        err = io.StringIO()
        with mock.patch("netsafe.urlopen", side_effect=http_error(code, body)), \
             redirect_stderr(err), self.assertRaises(SystemExit):
            provision_fcm.call("GET", "https://x.invalid/v1/projects/secret-project-id/y", "tok")
        return err.getvalue()

    def test_status_code_is_shown_and_raw_body_is_not(self):
        body = json.dumps({"error": {"status": "PERMISSION_DENIED",
                                     "message": "denied for fake-sa@fake.example.invalid",
                                     "details": [{"blob": "RAW-BODY-MARKER" + "z" * 600}]}}).encode()
        out = self.call_failing(403, body)
        self.assertIn("403", out)
        self.assertNotIn("RAW-BODY-MARKER", out)
        self.assertLess(len(out), 450)

    def test_error_text_is_scrubbed_and_clipped(self):
        hlog.register_secret("super-secret-value-1234")
        self.addCleanup(hlog._secrets.clear)
        body = json.dumps({"error": {"message": "bad super-secret-value-1234 " + "y" * 900}}).encode()
        out = self.call_failing(400, body)
        self.assertNotIn("super-secret-value-1234", out)
        self.assertNotIn("y" * 250, out)

    def test_non_json_body_is_not_echoed(self):
        out = self.call_failing(502, b"<html>RAW-HTML-MARKER</html>")
        self.assertIn("502", out)
        self.assertNotIn("RAW-HTML-MARKER", out)

    def test_refused_redirect_fails_cleanly(self):
        err = io.StringIO()
        with mock.patch("netsafe.urlopen", side_effect=RuntimeError("refusing non-https redirect")), \
             redirect_stderr(err), self.assertRaises(SystemExit):
            provision_fcm.call("GET", "https://x.invalid/", "tok")
        self.assertIn("redirect", err.getvalue())


if __name__ == "__main__":
    unittest.main()
