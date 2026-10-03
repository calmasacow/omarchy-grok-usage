"""Exercise watcher refreshes using the installed Quickshell runtime."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('qs'), 'Quickshell is not installed')
class AgentRefreshTests(unittest.TestCase):
  def test_repeated_refresh_keeps_limit_windows(self):
    with tempfile.TemporaryDirectory(prefix='grok-agent-refresh-') as raw:
      root = Path(raw)
      shutil.copy(ROOT / 'Agent.qml', root / 'Agent.qml')
      (root / 'record.json').write_text(json.dumps({'id': 'codex', 'limits': [
        {'label': '5h window', 'percent': 0.1}, {'label': 'Weekly (7-day)', 'percent': 0.04}]}))
      (root / 'reader.py').write_text('import json,sys,time\nfrom pathlib import Path\ntime.sleep(0.07)\nprint(json.dumps({"ok":True,"record":json.loads(Path(sys.argv[-1]).read_text())}))\n')
      (root / 'shell.qml').write_text('''import QtQuick
import Quickshell
ShellRoot {
  Agent {
    id: agent
    agentId: "codex"
    path: "''' + str(root / 'record.json') + '''"
    reader: "''' + str(root / 'reader.py') + '''"
    property bool sawValid: false
    property int lostLimits: 0
    onRecordChanged: {
      if (record && record.limits && record.limits.length === 2) sawValid = true
      else if (sawValid) lostLimits++
    }
  }
  Timer { interval: 180; running: true; onTriggered: spam.start() }
  Timer {
    id: spam
    property int ticks: 0
    interval: 10
    repeat: true
    onTriggered: {
      agent.reloadBounded()
      ticks++
      if (ticks === 25) stop()
    }
  }
  Timer { interval: 850; running: true; onTriggered: {
    console.log("AGENT_RESULT", agent.sawValid, agent.lostLimits, agent.record ? agent.record.limits.length : -1)
    Qt.quit()
  } }
}
''')
      env = os.environ.copy()
      env['QT_QPA_PLATFORM'] = 'offscreen'
      env.pop('WAYLAND_DISPLAY', None)
      result = subprocess.run(['qs', '-p', str(root / 'shell.qml'), '--no-color'],
                              text=True, capture_output=True, env=env, timeout=8)
      output = result.stdout + result.stderr
      self.assertEqual(result.returncode, 0, output)
      self.assertIn('AGENT_RESULT true 0 2', output)
      self.assertNotIn('Parse error', output)

  def run_report_sequence(self, final_status='', empty=False):
    with tempfile.TemporaryDirectory(prefix='grok-codex-refresh-') as raw:
      root = Path(raw)
      shutil.copy(ROOT / 'Agent.qml', root / 'Agent.qml')
      good = {'id': 'codex', 'limits': [{'label': '5h window', 'percent': 0.1}, {'label': 'Weekly', 'percent': 0.04}], 'usageStatusText': ''}
      transient = {'id': 'codex', 'limits': [], 'usageStatusText': 'Codex limits unavailable'}
      final = dict(good, limits=[{'label': '5h window', 'percent': 0.2}, {'label': 'Weekly', 'percent': 0.05}]) if not final_status else dict(transient, usageStatusText=final_status)
      (root / 'record.json').write_text(json.dumps(good))
      (root / 'reader.py').write_text('import sys,json,time\nfrom pathlib import Path\ntime.sleep(0.04)\ntry: record=json.loads(Path(sys.argv[-1]).read_text());print(json.dumps({"ok":True,"record":record}))\nexcept ValueError: print(json.dumps({"ok":False}))\n')
      qml = '''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  Agent {
    id: agent
    agentId: "codex"
    path: RECORD_PATH
    reader: READER_PATH
    property int errorCount: 0
    onRecordChanged: if (record && record.usageStatusText) errorCount++
  }
  FileView { id: data; path: agent.path; preload: false; blockWrites: true }
  Timer { interval: 150; running: true; onTriggered: {
    agent.deferRecord = true
    data.setText(INTERMEDIATE_JSON)
    agent.reloadBounded()
  } }
  Timer { interval: 300; running: true; onTriggered: agent.deferRecord = false }
  Timer { interval: 450; running: true; onTriggered: {
    console.log("INTERMEDIATE", agent.errorCount, agent.record ? agent.record.limits.length : -1)
    data.setText(FINAL_JSON)
    agent.reloadBounded()
  } }
  Timer { interval: 700; running: true; onTriggered: {
    console.log("FINAL", agent.errorCount, agent.record ? agent.record.limits.length : -1, agent.record && agent.record.limits.length ? agent.record.limits[0].percent : -1)
    Qt.quit()
  } }
}
'''
      qml = qml.replace('RECORD_PATH', json.dumps(str(root / 'record.json')))
      qml = qml.replace('READER_PATH', json.dumps(str(root / 'reader.py')))
      qml = qml.replace('INTERMEDIATE_JSON', json.dumps('' if empty else json.dumps(transient)))
      qml = qml.replace('FINAL_JSON', json.dumps(json.dumps(final)))
      (root / 'shell.qml').write_text(qml)
      env = os.environ.copy()
      env['QT_QPA_PLATFORM'] = 'offscreen'
      env.pop('WAYLAND_DISPLAY', None)
      result = subprocess.run(['qs', '-p', str(root / 'shell.qml'), '--no-color'], text=True, capture_output=True, env=env, timeout=8)
      output = result.stdout + result.stderr
      self.assertEqual(result.returncode, 0, output)
      self.assertIn('INTERMEDIATE 0 2', output)
      return output

  def test_transient_error_keeps_meters_until_valid_result(self):
    self.assertIn('FINAL 0 2 0.2', self.run_report_sequence())

  def test_empty_report_keeps_meters_until_valid_result(self):
    self.assertIn('FINAL 0 2 0.2', self.run_report_sequence(empty=True))

  def test_explicit_unavailable_status_is_displayed(self):
    self.assertRegex(self.run_report_sequence(final_status='Codex unavailable'), r'FINAL [1-9][0-9]* 0 -1')
