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
