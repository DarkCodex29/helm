"""Where the notifier keeps things. Everything comes from the environment.

Nothing here is read at import time: tests (and a second install) change the
environment and expect the next call to see it.

    HELM_NOTIFIER_DIR          install dir            (default ~/helm-notifier)
    HELM_NOTIFIER_CREDENTIALS  FCM service-account    (default <dir>/fcm-sa.json)
    HELM_NOTIFIER_PEM          extracted private key  (default <dir>/fcm-sa.pem)
    HELM_NOTIFIER_TOKENS       device tokens          (default <dir>/device-tokens.json)
    HELM_NOTIFIER_LOG          rotating log           (default <dir>/notifier.log)
    HELM_NOTIFIER_TOPIC_FILE   ntfy topic, optional   (default <dir>/topic)
    HELM_NOTIFIER_TOPIC        ntfy topic, overrides the file
    HELM_HERDR_BIN             herdr binary, overrides discovery
"""
import os


def _expand(value):
    return os.path.expanduser(value)


def install_dir():
    return _expand(os.environ.get("HELM_NOTIFIER_DIR") or "~/helm-notifier")


def _path(env_name, default_name):
    value = os.environ.get(env_name)
    if value:
        return _expand(value)
    return os.path.join(install_dir(), default_name)


def credentials_path():
    return _path("HELM_NOTIFIER_CREDENTIALS", "fcm-sa.json")


def pem_path():
    return _path("HELM_NOTIFIER_PEM", "fcm-sa.pem")


def tokens_path():
    return _path("HELM_NOTIFIER_TOKENS", "device-tokens.json")


def log_path():
    return _path("HELM_NOTIFIER_LOG", "notifier.log")


def topic():
    """The ntfy topic, or "" when ntfy is not configured.

    The live script crashed at import when the file was missing, which made
    the (optional) fallback transport a hard requirement of the preferred one.
    """
    value = os.environ.get("HELM_NOTIFIER_TOPIC")
    if value:
        return value.strip()
    try:
        with open(_path("HELM_NOTIFIER_TOPIC_FILE", "topic")) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def herdr_bin():
    """The herdr binary, discovered rather than assumed.

    launchd hands a minimal PATH, so `which` is not reliable: the candidates
    are checked directly.
    """
    override = os.environ.get("HELM_HERDR_BIN")
    if override:
        return _expand(override)
    candidates = [
        "/opt/homebrew/bin/herdr",
        "/usr/local/bin/herdr",
        os.path.expanduser("~/.local/bin/herdr"),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    # Nothing found: keep the last candidate so the failure surfaces in the
    # log as a missing binary rather than as silent no-op watching.
    return candidates[-1]
