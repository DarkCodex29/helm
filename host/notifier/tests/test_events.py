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
        self.assertEqual(self.deliver.call_args.kwargs["tag"], "w3:p2")

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
    def test_tokens_route_to_fcm_and_skip_ntfy(self):
        with mock.patch.object(notifier.fcm, "device_tokens", return_value=["t1", "t2"]), \
             mock.patch.object(notifier.fcm, "send") as send, \
             mock.patch.object(notifier, "push") as push:
            notifier.deliver("T", "B", "5", "warning", {"a": 1}, tag="p")
        self.assertEqual(send.call_count, 2)
        push.assert_not_called()

    def test_no_tokens_use_ntfy(self):
        with mock.patch.object(notifier.fcm, "device_tokens", return_value=[]), \
             mock.patch.object(notifier, "push") as push:
            notifier.deliver("T", "B", "5", "warning", {})
        push.assert_called_once()

    def test_every_fcm_failure_falls_back_to_ntfy(self):
        with mock.patch.object(notifier.fcm, "device_tokens", return_value=["t1"]), \
             mock.patch.object(notifier.fcm, "send", side_effect=OSError("x")), \
             mock.patch.object(notifier, "push") as push:
            notifier.deliver("T", "B", "5", "warning", {})
        push.assert_called_once()

    def test_push_without_topic_is_a_noop(self):
        with mock.patch("urllib.request.urlopen") as urlopen:
            notifier.push("T", "B")
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
