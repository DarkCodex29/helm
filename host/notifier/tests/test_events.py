import os
import unittest
from unittest import mock

from support import IsolatedEnv

import notifier


def event(pane="w1:p1", status: "str | None" = "idle", agent="opencode"):
    return {"event": "pane.agent_status_changed",
            "data": {"pane_id": pane, "agent_status": status, "agent": agent}}


class EventFilteringTest(IsolatedEnv):
    def setUp(self):
        super().setUp()
        notifier._last_state.clear()
        patcher = mock.patch.object(notifier, "deliver")
        self.deliver = patcher.start()
        self.addCleanup(patcher.stop)
        describe = mock.patch.object(
            notifier, "describe",
            side_effect=lambda s, p, a: ("Proj", "Area", "Doing X", a))
        describe.start()
        self.addCleanup(describe.stop)

    def test_blocked_and_idle_push(self):
        for status in ("blocked", "idle"):
            self.assertTrue(notifier.handle_event("default", event(pane="a" + status, status=status), {}))
        self.assertEqual(self.deliver.call_count, 2)

    def test_working_and_unknown_states_do_not_push(self):
        for status in ("working", "unknown", None):
            self.assertFalse(notifier.handle_event("default", event(status=status), {}))
        self.deliver.assert_not_called()

    def test_other_events_ignored(self):
        self.assertFalse(notifier.handle_event("default", {"event": "pane.output"}, {}))
        self.assertFalse(notifier.handle_event("default", {}, {}))
        self.deliver.assert_not_called()

    def test_repeat_state_for_same_pane_is_not_news(self):
        self.assertTrue(notifier.handle_event("default", event(), {}))
        self.assertFalse(notifier.handle_event("default", event(), {}))
        self.assertEqual(self.deliver.call_count, 1)

    def test_state_change_or_other_pane_pushes_again(self):
        notifier.handle_event("default", event(status="idle"), {})
        self.assertTrue(notifier.handle_event("default", event(status="blocked"), {}))
        self.assertTrue(notifier.handle_event("default", event(pane="w2:p1", status="blocked"), {}))

    def test_priority_distinguishes_blocked_from_idle(self):
        notifier.handle_event("default", event(status="blocked"), {})
        self.assertEqual(self.deliver.call_args.kwargs["priority"], "5")
        notifier.handle_event("default", event(pane="w9:p1", status="idle"), {})
        self.assertEqual(self.deliver.call_args.kwargs["priority"], "3")

    def test_pane_is_the_notification_tag(self):
        notifier.handle_event("default", event(pane="w3:p2"), {})
        self.assertEqual(self.deliver.call_args.kwargs["tag"], "default/w3:p2")

    def test_tag_is_scoped_by_session(self):
        notifier.handle_event("one", event(pane="w1:p1"), {})
        tag_one = self.deliver.call_args.kwargs["tag"]
        notifier.handle_event("two", event(pane="w1:p1"), {})
        self.assertNotEqual(tag_one, self.deliver.call_args.kwargs["tag"])

    def test_idle_working_idle_alerts_twice(self):
        for status in ("idle", "working", "idle"):
            notifier.handle_event("default", event(status=status), {})
        self.assertEqual(self.deliver.call_count, 2)

    def test_idle_idle_alerts_once(self):
        for status in ("idle", "idle"):
            notifier.handle_event("default", event(status=status), {})
        self.assertEqual(self.deliver.call_count, 1)

    def test_same_pane_id_in_two_sessions_is_independent(self):
        self.assertTrue(notifier.handle_event("one", event(pane="w1:p1"), {}))
        self.assertTrue(notifier.handle_event("two", event(pane="w1:p1"), {}))
        self.assertFalse(notifier.handle_event("one", event(pane="w1:p1"), {}))
        self.assertEqual(self.deliver.call_count, 2)

    def test_blocked_working_blocked_alerts_twice(self):
        for status in ("blocked", "working", "blocked"):
            notifier.handle_event("default", event(status=status), {})
        self.assertEqual(self.deliver.call_count, 2)

    def test_agent_name_falls_back_to_known_panes(self):
        msg = {"event": "pane.agent_status_changed",
               "data": {"pane_id": "w1:p1", "agent_status": "idle"}}
        notifier.handle_event("default", msg, {"w1:p1": "claude"})
        self.assertEqual(self.deliver.call_args.args[0], "Proj · claude is done")


class EnrichmentTest(IsolatedEnv):
    def test_build_alert_shape(self):
        rule = notifier.NOTIFY_ON["blocked"]
        title, body, data = notifier.build_alert(
            "default", "w1:p1", "blocked", rule, "claude", "Proj", "Area", "Fix bug")
        self.assertEqual(title, "Proj · claude needs you")
        self.assertEqual(body, "Fix bug")
        self.assertEqual(data, {
            "session": "default", "pane_id": "w1:p1", "agent": "claude",
            "state": "blocked", "place": "Proj", "area": "Area", "doing": "Fix bug"})

    def test_build_alert_without_context(self):
        rule = notifier.NOTIFY_ON["idle"]
        title, body, data = notifier.build_alert(
            "s", "w1:p1", "idle", rule, "opencode", None, None, None)
        self.assertEqual(title, "opencode is done")
        self.assertEqual(body, "s · w1:p1")
        self.assertEqual((data["place"], data["area"], data["doing"]), ("", "", ""))
        self.assertTrue(all(isinstance(v, str) for v in data.values()))

    def _describe(self, agent_info, tabs=None, workspaces=None):
        import json
        answers = {
            "get": json.dumps({"result": {"agent": agent_info}}),
            "tab": json.dumps({"result": {"tabs": tabs or []}}),
            "workspace": json.dumps({"result": {"workspaces": workspaces or []}}),
        }

        def fake_run(args, timeout=10):
            for key in ("get", "tab", "workspace"):
                if key in args:
                    return answers[key]
            return ""
        notifier._labels.update({"at": 0.0, "tabs": {}, "workspaces": {}})
        with mock.patch.object(notifier, "run", side_effect=fake_run):
            return notifier.describe("default", "w1:p1", "fallback")

    def test_describe_uses_labels_and_terminal_title(self):
        place, area, doing, agent = self._describe(
            {"agent": "opencode", "tab_id": "t1", "workspace_id": "k1",
             "terminal_title": " Working on it "},
            tabs=[{"tab_id": "t1", "label": "Backend"}],
            workspaces=[{"workspace_id": "k1", "label": "Team"}])
        self.assertEqual((place, area, doing, agent), ("Backend", "Team", "Working on it", "opencode"))

    def test_numeric_tab_label_falls_back_to_cwd_basename(self):
        place, _, _, _ = self._describe(
            {"tab_id": "t1", "cwd": "/work/demo/"}, tabs=[{"tab_id": "t1", "label": "3"}])
        self.assertEqual(place, "demo")

    def test_same_place_and_workspace_is_not_named_twice(self):
        place, area, _, _ = self._describe(
            {"tab_id": "t1", "workspace_id": "k1", "cwd": "/w/demo"},
            tabs=[{"tab_id": "t1", "label": "1"}],
            workspaces=[{"workspace_id": "k1", "label": "Demo"}])
        self.assertEqual((place, area), ("demo", None))

    def test_failed_lookup_degrades_to_four_values(self):
        # Regression: the live script returned three values and crashed the caller.
        with mock.patch.object(notifier, "run", return_value="not json"):
            result = notifier.describe("default", "w1:p1", "fallback")
        self.assertEqual(result, (None, None, None, "fallback"))


class DeliverRoutingTest(IsolatedEnv):
    """Every registered device gets the alert, each channel independently."""

    TOPIC_A = "helm-AAAAAAAAAAAAAAAAAAAAAAAA"
    TOPIC_B = "helm-BBBBBBBBBBBBBBBBBBBBBBBB"

    def setUp(self):
        super().setUp()
        self.addCleanup(notifier.hlog._secrets.clear)

    def run_deliver(self, tokens=(), topics=(), send=None, legacy="", push_effect=None):
        if legacy:
            os.environ["HELM_NOTIFIER_TOPIC"] = legacy
        with mock.patch.object(notifier.devices, "device_tokens", return_value=list(tokens)), \
             mock.patch.object(notifier.devices, "device_ntfy_topics", return_value=list(topics)), \
             mock.patch.object(notifier, "_sleep"), \
             mock.patch.object(notifier.fcm, "send", side_effect=send) as fcm_send, \
             mock.patch.object(notifier, "push_topic", side_effect=push_effect) as push_topic:
            notifier.deliver("T", "B", "5", "warning", {"a": 1}, tag="p")
        return fcm_send, push_topic

    def test_mixed_fleet_reaches_fcm_and_ntfy(self):
        fcm_send, push_topic = self.run_deliver(tokens=["t1"], topics=[self.TOPIC_A])
        self.assertEqual(fcm_send.call_count, 1)
        push_topic.assert_called_once()
        self.assertEqual(push_topic.call_args.args[0], self.TOPIC_A)

    def test_every_device_topic_gets_the_alert(self):
        _, push_topic = self.run_deliver(topics=[self.TOPIC_A, self.TOPIC_B])
        self.assertEqual([c.args[0] for c in push_topic.call_args_list],
                         [self.TOPIC_A, self.TOPIC_B])

    def test_priority_and_tags_are_kept(self):
        _, push_topic = self.run_deliver(topics=[self.TOPIC_A])
        self.assertEqual(push_topic.call_args.kwargs["priority"], "5")
        self.assertEqual(push_topic.call_args.kwargs["tags"], "warning")

    def test_fcm_failure_still_sends_ntfy(self):
        _, push_topic = self.run_deliver(
            tokens=["t1"], topics=[self.TOPIC_A], send=OSError("x"))
        push_topic.assert_called_once()

    def test_ntfy_failure_does_not_skip_other_destinations(self):
        fcm_send, push_topic = self.run_deliver(
            tokens=["t1"], topics=[self.TOPIC_A, self.TOPIC_B],
            push_effect=[OSError("x"), None, None])
        # topic A fails once and is retried, then topic B.
        self.assertEqual(push_topic.call_count, 3)
        self.assertEqual(fcm_send.call_count, 1)

    def test_legacy_topic_used_only_without_devices(self):
        _, push_topic = self.run_deliver(legacy="legacy-topic-123")
        push_topic.assert_called_once()
        self.assertEqual(push_topic.call_args.args[0], "legacy-topic-123")

    def test_legacy_topic_not_used_once_a_device_topic_exists(self):
        _, push_topic = self.run_deliver(topics=[self.TOPIC_A], legacy="legacy-topic-123")
        self.assertNotIn("legacy-topic-123", [c.args[0] for c in push_topic.call_args_list])

    def test_legacy_topic_not_used_when_fcm_token_exists(self):
        fcm_send, push_topic = self.run_deliver(tokens=["t1"], legacy="legacy-topic-123")
        self.assertEqual(fcm_send.call_count, 1)
        push_topic.assert_not_called()

    def test_legacy_topic_not_used_even_when_every_fcm_send_fails(self):
        # A registered device means the legacy topic stays quiet; otherwise a
        # transient FCM error would start duplicate alerts on a second channel.
        _, push_topic = self.run_deliver(
            tokens=["t1"], send=OSError("x"), legacy="legacy-topic-123")
        push_topic.assert_not_called()

    def test_no_devices_no_legacy_is_a_noop(self):
        _, push_topic = self.run_deliver()
        push_topic.assert_not_called()

    def test_log_has_counts_but_never_topic_or_token(self):
        logged = []
        token = "tok-SECRET-0123456789"
        with mock.patch.object(notifier, "log", side_effect=logged.append), \
             mock.patch.object(notifier.devices, "device_tokens", return_value=[token]), \
             mock.patch.object(notifier.devices, "device_ntfy_topics",
                               return_value=[self.TOPIC_A, self.TOPIC_B]), \
             mock.patch.object(notifier.fcm, "send"), \
             mock.patch.object(notifier, "push_topic"):
            notifier.deliver("T", "B", "5", "warning", {})
        text = "\n".join(logged)
        self.assertIn("pushed[fcm x1, ntfy x2]", text)
        self.assertNotIn(self.TOPIC_A, text)
        self.assertNotIn(token, text)

    def test_push_topic_failure_log_hides_the_topic(self):
        logged = []
        with mock.patch.object(notifier, "log", side_effect=logged.append), \
             mock.patch("netsafe.urlopen", side_effect=OSError(self.TOPIC_A)):
            with self.assertRaises(Exception):
                notifier.push_topic(self.TOPIC_A, "T", "B")
        self.assertNotIn(self.TOPIC_A, "\n".join(logged))

    def test_push_without_topic_is_a_noop(self):
        with mock.patch("netsafe.urlopen") as urlopen:
            notifier.push("T", "B")
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
