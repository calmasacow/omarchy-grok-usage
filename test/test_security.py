#!/usr/bin/env python3
"""Regression tests for marketplace security review #2379."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import os
import json
import subprocess
import sys
from unittest.mock import patch
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


class SnapshotPublishTests(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.addCleanup(self.tmp.cleanup)
    self.root = Path(self.tmp.name)
    self.sync = self.root / "sync"
    self.sync.mkdir()
    self.target = self.root / "outside.json"
    self.target.write_text("must survive")
    self.payload = {"deviceId": "host", "providers": {"grok": {"todayPrompts": 2}}}

  def publish(self, name="host.json"):
    mod.write_sync_snapshot(self.sync, name, self.payload)

  def test_snapshot_symlink_target_unchanged(self):
    snapshot = self.sync / "host.json"
    snapshot.symlink_to(self.target)
    self.publish()
    self.assertEqual(self.target.read_text(), "must survive")
    self.assertFalse(snapshot.is_symlink())
    self.assertEqual(json.loads(snapshot.read_text()), self.payload)
    self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)

  def test_dangling_symlink_does_not_create_outside_file(self):
    missing = self.root / "missing"
    (self.sync / "host.json").symlink_to(missing)
    self.publish()
    self.assertFalse(missing.exists())
    self.assertEqual(json.loads((self.sync / "host.json").read_text()), self.payload)

  def test_hardlink_target_unchanged(self):
    os.link(self.target, self.sync / "host.json")
    self.publish()
    self.assertEqual(self.target.read_text(), "must survive")

  def test_repeated_publish_and_new_directories(self):
    self.sync = self.root / "new" / "nested"
    self.publish()
    self.payload["providers"]["grok"]["todayPrompts"] = 3
    self.publish()
    self.assertEqual(json.loads((self.sync / "host.json").read_text()), self.payload)
    self.assertEqual([p.name for p in self.sync.iterdir()], ["host.json"])

  def test_sync_directory_symlink_rejected(self):
    linked = self.root / "linked"
    linked.symlink_to(self.sync, target_is_directory=True)
    self.sync = linked
    with self.assertRaises(OSError):
      self.publish()
    self.assertFalse((linked / "host.json").exists())

  def test_ancestor_symlink_rejected(self):
    linked = self.root / "linked"
    linked.symlink_to(self.sync, target_is_directory=True)
    self.sync = linked / "nested"
    with self.assertRaises(OSError):
      self.publish()
    self.assertFalse((self.root / "sync" / "nested").exists())

  def test_directory_replaced_during_publication(self):
    outside = self.root / "outside"
    outside.mkdir()
    victim = outside / "host.json"
    victim.write_text("must survive")
    pinned = self.root / "original-sync"
    real_replace = os.replace
    def replace_after_swap(src, dst, **kwargs):
      self.sync.rename(pinned)
      self.sync.symlink_to(outside, target_is_directory=True)
      return real_replace(src, dst, **kwargs)
    with patch.object(mod.os, "replace", side_effect=replace_after_swap):
      self.publish()
    self.assertEqual(victim.read_text(), "must survive")
    self.assertEqual(json.loads((pinned / "host.json").read_text()), self.payload)
    self.assertEqual([p.name for p in pinned.iterdir()], ["host.json"])

  def test_destination_replaced_immediately_before_rename(self):
    real_replace = os.replace
    def replace_after_swap(src, dst, **kwargs):
      (self.sync / "host.json").symlink_to(self.target)
      return real_replace(src, dst, **kwargs)
    with patch.object(mod.os, "replace", side_effect=replace_after_swap):
      self.publish()
    self.assertEqual(self.target.read_text(), "must survive")
    self.assertFalse((self.sync / "host.json").is_symlink())

  def test_temp_collision_does_not_follow_or_delete_symlink(self):
    temp = self.sync / (".host.json." + "00" * 12 + ".tmp")
    temp.symlink_to(self.target)
    with patch.object(mod.os, "urandom", return_value=bytes(12)):
      with self.assertRaises(FileExistsError):
        self.publish()
    self.assertEqual(self.target.read_text(), "must survive")
    self.assertTrue(temp.is_symlink())

  def test_failed_rename_cleans_temporary_file(self):
    (self.sync / "host.json").mkdir()
    with self.assertRaises(OSError):
      self.publish()
    self.assertEqual([p.name for p in self.sync.iterdir()], ["host.json"])

  def test_invalid_filename_rejected(self):
    for name in ["../outside.json", "/outside.json", "..", ".hidden.json", "bad/name.json", "a" * 101 + ".json"]:
      with self.subTest(name=name), self.assertRaises(ValueError):
        self.publish(name)
    self.assertEqual(self.target.read_text(), "must survive")

  def test_cli_publishes_and_rejects_bad_input(self):
    command = [sys.executable, str(SCRIPT), "--write-snapshot", str(self.sync), "host.json"]
    result = subprocess.run(command, input=json.dumps(self.payload), text=True, capture_output=True)
    self.assertEqual(result.returncode, 0, result.stderr)
    for raw in ["{bad", "[]", '{"providers":[]}', "x" * (mod.MAX_SNAPSHOT_BYTES + 1)]:
      result = subprocess.run(command, input=raw, text=True, capture_output=True)
      self.assertEqual(result.returncode, 1, result.stderr)
      self.assertEqual(json.loads((self.sync / "host.json").read_text()), self.payload)


class CodexLimitsTests(unittest.TestCase):
  def setUp(self):
    self.tmp = tempfile.TemporaryDirectory()
    self.addCleanup(self.tmp.cleanup)
    self.root = Path(self.tmp.name)
    self.windows = {"planType": "plus", "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1791027153},
                    "secondary": {"usedPercent": 4, "windowDurationMins": 10080, "resetsAt": 1791580264}}

  def fixture(self, response, split=False):
    exe = self.root / "codex"
    exe.write_text("#!" + sys.executable + "\n" + "import sys,json,time\n" +
      "response = " + repr(response) + "\n" +
      "for line in sys.stdin:\n" +
      " req=json.loads(line)\n" +
      " if req.get('method')=='initialize':\n" +
      "  raw=(json.dumps({'id':req['id'],'result':{}})+'\\n'+json.dumps({'method':'notice','params':{}})+'\\n').encode()\n" +
      " elif req.get('method')=='account/rateLimits/read':\n" +
      "  raw=(json.dumps(dict(response,id=req['id']))+'\\n').encode()\n" +
      " else: continue\n" +
      (" sys.stdout.buffer.write(raw[:10]);sys.stdout.buffer.flush();time.sleep(0.01);raw=raw[10:]\n" if split else "") +
      " sys.stdout.buffer.write(raw);sys.stdout.buffer.flush()\n")
    exe.chmod(0o700)
    return patch.object(mod.shutil, "which", return_value=str(exe))

  def test_rpc_coalesced_notification_and_windows(self):
    with self.fixture({"result": {"rateLimits": self.windows}}):
      data = mod.fetch_codex_limit_windows()
    self.assertEqual([x["label"] for x in data["limits"]], ["5h window", "Weekly (7-day)"])
    self.assertEqual([x["percent"] for x in data["limits"]], [0.10, 0.04])
    self.assertEqual(data["tierLabel"], "plus")

  def test_rpc_split_frames_and_limit_id_mapping(self):
    with self.fixture({"result": {"rateLimitsByLimitId": {"codex": self.windows}}}, split=True):
      data = mod.fetch_codex_limit_windows()
    self.assertEqual(len(data["limits"]), 2)

  def test_rpc_error_and_empty_limits_rejected(self):
    for response in [{"error": {"code": -1}}, {"result": {}}, {"result": {"rateLimits": {}}}]:
      with self.subTest(response=response), self.fixture(response), self.assertRaises(ValueError):
        mod.fetch_codex_limit_windows()

  def test_rpc_bounded_output(self):
    with self.fixture({"result": {"rateLimits": self.windows}}), patch.object(mod, "MAX_STDOUT_BYTES", 12):
      with self.assertRaises(ValueError):
        mod.fetch_codex_limit_windows()

  def test_repair_restores_missing_windows(self):
    path = self.root / "codex.json"
    path.write_text(json.dumps({"id": "codex", "ready": True, "hasLocalStats": True, "limits": [],
                               "todayPrompts": 42, "usageStatusText": "Codex limits unavailable", "authHelpText": "account/read"}))
    with patch.object(mod, "usage_dir", return_value=self.root), self.fixture({"result": {"rateLimits": self.windows}}):
      self.assertEqual(mod.repair_codex_record(), 0)
    record = json.loads(path.read_text())
    self.assertEqual(len(record["limits"]), 2)
    self.assertEqual(record["todayPrompts"], 42)
    self.assertEqual(record["usageStatusText"], "")
    self.assertEqual(path.stat().st_mode & 0o777, 0o600)

  def test_failed_recovery_preserves_error(self):
    path = self.root / "codex.json"
    original = json.dumps({"ready": True, "hasLocalStats": True, "limits": [], "usageStatusText": "Codex limits unavailable"})
    path.write_text(original)
    with patch.object(mod, "usage_dir", return_value=self.root), patch.object(mod, "fetch_codex_limit_windows", side_effect=OSError("offline")):
      self.assertEqual(mod.repair_codex_record(), 1)
    self.assertEqual(path.read_text(), original)

  def test_valid_limits_do_not_trigger_extra_rpc(self):
    path = self.root / "codex.json"
    path.write_text(json.dumps({"ready": True, "hasLocalStats": True, "limits": [{"percent": 0.1}]}))
    with patch.object(mod, "usage_dir", return_value=self.root), patch.object(mod, "fetch_codex_limit_windows") as fetch:
      self.assertEqual(mod.repair_codex_record(), 0)
      fetch.assert_not_called()


  def test_collection_does_not_publish_intermediate_error(self):
    path = self.root / "codex.json"
    original = json.dumps({"id": "codex", "limits": [{"percent": 0.1}], "usageStatusText": ""})
    path.write_text(original)
    reported = {"id": "codex", "limits": [], "usageStatusText": "Codex limits unavailable", "todayPrompts": 42}
    def recover():
      self.assertEqual(path.read_text(), original)
      return {"limits": [{"label": "5h window", "percent": 0.2}], "tierLabel": "plus"}
    with patch.object(mod, "usage_dir", return_value=self.root), patch.object(mod.shutil, "which", return_value="collector"), patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(reported).encode())), patch.object(mod, "fetch_codex_limit_windows", side_effect=recover):
      self.assertEqual(mod.collect_codex_record("limits"), 0)
    record = json.loads(path.read_text())
    self.assertEqual(record["usageStatusText"], "")
    self.assertEqual(record["limits"][0]["percent"], 0.2)
    self.assertEqual(record["todayPrompts"], 42)

  def test_empty_or_invalid_collection_preserves_previous_report(self):
    path = self.root / "codex.json"
    path.write_text("previous successful report")
    for output in [b"", b"not json", b"[]", b'{"id":"claude"}', b"x" * (mod.MAX_USAGE_RECORD_BYTES + 1)]:
      with self.subTest(output=output[:20]), patch.object(mod, "usage_dir", return_value=self.root), patch.object(mod.shutil, "which", return_value="collector"), patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, output)):
        self.assertEqual(mod.collect_codex_record("limits"), 1)
        self.assertEqual(path.read_text(), "previous successful report")

  def test_failed_collection_recovery_preserves_previous_report(self):
    path = self.root / "codex.json"
    path.write_text("previous successful report")
    reported = {"id": "codex", "limits": [], "usageStatusText": "Codex limits unavailable"}
    with patch.object(mod, "usage_dir", return_value=self.root), patch.object(mod.shutil, "which", return_value="collector"), patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(reported).encode())), patch.object(mod, "fetch_codex_limit_windows", side_effect=OSError("offline")):
      self.assertEqual(mod.collect_codex_record("limits"), 1)
    self.assertEqual(path.read_text(), "previous successful report")

  def test_explicit_unavailable_collection_is_published(self):
    reported = {"id": "codex", "limits": [], "usageStatusText": "Codex unavailable"}
    with patch.object(mod, "usage_dir", return_value=self.root), patch.object(mod.shutil, "which", return_value="collector"), patch.object(mod.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps(reported).encode())), patch.object(mod, "fetch_codex_limit_windows") as fetch:
      self.assertEqual(mod.collect_codex_record("limits"), 0)
      fetch.assert_not_called()
    self.assertEqual(json.loads((self.root / "codex.json").read_text())["usageStatusText"], "Codex unavailable")


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
