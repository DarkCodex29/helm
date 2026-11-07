"""Which devices are registered to receive helm's notifications.

Reads `device-tokens.json` (see config.tokens_path): FCM registration tokens
under `tokens`, per-device ntfy topics under `ntfy_topics`. This module is
deliberately independent of any transport (no FCM, no network), so a device
list is available even when the FCM module cannot be imported.

Tokens and topics are bearer secrets; each one read is registered with the
log scrubber.
"""
import json
import os
import re

import config
import hlog


def _read_device_file():
    """The decoded device file as a dict, or {} for anything unusable."""
    path = config.tokens_path()
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as handle:
            loaded = json.load(handle)
    except Exception:
        return {}
    return loaded if isinstance(loaded, dict) else {}


def _clean_strings(raw, accept=None):
    """Non-empty stripped strings of [raw], deduplicated, order kept."""
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if not isinstance(item, str):
            continue
        item = item.strip()
        if item and (accept is None or accept(item)) and item not in out:
            out.append(item)
    return out


def device_tokens():
    """Every FCM token registered to receive helm's notifications.

    Missing, empty, unreadable or malformed files all mean "none". Entries
    that are not non-empty strings are dropped and duplicates collapse.
    """
    tokens = _clean_strings(_read_device_file().get("tokens", []))
    for token in tokens:
        hlog.register_secret(token)
    return tokens


_TOPIC_SHAPE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


def device_ntfy_topics():
    """Every per-device ntfy topic registered by a phone without FCM.

    A topic is a bearer secret (whoever knows it reads the alerts), so each
    one is registered with the log scrubber. Entries outside the ntfy-safe
    alphabet are dropped: a topic ends up in a URL path.
    """
    topics = _clean_strings(
        _read_device_file().get("ntfy_topics", []), _TOPIC_SHAPE.match
    )
    for topic in topics:
        hlog.register_secret(topic)
    return topics
