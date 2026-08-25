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
  readonly property int maxRecordChars: 256 * 1024

  property string _buf: ""
  property bool _overflow: false
  property int _loadGen: 0

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
    onExited: {
      if (readProc.job !== root._loadGen) return
      if (root._overflow) {
        root.record = null
        return
      }
      root.parse(root._buf)
    }
  }

  Component.onCompleted: root.reloadBounded()
  onPathChanged: root.reloadBounded()
  onReaderChanged: root.reloadBounded()

  function reloadBounded() {
    root._loadGen++
    if (root.reader === "" || root.path === "" || root.agentId === "") {
      root.record = null
      return
    }
    root._buf = ""
    root._overflow = false
    if (readProc.running) readProc.running = false
    readProc.job = root._loadGen
    readProc.command = ["python3", "-B", root.reader, "--load-json", root.path]
    readProc.running = true
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      var record = parsed && parsed.ok === true ? parsed.record : null
      if (!record || typeof record !== "object") {
        root.record = null
        return
      }
      var id = String(record.id || "")
      if (id !== root.agentId) record.id = root.agentId
      root.record = record
    } catch (e) {
      console.warn("agents", "Ignoring bad usage record", root.path, e)
      root.record = null
    }
  }
}
