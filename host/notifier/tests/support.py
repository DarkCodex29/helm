"""Shared test plumbing: put the notifier on sys.path, isolate its env."""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
NOTIFIER_DIR = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")
if NOTIFIER_DIR not in sys.path:
    sys.path.insert(0, NOTIFIER_DIR)

ENV_KEYS = [
    "HELM_NOTIFIER_DIR", "HELM_NOTIFIER_CREDENTIALS", "HELM_NOTIFIER_PEM",
    "HELM_NOTIFIER_TOKENS", "HELM_NOTIFIER_LOG", "HELM_NOTIFIER_TOPIC_FILE",
    "HELM_NOTIFIER_TOPIC", "HELM_HERDR_BIN",
]


class IsolatedEnv(unittest.TestCase):
    """Every test gets a private install dir and a clean HELM_* environment."""

    def setUp(self):
        self._saved = {k: os.environ.pop(k, None) for k in ENV_KEYS}
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = os.path.join(self._tmp.name, "install")
        os.makedirs(self.dir)
        os.environ["HELM_NOTIFIER_DIR"] = self.dir
        self.addCleanup(self._restore)

    def _restore(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def write(self, name, text):
        path = os.path.join(self.dir, name)
        with open(path, "w") as handle:
            handle.write(text)
        return path
