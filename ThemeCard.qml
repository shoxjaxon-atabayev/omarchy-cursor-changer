import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One cursor theme, rendered as a card: a real composited cursor preview,
// the theme's name, and an Active/Selected indicator. Clicking (or pressing
// Enter while highlighted) only updates local selection — see Main.qml's
// selectTheme(); nothing here ever touches the system cursor directly.
BorderSurface {
  id: root

  property string themeId: ""
  property string themeName: ""
  property string previewScript: ""
  property string themeDir: ""
  property bool active: false
  property bool selected: false
  property bool highlighted: false
  property bool invalid: false
  // Only ever true for user-installed themes (SPEC: never offer to remove a
  // system theme, which would need root and isn't this plugin's to touch).
  property bool deletable: false

  signal activated()
  signal deleteRequested()

  readonly property bool hot: mouseArea.containsMouse || root.highlighted
  readonly property color foreground: Color.menu.text

  radius: Style.cornerRadius
  color: mouseArea.pressed ? Style.pressedFillFor(foreground, Color.accent)
    : (root.active || root.selected) ? Style.selectedFillFor(foreground, Color.accent)
    : root.hot ? Style.hoverFillFor(foreground, Color.accent)
    : "transparent"
  borderSpec: (root.active || root.selected)
    ? Border.controlSpec("selected", foreground, Color.accent)
    : root.hot
      ? Border.controlSpec("hover-cursor", foreground, Color.accent)
      : Border.controlSpec("normal", foreground, Color.accent)
  padding: Style.spacing.lg

  Behavior on color { ColorAnimation { duration: 120 } }

  property string previewPath: ""
  property bool previewRequested: false
  property bool previewFailed: false

  function requestPreview() {
    if (root.previewRequested || root.invalid) return
    root.previewRequested = true
    previewProc.command = [root.previewScript, root.themeDir]
    previewProc.running = true
  }

  Process {
    id: previewProc
    property bool exited: false
    property bool stdoutFinished: false
    property int finalExitCode: -1
    property string stdoutText: ""

    function checkFinished() {
      if (exited && stdoutFinished) {
        if (finalExitCode === 0 && stdoutText.trim().length > 0) {
          root.previewPath = stdoutText.trim()
        } else {
          root.previewFailed = true
        }
      }
    }

    onRunningChanged: if (running) { exited = false; stdoutFinished = false; finalExitCode = -1; stdoutText = "" }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        previewProc.stdoutText = text
        previewProc.stdoutFinished = true
        previewProc.checkFinished()
      }
    }
    stderr: StdioCollector {}
    onExited: function(exitCode) {
      previewProc.finalExitCode = exitCode
      previewProc.exited = true
      previewProc.checkFinished()
    }
  }

  Component.onCompleted: requestPreview()

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  Column {
    anchors.fill: parent
    anchors.topMargin: root.contentTopInset
    anchors.rightMargin: root.contentRightInset
    anchors.bottomMargin: root.contentBottomInset
    anchors.leftMargin: root.contentLeftInset
    spacing: Style.spacing.md

    Item {
      id: previewArea
      width: parent.width
      height: Style.space(56)
      clip: true

      Image {
        anchors.centerIn: parent
        // The strip's native size varies with how many roles a theme
        // resolves and its own cursor bitmap sizes, so it is scaled down
        // to fit the card (never up — sourceSize caps it at its own real
        // pixel size) rather than assumed to already fit.
        width: Math.min(implicitWidth, previewArea.width)
        height: implicitWidth > 0 ? width * (implicitHeight / implicitWidth) : previewArea.height
        visible: root.previewPath !== ""
        source: root.previewPath !== "" ? "file://" + root.previewPath : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: true
      }

      // Decoration-only placeholder while the preview renders or if this
      // particular theme's preview could not be produced — never a fake
      // cursor glyph standing in for the real thing (SPEC §12), just a
      // neutral hint that content is pending/unavailable.
      Rectangle {
        anchors.centerIn: parent
        visible: root.previewPath === ""
        width: Style.space(40)
        height: Style.space(40)
        radius: Style.cornerRadius
        color: Util.alpha(root.foreground, 0.06)
      }
    }

    Text {
      width: parent.width
      text: root.themeName
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: root.active || root.selected
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
    }

    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: Style.spacing.xs
      visible: root.active || root.selected

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(7)
        height: Style.space(7)
        radius: width / 2
        // Active is a filled dot ("this is what's running"); selected-but-
        // not-active is a hollow ring ("this is what you're about to
        // apply") — same accent color, deliberately different weight so
        // the two meanings never look identical (SPEC §56).
        color: root.active ? Color.accent : "transparent"
        border.color: Color.accent
        border.width: root.active ? 0 : Math.max(1, Style.space(1))
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.active ? "Active" : "Selected"
        color: Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    // Always reserves this row's height (even when empty) so every card in
    // the grid stays the same size regardless of whether it happens to be
    // deletable — the empty space this used to leave unused on every card
    // is now spent here instead of just sitting blank.
    Item {
      width: parent.width
      height: Style.space(20)

      Text {
        anchors.centerIn: parent
        visible: root.deletable && !root.active
        text: "Delete"
        color: deleteMouseArea.containsMouse ? Color.urgent : Util.alpha(root.foreground, 0.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption

        MouseArea {
          id: deleteMouseArea
          anchors.fill: parent
          anchors.margins: -Style.spacing.sm
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.deleteRequested()
        }
      }
    }
  }
}
