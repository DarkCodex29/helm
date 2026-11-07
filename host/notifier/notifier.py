#!/usr/bin/env python3
"""Watch herdr for agents that need a human and push a notification.

Uses events.subscribe over the herdr socket (the plugin event-hook route did
not dispatch for CLI-reported state changes, so this does not depend on it).
One thread per session, so an event in one session is never missed while
another is being watched.

Configuration is environment-only, see config.py. Standard library only.

What is logged (see hlog.py): session names, pane ids, the notification
TITLE clipped to 40 characters, counts and error types. Never the body (it is
the agent's own terminal title and can contain anything), never a device
token, never the credential, never the ntfy topic.
"""
import contextlib
import json
import os
import socket
import subprocess
import threading
import time
import urllib.request

import config
import hlog
from hlog import clip, log

# Optional on purpose: a daemon whose only job is telling a human something
# must not fail to start because its newer transport could not be imported.
try:
    import fcm
except Exception as _fcm_import_error:  # pragma: no cover - defensive
    fcm = None
    _FCM_IMPORT_ERROR = type(_fcm_import_error).__name__
else:
    _FCM_IMPORT_ERROR = None

NTFY_BASE = "https://ntfy.sh/"

# Which states are worth telling a human about, and how loudly.
#
# `blocked` interrupts (the agent needs a decision); `idle` informs (the turn
# ended). opencode is a herdr lifecycle authority and reports a finished turn
# as `idle`, never `blocked`, so watching only `blocked` stayed silent through
# every completed turn. Priorities are ntfy's 1..5. Drop an entry to stop
# being told about that state.
NOTIFY_ON = {
    "blocked": {"suffix": "needs you", "priority": "5", "tags": "warning"},
    "idle": {"suffix": "is done", "priority": "3", "tags": "white_check_mark"},
}
# How often to re-enumerate panes so a newly started agent gets watched.
RESCAN_SECONDS = 30

# The last state each pane was reported in, so a repeat is not re-announced.
# Keyed by pane: two agents reaching `idle` together are two pieces of news.
_last_state = {}


def run(args, timeout=10):
    try:
        return subprocess.run(
            args, capture_output=True, text=True, timeout=timeout
        ).stdout
    except Exception:
        return ""


def sessions():
    out = run([config.herdr_bin(), "session", "list"])
    names = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if line:
            names.append(line.split()[0])
    return names


def socket_path(session):
    if session == "default":
        return os.path.expanduser("~/.config/herdr/herdr.sock")
    return os.path.expanduser(
        "~/.config/herdr/sessions/" + session + "/herdr.sock"
    )


def agent_panes(session):
    out = run([config.herdr_bin(), "--session", session, "agent", "list"])
    try:
        agents = json.loads(out)["result"]["agents"]
    except Exception:
        return []
    return [(a["pane_id"], a.get("agent") or "agent") for a in agents]


# Tab and workspace labels, cached with a short TTL: they change only when the
# user renames something, so re-reading on every alert would spend two
# subprocesses to learn what almost never moves.
_LABEL_TTL = 60
_labels = {"at": 0.0, "tabs": {}, "workspaces": {}}


def _refresh_labels():
    now = time.time()
    if now - _labels["at"] < _LABEL_TTL:
        return

    def collect(args, key, id_field):
        try:
            payload = json.loads(run([config.herdr_bin(), *args]))
            rows = payload["result"][key]
            return {r[id_field]: r.get("label") or "" for r in rows}
        except Exception:
            # A stale label beats none: no label degrades every notification
            # to an opaque id.
            return None

    tabs = collect(["tab", "list"], "tabs", "tab_id")
    workspaces = collect(["workspace", "list"], "workspaces", "workspace_id")
    if tabs is not None:
        _labels["tabs"] = tabs
    if workspaces is not None:
        _labels["workspaces"] = workspaces
    _labels["at"] = now


def describe(session, pane, fallback_agent):
    """What a human should be told about [pane]: (place, area, doing, agent).

    The triggering event carries only `agent`, `pane_id` and `agent_status`.
    `herdr agent get` knows more, and `tab list` / `workspace list` resolve
    its ids into the labels the app's own drawer shows. `doing` is the agent's
    own terminal title when it wrote one.

    Every lookup degrades rather than fails: a weaker label still tells the
    user something, no notification tells them nothing.
    """
    place, area, doing, agent = None, None, None, fallback_agent
    try:
        payload = json.loads(
            run([config.herdr_bin(), "--session", session, "agent", "get", pane])
        )
        info = payload["result"].get("agent") or payload["result"]
    except Exception:
        # The live script returned THREE values here and the caller unpacks
        # four, so a failed lookup raised and dropped the alert entirely.
        return place, area, doing, agent

    agent = info.get("agent") or fallback_agent
    doing = (info.get("terminal_title_stripped")
             or info.get("terminal_title") or "").strip() or None

    _refresh_labels()
    tab = _labels["tabs"].get(info.get("tab_id") or "", "").strip()
    workspace = _labels["workspaces"].get(info.get("workspace_id") or "", "").strip()
    area = workspace or None

    # A tab herdr never named comes back as its number: an id wearing a
    # label's clothes, so it is refused and the ladder continues.
    if tab and not tab.isdigit():
        place = tab
    elif info.get("cwd"):
        place = os.path.basename(info["cwd"].rstrip("/")) or None

    # Case-insensitive: an unnamed tab falls back to the cwd basename while
    # the workspace label is typed by a human; same place, named twice.
    if area and place and area.casefold() == place.casefold():
        area = None
    if not place and area:
        place, area = area, None

    return place, area, doing, agent


def push(title, body, priority="5", tags="warning"):
    """Send one ntfy notification (fallback transport). No-op without a topic."""
    topic = config.topic()
    if not topic:
        log("ntfy not configured; notification dropped")
        return
    hlog.register_secret(topic)
    try:
        # NTFY_BASE is a fixed https URL; only the topic path varies.
        req = urllib.request.Request(  # noqa: S310
            NTFY_BASE + topic, data=body.encode("utf-8"), method="POST"
        )
        req.add_header("Title", title)
        req.add_header("Priority", priority)
        req.add_header("Tags", tags)
        urllib.request.urlopen(req, timeout=10).read()  # noqa: S310 (fixed https URL)
        log(f"pushed[ntfy {priority}]: {clip(title)}")
    except Exception as exc:
        log("push failed: " + type(exc).__name__)


def deliver(title, body, priority, tags, data, tag=None):
    """Send one alert by the best transport currently available.

    Tokens registered means FCM (helm's own channel, tap opens the session);
    none means ntfy. An FCM failure falls back rather than raising: a
    notification lost to a transient 5xx is the failure this daemon exists to
    prevent.
    """
    tokens = fcm.device_tokens() if fcm is not None else []

    if tokens and fcm is not None:
        sent = 0
        for index, token in enumerate(tokens):
            try:
                fcm.send(token, title, body, data=data, tag=tag)
                sent += 1
            except Exception as exc:
                # Device N of M, never any part of the token.
                log(f"fcm send failed for device {index + 1}/{len(tokens)}: "
                    f"{type(exc).__name__}")
        if sent:
            log(f"pushed[fcm x{sent}]: {clip(title)}")
            return
        log("every fcm delivery failed; falling back to ntfy")
    elif fcm is None:
        log(f"fcm unavailable ({_FCM_IMPORT_ERROR}); using ntfy")

    push(title, body, priority=priority, tags=tags)


def build_alert(session, pane, state, rule, agent, place, area, doing):
    """Title, body and FCM data for one alert. Pure, so it is testable.

    The place leads, because with three agents the first question is "where".
    Only the place, never place plus area: a title gets ~30 characters before
    a phone truncates it. The area rides in the payload for surfaces with
    more room. `session` is the only routing key helm honours.
    """
    title = (place + " · " if place else "") + agent + " " + rule["suffix"]
    body = doing or (session + " · " + pane)
    data = {
        "session": session,
        "pane_id": pane,
        "agent": agent,
        "state": str(state),
        # Empty strings, not omitted keys: FCM's data map is string-to-string.
        "place": place or "",
        "area": area or "",
        "doing": doing or "",
    }
    return title, body, data


def handle_event(session, msg, names):
    """Turn one herdr message into at most one alert. Returns True if sent."""
    if msg.get("event") != "pane.agent_status_changed":
        return False
    data = msg.get("data", {})
    state = data.get("agent_status")
    rule = NOTIFY_ON.get(state)
    if not rule:
        return False

    pane = data.get("pane_id", "?")
    agent = data.get("agent") or names.get(pane, "agent")

    # Same pane, same state, twice running is not news.
    if _last_state.get(pane) == state:
        return False
    _last_state[pane] = state

    place, area, doing, agent = describe(session, pane, agent)
    title, body, payload = build_alert(
        session, pane, state, rule, agent, place, area, doing
    )
    deliver(
        title, body,
        priority=rule["priority"], tags=rule["tags"],
        # One slot per pane: otherwise a second agent's alert replaces the
        # first one's and the user never learns it happened.
        tag=pane, data=payload,
    )
    return True


def watch_once(session):
    """Subscribe to this session's agent panes and block until the socket
    goes quiet. Returning re-enumerates, which is how a new agent is picked up."""
    targets = agent_panes(session)
    if not targets:
        return False

    path = socket_path(session)
    if not os.path.exists(path):
        return False

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(10)
    sock.connect(path)
    subs = [
        {"type": "pane.agent_status_changed", "pane_id": pane}
        for pane, _ in targets
    ]
    request = {
        "id": "helm-notifier",
        "method": "events.subscribe",
        "params": {"subscriptions": subs},
    }
    sock.sendall((json.dumps(request) + "\n").encode("utf-8"))

    names = dict(targets)
    log("watching " + session + ": " + ",".join(p for p, _ in targets))

    sock.settimeout(RESCAN_SECONDS)
    buf = b""
    try:
        while True:
            try:
                chunk = sock.recv(4096)
            except (socket.timeout, TimeoutError):  # distinct types on py3.9
                return True
            if not chunk:
                return True
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                handle_event(session, msg, names)
    finally:
        with contextlib.suppress(OSError):
            sock.close()


def session_loop(session):
    while True:
        try:
            if not watch_once(session):
                time.sleep(10)
        except Exception as exc:
            log(session + ": " + type(exc).__name__)
            time.sleep(10)


def main():
    hlog.setup()
    log("helm-notifier starting; herdr=" + config.herdr_bin()
        + "; ntfy=" + ("on" if config.topic() else "off"))
    running = {}
    while True:
        for sess in sessions():
            if sess not in running or not running[sess].is_alive():
                thread = threading.Thread(
                    target=session_loop, args=(sess,), daemon=True
                )
                thread.start()
                running[sess] = thread
                log("thread started for session " + sess)
        time.sleep(RESCAN_SECONDS)


if __name__ == "__main__":
    main()
