"""Delivery resilience: transport independence, retries, dedupe, no leaks."""
import json
import os
import unittest
from unittest import mock

from support import IsolatedEnv  # isort: skip  (puts the notifier dir on sys.path)

import notifier  # isort: skip

TOPIC = "helm-AAAAAAAAAAAAAAAAAAAAAAAA"
LEGACY = "legacy-topic-123"


class DeliveryBase(IsolatedEnv):
    def setUp(self):
        super().setUp()
        self.addCleanup(notifier.hlog._secrets.clear)
        self.addCleanup(notifier._last_state.clear)
        notifier._last_state.clear()

    def register(self, tokens=(), topics=()):
        os.environ["HELM_NOTIFIER_TOKENS"] = self.write(
            "d.json", json.dumps({"tokens": list(tokens), "ntfy_topics": list(topics)}))


class FcmUnavailableTest(DeliveryBase):
    def test_ntfy_devices_still_served_when_fcm_failed_to_import(self):
        self.register(tokens=["tok-aaaaaaaa"], topics=[TOPIC])
        os.environ["HELM_NOTIFIER_TOPIC"] = LEGACY
        logged = []
        with mock.patch.object(notifier, "fcm", None), \
             mock.patch.object(notifier, "log", side_effect=logged.append), \
             mock.patch.object(notifier, "push_topic") as push_topic:
            notifier.deliver("T", "B", "5", "w", {})
        self.assertEqual([c.args[0] for c in push_topic.call_args_list], [TOPIC])
        text = "\n".join(logged)
        self.assertNotIn("tok-aaaaaaaa", text)
        self.assertIn("1", text)  # counts of undeliverable tokens


class RetryTest(DeliveryBase):
    def deliver(self, **patches):
        sleeps = []
        with mock.patch.object(notifier, "_sleep", sleeps.append, create=True), \
             mock.patch.object(notifier, "push_topic", **patches) as push_topic:
            result = notifier.deliver("T", "B", "5", "w", {})
        return push_topic, sleeps, result

    def test_one_failure_then_success_is_delivered(self):
        self.register(topics=[TOPIC])
        push_topic, sleeps, _ = self.deliver(side_effect=[OSError("x"), None])
        self.assertEqual(push_topic.call_count, 2)
        self.assertEqual(len(sleeps), 1)

    def test_retries_are_bounded(self):
        self.register(topics=[TOPIC])
        push_topic, sleeps, _ = self.deliver(side_effect=OSError("x"))
        self.assertEqual(push_topic.call_count, 3)  # 1 try + 2 retries
        self.assertEqual(len(sleeps), 2)

    def test_total_failure_does_not_consume_the_event(self):
        self.register(topics=[TOPIC])
        msg = {"event": "pane.agent_status_changed",
               "data": {"agent_status": "blocked", "pane_id": "p1", "agent": "a"}}
        with mock.patch.object(notifier, "_sleep", lambda s: None, create=True), \
             mock.patch.object(notifier, "describe", return_value=(None, None, None, "a")), \
             mock.patch.object(notifier, "push_topic", side_effect=OSError("x")) as push_topic:
            notifier.handle_event("s", msg, {})
            first = push_topic.call_count
            notifier.handle_event("s", msg, {})
        self.assertGreater(first, 0)
        self.assertEqual(push_topic.call_count, first * 2)

    def test_success_still_dedupes_a_repeat(self):
        self.register(topics=[TOPIC])
        msg = {"event": "pane.agent_status_changed",
               "data": {"agent_status": "blocked", "pane_id": "p1", "agent": "a"}}
        with mock.patch.object(notifier, "describe", return_value=(None, None, None, "a")), \
             mock.patch.object(notifier, "push_topic") as push_topic:
            notifier.handle_event("s", msg, {})
            notifier.handle_event("s", msg, {})
        self.assertEqual(push_topic.call_count, 1)

    def test_legacy_topic_not_used_when_devices_exist_and_all_fail(self):
        self.register(topics=[TOPIC])
        os.environ["HELM_NOTIFIER_TOPIC"] = LEGACY
        push_topic, _, _ = self.deliver(side_effect=OSError("x"))
        self.assertNotIn(LEGACY, [c.args[0] for c in push_topic.call_args_list])


class PushTopicLeakTest(DeliveryBase):
    def test_exception_never_contains_the_topic(self):
        with mock.patch("netsafe.urlopen", side_effect=OSError("boom " + TOPIC)), \
             self.assertRaises(Exception) as ctx:
            notifier.push_topic(TOPIC, "T", "B")
        self.assertNotIn(TOPIC, str(ctx.exception))
        self.assertNotIn(TOPIC, repr(ctx.exception))
        self.assertIsNone(ctx.exception.__cause__)
        self.assertTrue(ctx.exception.__suppress_context__)
        self.assertEqual(str(ctx.exception), "ntfy send failed: OSError")


if __name__ == "__main__":
    unittest.main()
