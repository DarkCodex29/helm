#!/usr/bin/env python3
"""One-shot provisioning for helm's FCM push path.

Uses the OAuth access token firebase-tools already holds. That credential
carries the `cloud-platform` scope, a superscope of what IAM and Service Usage
need here, so no browser round trip and no second CLI login.

What this does, and nothing else:
  1. enables the Cloud Messaging API on the project
  2. finds the firebase-adminsdk service account Firebase creates for every
     project (so nothing is created that Firebase did not already make)
  3. mints ONE key for it and writes the JSON to the credentials path, 0600

The project id is NOT stored in the repo: pass `--project ID` or set
`HELM_FCM_PROJECT_ID`. The output path is `HELM_NOTIFIER_CREDENTIALS` (see
config.py). firebase-tools' configstore defaults to
`~/.config/configstore/firebase-tools.json`; override with
`HELM_FIREBASE_CONFIGSTORE`.

Deliberately NOT idempotent in step 3: minting a key is a real credential
event, so it refuses rather than silently piling up keys. It never prints the
account e-mail.
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

import config


def configstore_path():
    return os.path.expanduser(
        os.environ.get("HELM_FIREBASE_CONFIGSTORE")
        or "~/.config/configstore/firebase-tools.json"
    )


def project_id(argv):
    if "--project" in argv:
        index = argv.index("--project")
        if index + 1 < len(argv):
            return argv[index + 1]
    return os.environ.get("HELM_FCM_PROJECT_ID", "")


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def access_token():
    try:
        with open(configstore_path()) as handle:
            store = json.load(handle)
    except Exception as exc:
        fail("could not read firebase-tools configstore: " + repr(exc))

    tokens = store.get("tokens") or {}
    token = tokens.get("access_token")
    expires_at = tokens.get("expires_at", 0)

    if not token:
        fail("no access_token in configstore; run `firebase login` first")

    # expires_at is epoch MILLIseconds in firebase-tools.
    remaining = (expires_at / 1000.0) - time.time()
    if remaining < 60:
        fail(
            "stored access token expires in %ds. Run any firebase command "
            "(e.g. `firebase projects:list`) to refresh it, then re-run this."
            % int(remaining)
        )
    print("token ok, %d min remaining" % int(remaining / 60))
    return token


def call(method, url, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode()[:400]
        fail("%s %s -> HTTP %d\n%s" % (method, url, exc.code, detail))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    project = project_id(argv)
    if not project:
        fail("no project id: pass --project ID or set HELM_FCM_PROJECT_ID")
    out_path = config.credentials_path()
    token = access_token()

    # 1. Cloud Messaging API. Enabling an enabled service is a no-op.
    print("enabling fcm.googleapis.com ...")
    call(
        "POST",
        "https://serviceusage.googleapis.com/v1/projects/%s/services/"
        "fcm.googleapis.com:enable" % project,
        token,
        body={},
    )
    print("  ok")

    # 2. The service account Firebase already made.
    print("looking for the firebase-adminsdk service account ...")
    listing = call(
        "GET",
        "https://iam.googleapis.com/v1/projects/%s/serviceAccounts" % project,
        token,
    )
    accounts = listing.get("accounts") or []
    admin = next(
        (a for a in accounts if a["email"].startswith("firebase-adminsdk-")),
        None,
    )
    if admin is None:
        fail("no firebase-adminsdk service account found (%d accounts listed)"
             % len(accounts))
    print("  found")

    # 3. Mint the key.
    if os.path.exists(out_path):
        fail(
            out_path + " already exists. Refusing to mint a second key -- "
            "delete it deliberately if you mean to rotate."
        )

    print("minting key ...")
    created = call(
        "POST",
        "https://iam.googleapis.com/v1/%s/keys" % admin["name"],
        token,
        body={
            "privateKeyType": "TYPE_GOOGLE_CREDENTIALS_FILE",
            "keyAlgorithm": "KEY_ALG_RSA_2048",
        },
    )
    blob = created.get("privateKeyData")
    if not blob:
        fail("key created but no privateKeyData in the response")

    payload = base64.b64decode(blob)
    # 0600 from the start: creating it world-readable and fixing it later
    # leaves a window.
    directory = os.path.dirname(out_path)
    if directory:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)

    parsed = json.loads(payload)
    print("  wrote " + out_path)
    print("  private_key_id: " + parsed["private_key_id"][:8] + "...")
    print("DONE")


if __name__ == "__main__":
    main()
