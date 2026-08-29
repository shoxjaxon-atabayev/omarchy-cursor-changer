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
  property bool isImporting: false
  property string importError: ""

  // Keyboard "cursor": which logical control (the grid, Cancel, or Apply)
  // reacts to Enter/Space right now. keyCatcher below is the *only* item
  // that ever holds real Qt keyboard focus — GridView and the two Buttons
  // are driven programmatically from here instead of taking real focus
  // themselves. This is deliberate, not a simplification: letting a child
  // (GridView, a Button) grab real activeFocus made it a focus *sibling* of
  // keyCatcher rather than a descendant, so unhandled keys (Escape, in
  // particular) had nowhere to bubble to and were silently dropped.
  property string focusZone: "grid" // "import" | "grid" | "cancel" | "apply"

  function cycleFocus(direction) {
    var zones = ["import", "grid", "cancel", "apply"]
    var idx = zones.indexOf(root.focusZone)
    if (idx < 0) idx = 0
    var applyEnabled = root.hasChange && !root.isApplying
    for (var i = 0; i < zones.length; i++) {
      idx = (idx + direction + zones.length) % zones.length
      if (zones[idx] === "apply" && !applyEnabled) continue
      if (zones[idx] === "import" && root.isImporting) continue
      root.focusZone = zones[idx]
      return
    }
  }

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
    root.importError = ""
    root.focusZone = "grid"
    refreshState()
    if (!root.themesLoaded) discoverProc.running = true
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
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

  function importTheme() {
    if (root.isImporting) return
    root.isImporting = true
    root.importError = ""
    importProc.command = [root.binPath("omarchy-cursor-changer-import-pick")]
    importProc.running = true
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
        if (root.pendingSelectId !== "") {
          root.selectTheme(root.pendingSelectId)
          root.pendingSelectId = ""
        }
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

  // Rescanned after a successful import so the new theme shows up without
  // waiting for the next full open(); pendingSelectId carries the freshly
  // imported theme's id across that async rescan so it lands pre-selected.
  property string pendingSelectId: ""

  Process {
    id: importProc
    property bool exited: false
    property bool stdoutFinished: false
    property bool stderrFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""
    property string stderrText: ""

    function checkFinished() {
      if (exited && stdoutFinished && stderrFinished) {
        root.isImporting = false
        // The overlay was hidden (not just backgrounded) so the file-picker
        // dialog could actually be seen and used; restore it and re-grab
        // keyboard focus now that the dialog is gone.
        root.focusZone = "import"
        Qt.callLater(function() { if (root.opened && !root.isImporting) keyCatcher.forceActiveFocus() })
        if (finalExitCode === 0) {
          var result = Model.parseJsonObject(stdoutText)
          if (result.imported) {
            root.pendingSelectId = result.name || ""
            root.themesLoaded = false
            discoverProc.running = true
          }
        } else if (stderrText.trim() !== "") {
          // A blank stderr on failure means the user simply closed the file
          // picker without choosing anything — not an error worth surfacing.
          root.importError = "Couldn't import cursor theme: " + stderrText.trim().split("\n").pop()
          console.warn("omarchy-cursor-changer: import failed:", stderrText)
        }
      }
    }

    onRunningChanged: if (running) {
      exited = false; stdoutFinished = false; stderrFinished = false; finalExitCode = -1
      stdoutText = ""; stderrText = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        importProc.stdoutText = text
        importProc.stdoutFinished = true
        importProc.checkFinished()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        importProc.stderrText = text
        importProc.stderrFinished = true
        importProc.checkFinished()
      }
    }
    onExited: function(exitCode) {
      importProc.finalExitCode = exitCode
      importProc.exited = true
      importProc.checkFinished()
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
    // Hidden (not just backgrounded) while a file-chooser dialog is up: this
    // surface sits on WlrLayer.Overlay with exclusive keyboard focus, which
    // is the topmost compositor layer — a normal application window (the
    // desktop portal's file picker, spawned by Import…) renders *below* it,
    // so leaving this visible made the picker completely unreachable behind
    // an opaque scrim the user couldn't see past or click through.
    visible: root.opened && !root.isImporting
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
            return
          }
          if (event.key === Qt.Key_Tab) {
            root.cycleFocus(event.modifiers & Qt.ShiftModifier ? -1 : 1)
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Backtab) {
            root.cycleFocus(-1)
            event.accepted = true
            return
          }

          if (root.focusZone === "import") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              root.importTheme()
              event.accepted = true
              return
            }
          } else if (root.focusZone === "grid") {
            if (event.key === Qt.Key_Left) { gridView.moveCurrentIndexLeft(); event.accepted = true; return }
            if (event.key === Qt.Key_Right) { gridView.moveCurrentIndexRight(); event.accepted = true; return }
            if (event.key === Qt.Key_Up) { gridView.moveCurrentIndexUp(); event.accepted = true; return }
            if (event.key === Qt.Key_Down) { gridView.moveCurrentIndexDown(); event.accepted = true; return }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              var idx = gridView.currentIndex
              if (idx >= 0 && idx < root.sortedThemes.length) root.selectTheme(root.sortedThemes[idx].id)
              event.accepted = true
              return
            }
          } else if (root.focusZone === "cancel") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              root.cancel()
              event.accepted = true
              return
            }
          } else if (root.focusZone === "apply") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
              root.applySelected()
              event.accepted = true
              return
            }
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

        Item {
          id: header
          width: parent.width
          height: headerLabels.height

          Column {
            id: headerLabels
            width: parent.width - importLink.width - Style.spacing.md
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

          // Secondary, deliberately understated action: importing a theme
          // the user already downloaded is not the primary flow (SPEC §9
          // keeps the header free of clutter), but it needs to be reachable
          // without waiting for the grid to be empty.
          Button {
            id: importLink
            anchors.right: parent.right
            anchors.verticalCenter: headerLabels.verticalCenter
            text: root.isImporting ? "Importing…" : "Import…"
            fontSize: Style.font.bodySmall
            hasCursor: root.focusZone === "import"
            enabled: !root.isImporting
            onClicked: { root.focusZone = "import"; root.importTheme() }
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
            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.isImporting ? "Importing…" : "Import a cursor theme…"
              bordered: true
              enabled: !root.isImporting
              onClicked: { root.focusZone = "import"; root.importTheme() }
            }
          }

          GridView {
            id: gridView
            visible: root.themes.length > 0
            anchors.fill: parent
            clip: true
            cellWidth: width / Model.columnsForWidth(width)
            cellHeight: Style.space(168)
            model: root.sortedThemes
            currentIndex: 0
            highlight: null

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
                highlighted: index === gridView.currentIndex && root.focusZone === "grid"
                onActivated: {
                  gridView.currentIndex = index
                  root.focusZone = "grid"
                  root.selectTheme(modelData.id)
                }
              }
            }
          }
        }

        Text {
          id: errorText
          readonly property string message: root.applyError !== "" ? root.applyError : root.importError
          visible: message !== ""
          width: parent.width
          text: message
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
            bordered: true
            hasCursor: root.focusZone === "cancel"
            onClicked: { root.focusZone = "cancel"; root.cancel() }
          }

          Button {
            text: root.isApplying ? "Applying…" : (root.applySuccess ? "Applied ✓" : "Apply")
            bordered: true
            hasCursor: root.focusZone === "apply"
            enabled: root.hasChange && !root.isApplying
            opacity: enabled ? 1.0 : 0.45
            onClicked: { root.focusZone = "apply"; root.applySelected() }
          }
        }
      }
    }
  }
}
