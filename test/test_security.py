#!/usr/bin/env python3
"""Regression tests for marketplace security review #2379."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "omarchy-agent-usage-grok"


def load_collector():
  loader = importlib.machinery.SourceFileLoader("omarchy_agent_usage_grok", str(SCRIPT))
  spec = importlib.util.spec_from_loader(loader.name, loader)
  mod = importlib.util.module_from_spec(spec)
  loader.exec_module(mod)
  return mod


mod = load_collector()


class OriginTests(unittest.TestCase):
  def test_same_origin_https_billing_host(self):
    a = "https://cli-chat-proxy.grok.com/v1/billing"
    b = "https://cli-chat-proxy.grok.com/v1/settings"
    self.assertTrue(mod.same_origin(a, b))
    self.assertTrue(mod.allowed_request_url(a))

  def test_scheme_change_is_cross_origin(self):
    self.assertFalse(
      mod.same_origin(
        "https://cli-chat-proxy.grok.com/v1/billing",
        "http://cli-chat-proxy.grok.com/v1/billing",
      )
    )

  def test_host_change_is_cross_origin(self):
    self.assertFalse(
      mod.same_origin(
        "https://cli-chat-proxy.grok.com/v1/billing",
        "https://evil.example/v1/billing",
      )
    )

  def test_file_url_rejected(self):
    self.assertFalse(mod.allowed_request_url("file:///etc/passwd"))
    self.assertIsNone(mod.origin_of("file:///etc/passwd"))


class RedirectTests(unittest.TestCase):
  def _req(self):
    return urllib.request.Request(
      "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
      headers={"Authorization": "Bearer secret-token", "X-XAI-Token-Auth": "xai-grok-cli"},
      method="GET",
    )

  def test_cross_origin_redirect_refused(self):
    handler = mod.SameOriginRedirectHandler()
    req = self._req()
    with self.assertRaises(urllib.error.HTTPError) as raised:
      handler.redirect_request(
        req, None, 302, "Found", {}, "https://evil.example/steal",
      )
    self.assertIn("cross-origin redirect refused", str(raised.exception))

  def test_http_downgrade_refused(self):
    handler = mod.SameOriginRedirectHandler()
    with self.assertRaises(urllib.error.HTTPError):
      handler.redirect_request(
        self._req(), None, 302, "Found", {},
        "http://cli-chat-proxy.grok.com/v1/billing",
      )

  def test_same_origin_https_allowed(self):
    handler = mod.SameOriginRedirectHandler()
    nxt = handler.redirect_request(
      self._req(), None, 302, "Found", {},
      "https://cli-chat-proxy.grok.com/v1/billing?format=credits&next=1",
    )
    self.assertIsNotNone(nxt)
    self.assertTrue(str(nxt.full_url).startswith("https://cli-chat-proxy.grok.com/"))
    self.assertIn("secret-token", nxt.headers.get("Authorization", ""))

  def test_fetch_json_refuses_unexpected_host(self):
    with self.assertRaises(ValueError):
      mod.fetch_json("https://evil.example/", {"Authorization": "Bearer x"}, timeout=1)
    with self.assertRaises(ValueError):
      mod.fetch_json("http://cli-chat-proxy.grok.com/v1/billing", {}, timeout=1)


class FileTrustTests(unittest.TestCase):
  def setUp(self):
    self.tmpdir = tempfile.TemporaryDirectory()
    self.root = Path(self.tmpdir.name)

  def tearDown(self):
    self.tmpdir.cleanup()

  def test_open_regular_reads_file(self):
    path = self.root / "ok.json"
    path.write_text('{"a":1}\n', encoding="utf-8")
    self.assertEqual(mod.open_regular(path, 1024), b'{"a":1}\n')

  def test_open_regular_refuses_symlink(self):
    target = self.root / "secret"
    target.write_text("token", encoding="utf-8")
    link = self.root / "grok.json"
    link.symlink_to(target)
    with self.assertRaises(OSError):
      mod.open_regular(link, 1024)

  def test_open_regular_refuses_fifo(self):
    fifo = self.root / "pipe"
    os.mkfifo(fifo)
    with self.assertRaises(OSError):
      mod.open_regular(fifo, 1024)

  def test_open_regular_refuses_oversize(self):
    path = self.root / "big.json"
    path.write_bytes(b"x" * 64)
    with self.assertRaises(OSError):
      mod.open_regular(path, 8)

  def test_load_json_requires_safe_basename(self):
    hidden = self.root / ".env.json"
    hidden.write_text('{"key":"nope"}', encoding="utf-8")
    self.assertIsNone(mod.load_json_file(hidden, 1024))
    record = self.root / "grok.json"
    record.write_text('{"id":"grok","ready":true}', encoding="utf-8")
    self.assertEqual(mod.load_json_file(record, 1024)["id"], "grok")

  def test_list_usage_skips_symlink_and_unsafe_names(self):
    (self.root / "grok.json").write_text('{"id":"grok"}', encoding="utf-8")
    (self.root / "..not.json").write_text("{}", encoding="utf-8")
    secret = self.root / "secret.json"
    secret.write_text('{"id":"secret"}', encoding="utf-8")
    link = self.root / "claude.json"
    link.symlink_to(secret)
    listed = mod.list_usage_records(self.root)
    self.assertEqual(listed["ids"], ["grok", "secret"])

  def test_load_text_only_agent_basename_and_safe_id(self):
    agent = self.root / "agent"
    agent.write_text("grok\n", encoding="utf-8")
    self.assertEqual(mod.load_text_file(agent, 256), "grok")
    agent.write_text("../etc/passwd\n", encoding="utf-8")
    self.assertEqual(mod.load_text_file(agent, 256), "")
    other = self.root / "not-agent"
    other.write_text("grok\n", encoding="utf-8")
    self.assertEqual(mod.load_text_file(other, 256), "")

  def test_load_snapshots_skips_symlink(self):
    good = self.root / "host.json"
    good.write_text('{"providers":{"grok":{"todayPrompts":1}}}', encoding="utf-8")
    target = Path(self.root).parent / "outside-secret.json"
    target.write_text('{"providers":{"evil":{}}}', encoding="utf-8")
    self.addCleanup(lambda: target.unlink(missing_ok=True))
    link = self.root / "peer.json"
    link.symlink_to(target)
    snaps = mod.load_snapshots(self.root)["snapshots"]
    self.assertEqual(len(snaps), 1)
    self.assertIn("grok", snaps[0]["providers"])

  def test_is_safe_agent_id(self):
    self.assertTrue(mod.is_safe_agent_id("grok"))
    self.assertTrue(mod.is_safe_agent_id("claude-4"))
    self.assertFalse(mod.is_safe_agent_id(""))
    self.assertFalse(mod.is_safe_agent_id("../grok"))
    self.assertFalse(mod.is_safe_agent_id("grok/json"))
    self.assertFalse(mod.is_safe_agent_id("-dash"))
    self.assertFalse(mod.is_safe_agent_id("a" * 65))


class ParseLimitsTests(unittest.TestCase):
  def test_weekly_pool_and_product_segments(self):
    limits = mod.parse_limits({
      "currentPeriod": {
        "type": "USAGE_PERIOD_TYPE_WEEKLY",
        "start": "2026-08-24T23:52:40+00:00",
        "end": "2026-08-31T23:52:40+00:00",
      },
      "creditUsagePercent": 73.0,
      "productUsage": [
        {"product": "GrokBuild", "usagePercent": 68.0},
        {"product": "GrokChat", "usagePercent": 5.0},
      ],
    })
    self.assertEqual([row["kind"] for row in limits], ["pool", "product", "product"])
    self.assertEqual(limits[0]["title"], "Weekly")
    self.assertAlmostEqual(limits[0]["percent"], 0.73)
    self.assertEqual(limits[1]["title"], "Grok Build")
    self.assertAlmostEqual(limits[1]["percent"], 0.68)
    self.assertEqual(limits[2]["title"], "Chat")
    self.assertAlmostEqual(limits[2]["percent"], 0.05)

  def test_product_title_drops_grok_on_chat(self):
    self.assertEqual(mod.product_title("GrokBuild"), "Grok Build")
    self.assertEqual(mod.product_title("GrokChat"), "Chat")
    self.assertEqual(mod.product_title("GrokImagine"), "Imagine")


class ScanSkipTests(unittest.TestCase):
  def test_scan_skips_symlink_updates(self):
    with tempfile.TemporaryDirectory() as raw:
      root = Path(raw)
      real = root / "real"
      real.mkdir()
      (real / "updates.jsonl").write_text("{}\n", encoding="utf-8")
      linked = root / "linked"
      linked.mkdir()
      (linked / "updates.jsonl").symlink_to(real / "updates.jsonl")
      stats = mod.scan_sessions(root)
      self.assertEqual(stats["totalPrompts"], 0)


if __name__ == "__main__":
  unittest.main()
