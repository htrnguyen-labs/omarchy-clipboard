import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui
import "ClipboardHistory.js" as ClipboardHistory
import "StreamGuard.js" as StreamGuard

Item {
  id: root

  readonly property string omarchyBin: "/usr/share/omarchy/bin"
  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool clearConfirmOpen: false
  property var history: []

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string captureScript: pluginDir + "/capture.sh"
  readonly property string stateHelper: pluginDir + "/clipboard-state"
  readonly property var processEnvironment: ({
    PATH: "/usr/bin:/bin",
    HOME: Quickshell.env("HOME"),
    XDG_STATE_HOME: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state",
    XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
    WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY"),
    LANG: "C.UTF-8"
  })
  property string pendingState: ""
  property bool captureStarted: false
  property bool stopping: false
  readonly property int finiteOutputLimit: 262144
  readonly property int watcherOutputLimit: 262144
  readonly property int watcherLineLimit: 70000
  readonly property bool darkMode: Color.background.r * 0.2126 + Color.background.g * 0.7152 + Color.background.b * 0.0722 < 0.5
  property color background: darkMode ? "#090d12" : "#f7f9fb"
  property color foreground: darkMode ? "#dce4ed" : "#18212b"
  property color muted: darkMode ? "#788595" : "#667281"
  property color border: darkMode ? "#27313b" : "#d7dde5"
  property color panelSurface: darkMode ? "#0d1218" : "#ffffff"
  property color raisedSurface: darkMode ? "#111820" : "#f0f3f7"
  property color accent: darkMode ? "#ff4d43" : "#df3f38"
  property var borderSpec: Border.surfaceSpec("menu", "border", border, 1)
  property color scrim: darkMode ? "#c0000000" : "#66000000"
  property color selectedBackground: darkMode ? "#25303b" : "#e9eef5"
  property color selectedText: darkMode ? "#ffffff" : "#111820"
  readonly property int cornerRadius: Math.max(Style.cornerRadius, Style.space(10))
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(54), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(940), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int historyLimit: 300

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.cancelClearHistory()
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function normalizeEntry(value) {
    return ClipboardHistory.normalizeEntry(value)
  }

  function entryKey(entry) {
    return ClipboardHistory.entryKey(entry)
  }

  function loadHistory(raw) {
    root.history = ClipboardHistory.parseHistory(raw)
    if (root.opened) root.rebuildDisplay()
  }

  function saveHistory() {
    root.pendingState = JSON.stringify(root.history.slice(0, root.historyLimit))
    root.flushState()
  }

  function flushState() {
    if (stateWriteProc.running || !root.pendingState) return
    stateWriteProc.payload = root.pendingState
    root.pendingState = ""
    stateWriteProc.running = true
  }

  function startCapture() {
    if (root.captureStarted) return
    root.captureStarted = true
    currentProc.running = true
    textWatchProc.running = true
    imageWatchProc.running = true
  }

  function addClipboardEntry(entry) {
    var normalized = ClipboardHistory.normalizeEntry(entry)
    if (!normalized) return

    root.history = ClipboardHistory.addEntry(root.history, normalized, root.historyLimit)
    root.saveHistory()
    if (root.opened) root.rebuildDisplay()
  }

  function addClipboardJson(line) {
    root.addClipboardEntry(ClipboardHistory.parseEntryJson(line))
  }

  function requestClearHistory() {
    if (root.history.length === 0) return
    clearConfirm.selectedIndex = 1
    root.clearConfirmOpen = true
  }

  function cancelClearHistory() {
    root.clearConfirmOpen = false
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmClearHistory() {
    root.history = ClipboardHistory.clearHistory()
    root.saveHistory()
    root.selectedIndex = 0
    root.cursorActive = false
    root.disarmPointer()
    root.clearConfirmOpen = false
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function removeDisplayIndex(index) {
    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    if (row.entryType === "section") return
    root.history = ClipboardHistory.removeEntryAt(root.history, row.historyIndex)
    root.saveHistory()

    if (displayModel.count <= 1) {
      root.selectedIndex = 0
      root.cursorActive = false
    } else if (root.selectedIndex >= displayModel.count - 1) {
      root.selectedIndex = displayModel.count - 2
    }

    root.disarmPointer()
    root.rebuildDisplay()
  }

  function togglePinIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    root.history = ClipboardHistory.togglePinAt(root.history, displayModel.get(index).historyIndex)
    root.saveHistory()
    root.selectedIndex = 0
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function movePinnedIndex(index, direction) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (!row.pinned) return
    root.history = ClipboardHistory.movePinnedAt(root.history, row.historyIndex, direction)
    root.saveHistory()
    root.rebuildDisplay()
    root.selectedIndex = Math.max(1, Math.min(index + direction, displayModel.count - 1))
  }

  function rebuildDisplay() {
    var rows = ClipboardHistory.displayRows(root.history, root.filterText, 50)

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      displayModel.append({
        entryType: row.entryType,
        fullText: row.fullText,
        previewText: row.previewText,
        previewImage: row.previewImage ? Util.fileUrl(row.previewImage) : "",
        path: row.path,
        mime: row.mime,
        historyIndex: row.index,
        pinned: row.pinned
      })
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0
    if (displayModel.count > 0 && displayModel.get(selectedIndex).entryType === "section") selectedIndex++

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex <= 1 ? 0 : root.selectedIndex, root.selectedIndex <= 1 ? ListView.Beginning : ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      var next = selectedIndex
      do next = (next + delta + displayModel.count) % displayModel.count
      while (displayModel.get(next).entryType === "section")
      selectedIndex = next
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    if (displayModel.get(root.selectedIndex).entryType === "section") {
      root.selectedIndex = Math.min(root.selectedIndex + 1, displayModel.count - 1)
      if (displayModel.get(root.selectedIndex).entryType === "section") root.selectedIndex = Math.max(0, root.selectedIndex - 1)
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.entryType === "section") return
    root.applySelected(row)
  }

  function copyIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.entryType === "section") return
    root.copySelected(row)
  }

  function openIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.entryType === "section") return
    root.openSelected(row)
  }

  function applySelected(row) {
    if (!row) return
    root.opened = false
    if (row.entryType === "image") {
      Quickshell.execDetached([root.omarchyBin + "/omarchy-clipboard-paste-file", row.mime, row.path])
    } else if (row.fullText) {
      Quickshell.execDetached([root.omarchyBin + "/omarchy-clipboard-paste-text", "--shift-insert", "--history-index", String(row.historyIndex)])
    }
  }

  function copySelected(row) {
    if (!row) return
    root.opened = false
    if (row.entryType === "image") {
      Quickshell.execDetached([root.omarchyBin + "/omarchy-clipboard-paste-file", "--copy-only", row.mime, row.path])
    } else if (row.fullText) {
      Quickshell.execDetached([root.omarchyBin + "/omarchy-clipboard-paste-text", "--copy-only", "--history-index", String(row.historyIndex)])
    }
  }

  function openSelected(row) {
    if (!row) return
    root.opened = false
    Quickshell.execDetached([root.omarchyBin + "/omarchy-clipboard-open", "--history-index", String(row.historyIndex)])
  }

  Component.onCompleted: stateReadProc.running = true
  Component.onDestruction: {
    root.stopping = true
    textWatchProc.running = false
    imageWatchProc.running = false
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: stateReadProc
    property bool overflow: false
    command: ["/usr/bin/timeout", "--signal=TERM", "--kill-after=1s", "3s", "/usr/bin/python3", root.stateHelper, "read"]
    clearEnvironment: true
    environment: root.processEnvironment
    onStarted: overflow = false
    stdout: StdioCollector {
      id: stateReadOut
      waitForEnd: false
      onDataChanged: if (data.byteLength > root.finiteOutputLimit) {
        stateReadProc.overflow = true
        stateReadProc.signal(15)
      }
      onStreamFinished: {
        root.loadHistory(stateReadProc.overflow ? "[]" : text)
        root.startCapture()
      }
    }
  }

  Process {
    id: stateWriteProc
    property string payload: ""
    command: ["/usr/bin/timeout", "--signal=TERM", "--kill-after=1s", "3s", "/usr/bin/python3", root.stateHelper, "write"]
    stdinEnabled: true
    clearEnvironment: true
    environment: root.processEnvironment
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    onExited: root.flushState()
  }

  Process {
    id: currentProc
    property bool overflow: false
    command: ["/usr/bin/timeout", "--signal=TERM", "--kill-after=1s", "5s", root.captureScript]
    clearEnvironment: true
    environment: root.processEnvironment
    onStarted: overflow = false
    stdout: StdioCollector {
      id: currentOut
      waitForEnd: false
      onDataChanged: if (data.byteLength > root.finiteOutputLimit) {
        currentProc.overflow = true
        currentProc.signal(15)
      }
      onStreamFinished: if (!currentProc.overflow) root.addClipboardJson(text)
    }
  }

  Process {
    id: textWatchProc
    command: ["/usr/bin/timeout", "--signal=TERM", "--kill-after=1s", "1h", "/usr/bin/setpriv", "--pdeathsig", "TERM", "/usr/bin/wl-paste", "--type", "text", "--watch", root.captureScript, "text"]
    clearEnvironment: true
    environment: root.processEnvironment
    onStarted: textWatchOut.guardState = { offset: textWatchOut.text.length, pending: "" }
    onExited: if (!root.stopping) watchRestartTimer.restart()
    stdout: StdioCollector {
      id: textWatchOut
      property var guardState: StreamGuard.empty()
      waitForEnd: false
      onDataChanged: {
        var result = StreamGuard.consume(guardState, text, data.byteLength, root.watcherOutputLimit, root.watcherLineLimit)
        guardState = result.state
        if (result.overflow) {
          textWatchProc.signal(15)
          return
        }
        for (var i = 0; i < result.lines.length; i++) root.addClipboardJson(result.lines[i])
      }
    }
  }

  Process {
    id: imageWatchProc
    command: ["/usr/bin/timeout", "--signal=TERM", "--kill-after=1s", "1h", "/usr/bin/setpriv", "--pdeathsig", "TERM", "/usr/bin/wl-paste", "--type", "image/png", "--watch", root.captureScript, "image/png"]
    clearEnvironment: true
    environment: root.processEnvironment
    onStarted: imageWatchOut.guardState = { offset: imageWatchOut.text.length, pending: "" }
    onExited: if (!root.stopping) watchRestartTimer.restart()
    stdout: StdioCollector {
      id: imageWatchOut
      property var guardState: StreamGuard.empty()
      waitForEnd: false
      onDataChanged: {
        var result = StreamGuard.consume(guardState, text, data.byteLength, root.watcherOutputLimit, root.watcherLineLimit)
        guardState = result.state
        if (result.overflow) {
          imageWatchProc.signal(15)
          return
        }
        for (var i = 0; i < result.lines.length; i++) root.addClipboardJson(result.lines[i])
      }
    }
  }

  // A watcher that dies takes clipboard history with it, silently: copying still
  // works, the picker still opens, and the old entries are all still there, so
  // nothing recorded until the next shell reload. Bring it back instead.
  Timer {
    id: watchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (!root.stopping && !textWatchProc.running) textWatchProc.running = true
      if (!root.stopping && !imageWatchProc.running) imageWatchProc.running = true
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-clipboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.clearConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.requestClearHistory()
            else root.removeDisplayIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) {
            root.togglePinIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive && (event.modifiers & Qt.AltModifier)) root.openIndex(root.selectedIndex)
            else if (root.cursorActive && (event.modifiers & Qt.ShiftModifier)) root.copyIndex(root.selectedIndex)
            else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: clearConfirm

          anchors.fill: parent
          opened: root.clearConfirmOpen
          z: 10
          message: "Delete entire clipboard history?"
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelClearHistory()
          onConfirmed: root.confirmClearHistory()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: root.raisedSurface
          border.width: 1
          border.color: root.border

          Row {
            anchors.fill: parent
            anchors.leftMargin: Style.space(16)
            anchors.rightMargin: Style.space(16)
            spacing: Style.space(12)

            Text {
              id: searchIcon
              anchors.verticalCenter: parent.verticalCenter
              text: "⌕"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width - searchIcon.width - searchShortcut.width - parent.spacing * 2
              anchors.verticalCenter: parent.verticalCenter
              text: root.filterText || "Search clipboard…"
              color: root.filterText ? root.foreground : root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            Text {
              id: searchShortcut
              anchors.verticalCenter: parent.verticalCenter
              text: "Ctrl + P  pin"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          Row {
            anchors.fill: parent
            spacing: root.contentSpacing

            Rectangle {
              id: listSurface
              width: (parent.width - parent.spacing) * 0.52
              height: parent.height
              clip: true
              radius: root.cornerRadius
              color: root.panelSurface
              border.width: 1
              border.color: root.border

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.margins: Style.space(8)
                model: displayModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string entryType
                  required property string previewText
                  required property string fullText
                  required property string previewImage
                  required property bool pinned

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

                  width: ListView.view.width
                  height: entryType === "section" ? Style.space(34) : root.rowHeight
                  radius: root.cornerRadius
                  color: entryType === "section"
                    ? "transparent"
                    : (hasCursor ? root.selectedBackground : (pinned ? Util.alpha(root.accent, 0.12) : "transparent"))

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(10)

                    Rectangle {
                      visible: parent.parent.entryType === "section"
                      width: visible ? Style.space(3) : 0
                      height: Style.space(14)
                      radius: width / 2
                      anchors.verticalCenter: parent.verticalCenter
                      color: parent.parent.previewText.indexOf("Pinned") >= 0 ? root.accent : root.muted
                    }

                    Image {
                      visible: parent.parent.previewImage.length > 0
                      width: visible ? parent.height : 0
                      height: parent.height
                      source: parent.parent.previewImage
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                    }

                    Text {
                      visible: parent.parent.entryType !== "section" && parent.parent.previewImage.length === 0
                      width: visible ? Style.space(18) : 0
                      anchors.verticalCenter: parent.verticalCenter
                      text: parent.parent.entryType === "file" ? "↗" : "▤"
                      color: parent.parent.pinned ? root.accent : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                        - (parent.parent.entryType === "section" ? Style.space(3) + parent.spacing : 0)
                        - (parent.parent.previewImage.length > 0 ? parent.height + parent.spacing : 0)
                        - (parent.parent.entryType !== "section" && parent.parent.previewImage.length === 0 ? Style.space(18) + parent.spacing : 0)
                        - (pinMark.visible ? pinMark.width + parent.spacing : 0)
                      height: parent.height
                      text: parent.parent.previewText
                      color: parent.parent.entryType === "section"
                        ? (parent.parent.previewText.indexOf("Pinned") >= 0 ? root.accent : root.muted)
                        : (parent.parent.hasCursor ? root.selectedText : root.foreground)
                      font.family: root.fontFamily
                      font.pixelSize: parent.parent.entryType === "section" ? Style.font.caption : Style.font.title
                      font.weight: parent.parent.entryType === "section" ? Font.DemiBold : Font.Normal
                      font.capitalization: parent.parent.entryType === "section" ? Font.AllUppercase : Font.MixedCase
                      font.letterSpacing: parent.parent.entryType === "section" ? 1.6 : 0
                      opacity: parent.parent.entryType === "image" || parent.parent.entryType === "file" ? 0.72 : 1.0
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      verticalAlignment: Text.AlignVCenter
                    }

                    Text {
                      id: pinMark
                      visible: parent.parent.pinned
                      text: "📌"
                      color: root.accent
                      opacity: 1
                      font.pixelSize: Style.font.body
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: row.entryType !== "section"
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPositionChanged: function(mouse) {
                      root.selectFromPointer(row.index, row, mouse)
                    }
                    onClicked: function(mouse) {
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      if (mouse.button === Qt.RightButton) {
                        rowMenu.displayIndex = row.index
                        var point = row.mapToItem(card, mouse.x, mouse.y)
                        rowMenu.x = point.x
                        rowMenu.y = point.y
                        rowMenu.open()
                      } else {
                        root.activateIndex(row.index)
                      }
                    }
                  }
                }
              }
            }

            Rectangle {
              id: previewSurface
              width: parent.width - listSurface.width - parent.spacing
              height: parent.height
              clip: true
              radius: root.cornerRadius
              color: root.panelSurface
              border.width: 1
              border.color: root.border

              property var activeRow: displayModel.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null

              Text {
                visible: parent.activeRow && parent.activeRow.pinned
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.space(18)
                text: "📌"
                color: root.accent
                font.pixelSize: Style.font.heading
              }

              Text {
                textFormat: Text.PlainText
                visible: parent.activeRow && !parent.activeRow.previewImage
                anchors.fill: parent
                anchors.margins: Style.space(20)
                anchors.topMargin: Style.space(54)
                text: parent.activeRow ? parent.activeRow.fullText : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
              }

              Image {
                visible: parent.activeRow && parent.activeRow.previewImage
                anchors.fill: parent
                anchors.margins: Style.space(20)
                anchors.topMargin: Style.space(54)
                source: parent.activeRow ? parent.activeRow.previewImage : ""
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
              }

              Text {
                visible: !parent.activeRow || parent.activeRow.entryType === "section"
                anchors.centerIn: parent
                text: "Select an item to preview"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          Controls.Menu {
            id: rowMenu
            property int displayIndex: -1

            Controls.MenuItem {
              text: rowMenu.displayIndex >= 0 && displayModel.get(rowMenu.displayIndex).pinned ? "Unpin" : "Pin to top"
              onTriggered: root.togglePinIndex(rowMenu.displayIndex)
            }
            Controls.MenuItem {
              text: "Move up"
              enabled: rowMenu.displayIndex > 1 && displayModel.get(rowMenu.displayIndex).pinned
              onTriggered: root.movePinnedIndex(rowMenu.displayIndex, -1)
            }
            Controls.MenuItem {
              text: "Move down"
              enabled: rowMenu.displayIndex >= 1
                && rowMenu.displayIndex + 1 < displayModel.count
                && displayModel.get(rowMenu.displayIndex).pinned
                && displayModel.get(rowMenu.displayIndex + 1).pinned
              onTriggered: root.movePinnedIndex(rowMenu.displayIndex, 1)
            }
            Controls.MenuItem {
              text: "Delete"
              onTriggered: root.removeDisplayIndex(rowMenu.displayIndex)
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "󰅌"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.history.length === 0 ? "Clipboard is empty" : "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
