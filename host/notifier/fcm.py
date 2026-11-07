#!/usr/bin/env python3
"""Send FCM HTTP v1 messages from this machine, with no third-party service.

The Mac is the push provider: there is no hosted relay between herdr noticing
an agent needs attention and the phone lighting up.

### Why openssl instead of a Python crypto library

The JWT is signed by shelling out to `openssl`, not by `cryptography`. The
LaunchAgent runs the system `/usr/bin/python3`, which has no `cryptography`;
pointing it at a Homebrew interpreter would work today and rot on the next
minor-version upgrade, silently, on the night an agent needed a human.
Signing through `openssl` keeps the whole path on tools the OS ships. This
file therefore uses only `json`, `urllib` and `subprocess`.

### Legacy API is gone

`https://fcm.googleapis.com/fcm/send` with a server key was shut down in
2024. HTTP v1 with a short-lived OAuth token replaced it: a leaked access
token expires in an hour, a leaked server key never did.

Paths come from `config` (environment), never from constants in this file.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import config
import hlog

TOKEN_URL = "https://oauth2.googleapis.com/token"  # noqa: S105 (endpoint URL, not a secret)
SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

# Refreshed early rather than on expiry: a notification that arrives after a
# 401 is a notification that arrived late.
_REFRESH_MARGIN = 600

_cached = {"token": None, "expires_at": 0}


def _request_json(req, timeout=20):
    """POST [req] and return the decoded JSON object.

    Only https is allowed (the URLs are constants, but this makes it a
    checked property), and a non-JSON answer is a RuntimeError rather than a
    bare ValueError, so callers have one failure type to handle.
    """
    if not req.full_url.startswith("https://"):
        raise RuntimeError("refusing non-https URL")
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        raw = resp.read().decode()
    try:
        parsed = json.loads(raw)
    except ValueError as exc:
        raise RuntimeError("response was not JSON") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("response was not a JSON object")
    return parsed


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def _service_account():
    path = config.credentials_path()
    if not os.path.exists(path):
        raise RuntimeError(
            path + " missing. Run provision_fcm.py to mint the key."
        )
    try:
        with open(path) as handle:
            account = json.load(handle)
    except (OSError, ValueError) as exc:
        raise RuntimeError("cannot read credentials file: " + type(exc).__name__) from exc
    hlog.register_secret(account.get("private_key"))
    return account


def _private_key_pem(account):
    """The SA's private key on disk as PEM, written 0600 on first use.

    Extracted once instead of a temp file per signature: the token is
    re-minted roughly every 50 minutes, and each of those would otherwise
    create and delete a file containing a private key.
    """
    path = config.pem_path()
    if not os.path.exists(path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(account["private_key"])
    return path


def _sign_rs256(message, pem_path):
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", pem_path],
        input=message,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "openssl signing failed: " + result.stderr.decode(errors="replace")
        )
    return result.stdout


def build_assertion(account, pem_path, now):
    """The signed JWT bearer assertion for the OAuth token endpoint."""
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64url(
        json.dumps(
            {
                "iss": account["client_email"],
                "scope": SCOPE,
                "aud": TOKEN_URL,
                "iat": int(now),
                "exp": int(now) + 3600,
            }
        ).encode()
    )
    signing_input = header + b"." + claims
    return (signing_input + b"." + _b64url(_sign_rs256(signing_input, pem_path))).decode()


def access_token():
    """A cached `firebase.messaging` access token, minted offline."""
    now = time.time()
    if _cached["token"] and now < _cached["expires_at"]:
        return _cached["token"]

    account = _service_account()
    assertion = build_assertion(account, _private_key_pem(account), now)

    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        }
    ).encode()
    req = urllib.request.Request(TOKEN_URL, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    payload = _request_json(req)

    _cached["token"] = payload["access_token"]
    hlog.register_secret(_cached["token"])
    _cached["expires_at"] = now + payload.get("expires_in", 3600) - _REFRESH_MARGIN
    return _cached["token"]


def device_tokens():
    """Every device registered to receive helm's notifications.

    Missing, empty, unreadable or malformed files all mean "none": the caller
    then falls back to ntfy. Entries that are not non-empty strings are
    dropped (the live code passed them on to FCM) and duplicates collapse.
    """
    path = config.tokens_path()
    if not os.path.exists(path):
        return []
    try:
        with open(path) as handle:
            raw = json.load(handle).get("tokens", [])
    except Exception:
        return []
    if not isinstance(raw, list):
        return []
    tokens = []
    for item in raw:
        if isinstance(item, str) and item.strip() and item.strip() not in tokens:
            tokens.append(item.strip())
    for token in tokens:
        hlog.register_secret(token)
    return tokens


def build_message(device_token, title, body, data=None, tag=None):
    """The FCM v1 `message` object. Pure, so its shape is testable."""
    android_notification = {"click_action": "FLUTTER_NOTIFICATION_CLICK"}
    if tag:
        android_notification["tag"] = tag
    return {
        "token": device_token,
        "notification": {"title": title, "body": body},
        # FCM's data map is string -> string.
        "data": {k: str(v) for k, v in (data or {}).items()},
        "android": {
            # High priority is the documented way to wake an app through
            # Doze; it obliges every such message to show a notification.
            "priority": "high",
            "notification": android_notification,
        },
    }


def send(device_token, title, body, data=None, tag=None, validate_only=False):
    """Deliver one notification. Returns the FCM message name.

    [tag] gives every pane its own notification slot on Android, so a new
    alert for one pane does not erase another pane's.
    """
    account = _service_account()
    url = "https://fcm.googleapis.com/v1/projects/{}/messages:send".format(
        account["project_id"]
    )
    payload: dict = {"message": build_message(device_token, title, body, data, tag)}
    if validate_only:
        payload["validate_only"] = True

    req = urllib.request.Request(  # noqa: S310 (https checked in _request_json)
        url, data=json.dumps(payload).encode(), method="POST"
    )
    req.add_header("Authorization", "Bearer " + access_token())
    req.add_header("Content-Type", "application/json")
    return _request_json(req).get("name", "")


def _selftest():
    """Prove the credential works without a real device.

    A deliberately invalid device token separates the two failures that look
    alike: 401/403 means the credential is wrong, 400 INVALID_ARGUMENT means
    FCM accepted us and rejected only the token. Only the second means done.
    Never prints the project id, account e-mail or any token.
    """
    _service_account()
    print("credential file loaded")
    print("minting access token ...")
    token = access_token()
    print(f"  ok, {len(token)} chars")

    print("probing messages:send with a deliberately invalid device token ...")
    try:
        send("INVALID_TOKEN_FOR_SELFTEST", "selftest", "selftest",
             validate_only=True)
        print("  unexpected success -- FCM accepted a bogus token")
        return 1
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()[:200]
        if exc.code in (401, 403):
            print(f"  AUTH FAILED ({exc.code}): {detail}")
            return 1
        if exc.code == 400:
            print("  AUTH OK -- FCM rejected only the fake token (400), as expected")
            return 0
        print(f"  unexpected HTTP {exc.code}: {detail}")
        return 1


if __name__ == "__main__":
    sys.exit(_selftest())
