import QtQuick
import Quickshell.Io

// One agent's usage record. FileView only watches; the bytes are read through
// the bounded no-follow helper so a planted symlink, FIFO, or huge file never
// lands in the long-lived shell.
Item {
  id: root
  visible: false

  property string agentId: ""
  property string path: ""
  property string reader: ""
  property var record: null
  property bool deferRecord: false
  property int _readEpoch: 0
  readonly property int maxRecordChars: 256 * 1024

  property string _buf: ""
  property bool _overflow: false
  property int _loadGen: 0
  property bool _reloadRequested: false

  FileView {
    path: root.path
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: root.reloadBounded()
  }

  Process {
    id: readProc
    running: false
    property int job: 0
    property int epoch: 0
    property string sourcePath: ""
    property string sourceReader: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (readProc.job !== root._loadGen || root._overflow) return
        var piece = String(chunk || "")
        if (root._buf.length + piece.length > root.maxRecordChars) {
          root._overflow = true
          readProc.running = false
          return
        }
        root._buf += piece
      }
    }
    onExited: function(exitCode) {
      if (readProc.job === root._loadGen && readProc.sourcePath === root.path
          && readProc.sourceReader === root.reader && readProc.epoch === root._readEpoch
          && !root.deferRecord && exitCode === 0 && !root._overflow) {
        root.parse(root._buf)
      }
      if (root._reloadRequested) {
        root._reloadRequested = false
        Qt.callLater(root.reloadBounded)
      }
    }
  }

  Component.onCompleted: root.reloadBounded()
  onPathChanged: root.reloadBounded()
  onReaderChanged: root.reloadBounded()
  onDeferRecordChanged: {
    root._readEpoch++
    if (!root.deferRecord) root.reloadBounded()
  }

  function reloadBounded() {
    if (root.reader === "" || root.path === "" || root.agentId === "") {
      root.record = null
      return
    }
    // The Codex collector may publish an error before recovery finishes.
    // Keep the displayed record until the entire update has completed.
    if (root.deferRecord) return
    // A watcher event can arrive while the helper is reading. Queue one more
    // read instead of killing it and mistaking its incomplete output for JSON.
    if (readProc.running) {
      root._reloadRequested = true
      return
    }
    root._loadGen++
    root._buf = ""
    root._overflow = false
    readProc.job = root._loadGen
    readProc.epoch = root._readEpoch
    readProc.sourcePath = root.path
    readProc.sourceReader = root.reader
    readProc.command = ["python3", "-B", root.reader, "--load-json", root.path]
    readProc.running = true
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      var record = parsed && parsed.ok === true ? parsed.record : null
      if (!record || typeof record !== "object" || Array.isArray(record)) return
      // A transient limits probe is not a replacement for a successful one.
      // Keep the previous Codex record until a valid quota response arrives.
      if (root.agentId === "codex" && root.record && root.record.limits
          && root.record.limits.length > 0 && (!record.limits || record.limits.length === 0)
          && (String(record.usageStatusText || "") === ""
              || String(record.usageStatusText || "") === "Codex limits unavailable")) return
      var id = String(record.id || "")
      if (id !== root.agentId) record.id = root.agentId
      root.record = record
    } catch (e) {
      console.warn("agents", "Ignoring bad usage record", root.path, e)
    }
  }
}
