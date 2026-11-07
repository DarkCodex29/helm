"""Rotating, redacting log for the notifier.

The live script wrote to stdout and relied on launchd to append to a file
that never rotated (7.4 MB and growing). It also logged the whole message
body, the last 8 characters of device tokens, and the ntfy topic.

Here:
  * RotatingFileHandler, 1 MB x 3 backups;
  * umask 077 before any file is created, so log, backups and token files are
    0600, and existing log files/backups are chmod'ed to 0600 at startup;
  * a filter that scrubs registered secrets and token-shaped strings from
    every record, as a second line of defence behind "never pass them in";
  * `clip` for the little text that is logged (titles), body is omitted.
"""
import logging
import logging.handlers
import os
import re
import sys

import config

MAX_BYTES = 1000000
BACKUP_COUNT = 3
TEXT_LIMIT = 40
REDACTED = "[redacted]"

_secrets = set()

_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z ]+-----.*?(-----END [A-Z ]+-----|$)", re.S),
    re.compile(r"Bearer\s+\S+"),
    re.compile(r"ya29\.[\w.-]+"),
    # FCM registration tokens look like "<id>:<long opaque string>".
    re.compile(r"[A-Za-z0-9_-]{16,}:[A-Za-z0-9_-]{20,}"),
]


def register_secret(value):
    """Make [value] disappear from every later log record."""
    if isinstance(value, str) and len(value) >= 8:
        _secrets.add(value)


def scrub(text):
    for secret in _secrets:
        text = text.replace(secret, REDACTED)
    for pattern in _PATTERNS:
        text = pattern.sub(REDACTED, text)
    return text


def clip(text, limit=TEXT_LIMIT):
    """One line, at most [limit] characters, secrets scrubbed FIRST.

    Scrubbing after truncation would let a registered secret cut in half
    escape the match and leave its prefix in the log.
    """
    flat = " ".join(scrub(str(text)).split())
    if len(flat) <= limit:
        return flat
    return flat[: limit - 1] + "\u2026"


class RedactFilter(logging.Filter):
    def filter(self, record):
        record.msg = scrub(record.getMessage())
        record.args = None
        return True


_logger = logging.getLogger("helm-notifier")


def _tighten(path):
    """0600 for an existing log file and its rotated backups."""
    for candidate in [path] + ["%s.%d" % (path, i) for i in range(1, BACKUP_COUNT + 1)]:
        try:
            os.chmod(candidate, 0o600)
        except OSError:
            pass  # absent (or not ours): nothing to tighten


def setup(path=None):
    """Configure the logger. Safe to call twice (handlers are replaced)."""
    os.umask(0o077)
    path = path or config.log_path()
    for old in list(_logger.handlers):
        _logger.removeHandler(old)
        old.close()
    try:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, mode=0o700, exist_ok=True)
        _tighten(path)
        # Created here, 0600, so the mode never depends on the handler.
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600))
        handler = logging.handlers.RotatingFileHandler(
            path, maxBytes=MAX_BYTES, backupCount=BACKUP_COUNT, encoding="utf-8"
        )
    except OSError as exc:
        sys.stderr.write("cannot open log file (%s); logging to stderr\n" % exc)
        handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter("%(asctime)s %(message)s", "%Y-%m-%dT%H:%M:%S")
    )
    handler.addFilter(RedactFilter())
    _logger.addHandler(handler)
    _logger.setLevel(logging.INFO)
    _logger.propagate = False
    return _logger


def log(msg):
    if not _logger.handlers:
        setup()
    _logger.info(msg)
