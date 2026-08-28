import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "CursorChangerModel.js" as Model

// Cursor Changer overlay: discover -> preview -> select -> apply.
//
// Selecting a card only updates local state (selectedThemeId); the system
// cursor never changes until Apply runs (SPEC §6). Discovery only runs once
// per shell session (themesLoaded guards it) since a full rescan on every
// open would repeat filesystem work for no reason (SPEC §33/§61) — the
// active/selected state is still refreshed on every open, which is cheap.
Item {
  id: root

  property bool opened: false
  property bool themesLoaded: false
  property bool loading: false
  property var themes: []
  property string activeThemeId: ""
  property string selectedThemeId: ""
  property bool isApplying: false
  property string applyError: ""
  property bool applySuccess: false

  readonly property var sortedThemes: Model.sortThemes(root.themes, root.activeThemeId)
  readonly property bool hasChange: root.selectedThemeId !== "" && root.selectedThemeId !== root.activeThemeId

  // Third-party plugins are not installed into core bin/ and are not on
  // PATH, so the bundled CLI is addressed by a path resolved relative to
  // this file (same idiom used by the plugin's own bin-backed prior art).
  readonly property string binDir: Qt.resolvedUrl("bin/").toString().replace("file://", "")
  function binPath(name) { return root.binDir + name }

  function open() {
    root.opened = true
    root.applyError = ""
    root.applySuccess = false
    refreshState()
    if (!root.themesLoaded) discoverProc.running = true
    Qt.callLater(function() { if (root.opened) gridView.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    // Discard any unapplied local selection — reopening starts from
    // whatever is actually active, never a stale pending pick (SPEC §36).
    root.selectedThemeId = root.activeThemeId
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function refreshState() {
    stateProc.running = true
  }

  function selectTheme(id) {
    if (root.isApplying || !id) return
    root.selectedThemeId = id
    root.applyError = ""
  }

  function cancel() {
    root.close()
  }

  function applySelected() {
    if (root.isApplying || !root.hasChange) return
    root.isApplying = true
    root.applyError = ""
    applyProc.command = [root.binPath("omarchy-cursor-changer-apply"), root.selectedThemeId]
    applyProc.running = true
  }

  Process {
    id: discoverProc
    property bool exited: false
    property bool stdoutFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""

    command: [root.binPath("omarchy-cursor-changer-discover")]

    function checkFinished() {
      if (exited && stdoutFinished) {
        root.loading = false
        root.themes = finalExitCode === 0 ? Model.parseJsonArray(stdoutText) : []
        root.themesLoaded = true
      }
    }

    onRunningChanged: if (running) {
      root.loading = true
      exited = false; stdoutFinished = false; finalExitCode = -1; stdoutText = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        discoverProc.stdoutText = text
        discoverProc.stdoutFinished = true
        discoverProc.checkFinished()
      }
    }
    stderr: StdioCollector {}
    onExited: function(exitCode) {
      discoverProc.finalExitCode = exitCode
      discoverProc.exited = true
      discoverProc.checkFinished()
    }
  }

  Process {
    id: stateProc
    property bool exited: false
    property bool stdoutFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""

    command: [root.binPath("omarchy-cursor-changer-state")]

    function checkFinished() {
      if (exited && stdoutFinished) {
        var state = finalExitCode === 0 ? Model.parseJsonObject(stdoutText) : {}
        var wasUnset = root.selectedThemeId === ""
        root.activeThemeId = state.hasState ? (state.theme || "") : ""
        if (wasUnset || root.selectedThemeId === "") root.selectedThemeId = root.activeThemeId
      }
    }

    onRunningChanged: if (running) {
      exited = false; stdoutFinished = false; finalExitCode = -1; stdoutText = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        stateProc.stdoutText = text
        stateProc.stdoutFinished = true
        stateProc.checkFinished()
      }
    }
    stderr: StdioCollector {}
    onExited: function(exitCode) {
      stateProc.finalExitCode = exitCode
      stateProc.exited = true
      stateProc.checkFinished()
    }
  }

  Process {
    id: applyProc
    property bool exited: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stderrText: ""

    function checkFinished() {
      if (exited && stderrFinished) {
        root.isApplying = false
        if (finalExitCode === 0) {
          root.activeThemeId = root.selectedThemeId
          root.applySuccess = true
          successTimer.restart()
        } else {
          root.applyError = "Couldn't apply cursor theme. Your current cursor theme was kept unchanged."
          console.warn("omarchy-cursor-changer: apply failed:", stderrText)
        }
      }
    }

    onRunningChanged: if (running) {
      exited = false; stderrFinished = false; finalExitCode = -1; stderrText = ""
    }
    stdout: StdioCollector {}
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        applyProc.stderrText = text
        applyProc.stderrFinished = true
        applyProc.checkFinished()
      }
    }
    onExited: function(exitCode) {
      applyProc.finalExitCode = exitCode
      applyProc.exited = true
      applyProc.checkFinished()
    }
  }

  Timer {
    id: successTimer
    interval: 1600
    onTriggered: root.applySuccess = false
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-cursor-changer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(920), panel.width - Style.gapsOut * 4)
      height: Math.min(Style.space(640), panel.height - Style.gapsOut * 4)
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      // Swallow clicks so they don't bubble to the scrim's close-on-click.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancel()
            event.accepted = true
          }
        }
      }

      Column {
        id: layout
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.lg

        Column {
          id: header
          width: parent.width
          spacing: Style.spacing.xxs

          Text {
            text: "Cursor"
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
          }
          Text {
            text: "Choose a cursor style for your desktop"
            color: Color.menu.text
            opacity: 0.65
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Item {
          id: content
          width: parent.width
          height: parent.height - header.height - footer.height - layout.spacing * 2
            - (errorText.visible ? errorText.height + layout.spacing : 0)

          Text {
            visible: root.loading && root.themes.length === 0
            anchors.centerIn: parent
            text: "Loading cursor themes…"
            color: Color.menu.text
            opacity: 0.6
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Column {
            visible: !root.loading && root.themesLoaded && root.themes.length === 0
            anchors.centerIn: parent
            spacing: Style.spacing.sm

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "No cursor themes found"
              color: Color.menu.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Install a cursor theme and try again."
              color: Color.menu.text
              opacity: 0.65
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          GridView {
            id: gridView
            visible: root.themes.length > 0
            anchors.fill: parent
            clip: true
            focus: true
            cellWidth: width / Model.columnsForWidth(width)
            cellHeight: Style.space(168)
            model: root.sortedThemes
            currentIndex: 0
            highlight: null

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                if (currentIndex >= 0 && currentIndex < root.sortedThemes.length)
                  root.selectTheme(root.sortedThemes[currentIndex].id)
                event.accepted = true
              }
            }

            delegate: Item {
              width: gridView.cellWidth
              height: gridView.cellHeight

              ThemeCard {
                anchors.fill: parent
                anchors.margins: Style.spacing.sm
                themeId: modelData.id
                themeName: modelData.name
                previewScript: root.binPath("omarchy-cursor-changer-preview")
                themeDir: modelData.dir
                active: modelData.id === root.activeThemeId
                selected: modelData.id === root.selectedThemeId
                highlighted: index === gridView.currentIndex
                onActivated: {
                  gridView.currentIndex = index
                  root.selectTheme(modelData.id)
                }
              }
            }
          }
        }

        Text {
          id: errorText
          visible: root.applyError !== ""
          width: parent.width
          text: root.applyError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Row {
          id: footer
          anchors.right: parent.right
          spacing: Style.spacing.md

          Button {
            text: "Cancel"
            focusable: true
            bordered: true
            onClicked: root.cancel()
          }

          Button {
            text: root.isApplying ? "Applying…" : (root.applySuccess ? "Applied ✓" : "Apply")
            focusable: true
            bordered: true
            enabled: root.hasChange && !root.isApplying
            opacity: enabled ? 1.0 : 0.45
            onClicked: root.applySelected()
          }
        }
      }
    }
  }
}
