import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Framework Desktop RGB: a colour wheel for the eight LEDs on the fan.
//
// The wheel picks hue (angle) and saturation (distance from the centre), the
// slider below it the brightness. With "Keep in sync with theme" on,
// hue and saturation come from the theme accent instead and follow every
// theme switch; the brightness stays yours either way.
//
// Writing to the EC needs root, so every colour goes through
// bin/framework-desktop-rgb to a root helper that accepts nothing but RRGGBB.
// Until that helper is set up the panel offers to do it in a terminal.
//
// KeyboardPanel rather than PopupCard so the arrow keys can drive the wheel.
Panel {
  id: root
  moduleName: "jankeesvw.framework-desktop-rgb"
  ipcTarget: "jankeesvw.framework-desktop-rgb"

  readonly property string script: Qt.resolvedUrl("bin/framework-desktop-rgb").toString().replace(/^file:\/\//, "")
  readonly property string iconFan: "\uDB80\uDE10"   // nf-md-fan, U+F0210

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function fade(c, amount) {
    var bg = Color.background
    return Qt.rgba(c.r + (bg.r - c.r) * amount,
                   c.g + (bg.g - c.g) * amount,
                   c.b + (bg.b - c.b) * amount, 1)
  }
  readonly property color muted: fade(foreground, 0.45)

  // Bindings until the first interaction, so values arriving from shell.json
  // after construction still land.
  property real hue: clamp01(Number(setting("hue", 0.58)))
  property real saturation: clamp01(Number(setting("saturation", 1)))
  property real brightness: clamp01(Number(setting("brightness", 1)))
  property bool syncTheme: setting("syncTheme", false) === true

  // An achromatic accent reports hsvHue -1; white LEDs is the honest answer.
  readonly property color accent: Color.accent
  readonly property real shownHue: syncTheme ? Math.max(0, accent.hsvHue) : hue
  readonly property real shownSaturation: syncTheme ? accent.hsvSaturation : saturation
  readonly property color ledColor: Qt.hsva(shownHue, shownSaturation, brightness, 1)
  readonly property string ledHex: toHex(ledColor)

  property bool desktop: true
  property bool ready: false
  property bool statusKnown: false
  property string lastError: ""

  // The colour last handed to the helper. Compared against ledHex so a
  // failing write is not retried in a loop, only when the colour changes.
  property string attemptedHex: ""

  function clamp01(v) { return isFinite(v) ? Math.max(0, Math.min(1, v)) : 0 }

  function toHex(c) {
    function part(v) {
      var s = Math.round(clamp01(v) * 255).toString(16)
      return s.length < 2 ? "0" + s : s
    }
    return (part(c.r) + part(c.g) + part(c.b)).toUpperCase()
  }

  onLedHexChanged: applyTimer.restart()

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function pushColor() {
    if (!root.ready || setProc.running) return
    if (root.ledHex === root.attemptedHex) return
    var hex = root.ledHex
    root.attemptedHex = hex
    setProc.command = [root.script, "set", hex]
    setProc.running = true
  }

  // Every user change goes through here: it ends a theme sync the moment the
  // wheel is touched, and schedules one write to shell.json per burst.
  function pick(h, s) {
    root.syncTheme = false
    root.hue = (h % 1 + 1) % 1
    root.saturation = clamp01(s)
    persistTimer.restart()
  }

  function setBrightness(v) {
    root.brightness = clamp01(v)
    persistTimer.restart()
  }

  function toggleSync() {
    if (root.syncTheme) {
      // Leave the wheel where the theme had it rather than jumping back.
      root.hue = root.shownHue
      root.saturation = root.shownSaturation
    }
    root.syncTheme = !root.syncTheme
    persistTimer.restart()
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  onOpenedChanged: if (opened) refreshStatus()

  Component.onCompleted: refreshStatus()

  implicitWidth: button.implicitWidth
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  // Both helpers answer with one short JSON line. Output is read in raw
  // chunks with a byte budget, so a misbehaving helper cannot make the shell
  // buffer without bound; anything over the budget is dropped as a failure.
  readonly property int maxReplyBytes: 1024
  readonly property var helperEnvironment: ({ HOME: Quickshell.env("HOME"), PATH: "/usr/bin:/bin" })

  function parseReply(text) {
    if (text.length > root.maxReplyBytes) return null
    try {
      var data = JSON.parse(text)
      return (data && typeof data === "object") ? data : null
    } catch (e) {
      return null
    }
  }

  Process {
    id: statusProc
    property string buf: ""
    command: [root.script, "status"]
    clearEnvironment: true
    environment: root.helperEnvironment
    onStarted: buf = ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (statusProc.buf.length <= root.maxReplyBytes) statusProc.buf += chunk
      }
    }
    onExited: {
      var data = root.parseReply(buf)
      root.desktop = data !== null && data.desktop === true
      var wasReady = root.ready
      root.ready = data !== null && data.ready === true
      // The EC forgets the colour on a cold boot, so the first time the
      // helper is usable the current colour goes out even if unchanged.
      if (root.ready && !wasReady) {
        root.attemptedHex = ""
        applyTimer.restart()
      }
      root.statusKnown = true
    }
  }

  Process {
    id: setProc
    property string buf: ""
    clearEnvironment: true
    environment: root.helperEnvironment
    onStarted: buf = ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (setProc.buf.length <= root.maxReplyBytes) setProc.buf += chunk
      }
    }
    // A drag produces colours faster than framework_tool writes them; the
    // one that arrived meanwhile goes out as soon as this write is done.
    onExited: {
      var data = root.parseReply(buf)
      root.lastError = data !== null && data.ok === true ? ""
        : String((data && data.error) || "Could not set the colour").slice(0, 300)
      applyTimer.restart()
    }
  }

  Process {
    id: grantProc
    command: ["/usr/bin/xdg-terminal-exec", root.script, "grant"]
    onExited: root.refreshStatus()
  }

  Timer {
    id: applyTimer
    interval: 40
    onTriggered: root.pushColor()
  }

  Timer {
    id: persistTimer
    interval: 700
    onTriggered: root.persistSettings({
      hue: root.hue,
      saturation: root.saturation,
      brightness: root.brightness,
      syncTheme: root.syncTheme
    })
  }

  // The setup happens in a terminal the panel cannot watch closely, so poll
  // while it is waiting for it.
  Timer {
    interval: 2000
    repeat: true
    running: root.opened && !root.ready
    onTriggered: root.refreshStatus()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconFan
    tooltipText: "Framework Desktop RGB"
    opacity: root.ready ? 1 : 0.45
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher

    readonly property int desiredWidth: Style.space(280)
    contentWidth: Math.min(desiredWidth, panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var step = (event.modifiers & Qt.ShiftModifier) ? 0.1 : 0.02
        var enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        if (event.key === Qt.Key_Escape) root.close()
        else if (!root.ready) {
          if (!(enter && root.desktop)) return
          if (!grantProc.running) grantProc.running = true
        }
        else if (event.key === Qt.Key_Left) root.pick(root.shownHue + step, root.shownSaturation)
        else if (event.key === Qt.Key_Right) root.pick(root.shownHue - step, root.shownSaturation)
        else if (event.key === Qt.Key_Up) root.pick(root.shownHue, root.shownSaturation + step)
        else if (event.key === Qt.Key_Down) root.pick(root.shownHue, root.shownSaturation - step)
        else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) root.setBrightness(root.brightness + step * 2.5)
        else if (event.key === Qt.Key_Minus) root.setBrightness(root.brightness - step * 2.5)
        else if (event.key === Qt.Key_Space || enter) root.toggleSync()
        else return
        event.accepted = true
      }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // Setup, shown instead of the controls until the helper is allowed.
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.statusKnown && !root.ready

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: root.desktop
              ? "Setting the fan LEDs needs root. A one-time setup installs a small helper that can only change their colour, and allows it through sudo."
              : "No Framework Desktop found. This plugin only drives the fan LEDs of the Framework Desktop."
          }

          Button {
            visible: root.desktop
            text: grantProc.running ? "Waiting for the terminal…" : "Run setup in a terminal (Enter)"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: if (!grantProc.running) grantProc.running = true
          }
        }

        Item {
          width: parent.width
          height: wheel.height
          visible: root.ready

          Item {
            id: wheel
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(parent.width, Style.space(220))
            height: width
            opacity: root.syncTheme ? 0.55 : 1

            readonly property real r: width / 2

            // Hue runs counter-clockwise from red on the right, saturation
            // outwards from white. The canvas is drawn from the same maths the
            // marker and the mouse use, so the three cannot disagree.
            Canvas {
              id: canvas
              anchors.fill: parent
              onWidthChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                var r = width / 2
                ctx.reset()
                var steps = 360
                for (var i = 0; i < steps; i++) {
                  var a0 = i / steps * 2 * Math.PI
                  var a1 = (i + 1.5) / steps * 2 * Math.PI
                  ctx.beginPath()
                  ctx.moveTo(r, r)
                  ctx.arc(r, r, r, -a1, -a0, false)
                  ctx.closePath()
                  ctx.fillStyle = Qt.hsva(i / steps, 1, 1, 1)
                  ctx.fill()
                }
                var white = ctx.createRadialGradient(r, r, 0, r, r, r)
                white.addColorStop(0, "rgba(255,255,255,1)")
                white.addColorStop(1, "rgba(255,255,255,0)")
                ctx.beginPath()
                ctx.arc(r, r, r, 0, 2 * Math.PI, false)
                ctx.fillStyle = white
                ctx.fill()
              }
            }

            Rectangle {
              readonly property real angle: root.shownHue * 2 * Math.PI
              readonly property real dist: root.shownSaturation * (wheel.r - width / 2)
              width: Style.space(18)
              height: width
              radius: width / 2
              x: wheel.r + Math.cos(angle) * dist - width / 2
              y: wheel.r - Math.sin(angle) * dist - height / 2
              color: Qt.hsva(root.shownHue, root.shownSaturation, 1, 1)
              border.width: Math.max(2, Style.space(3))
              border.color: "white"

              Rectangle {
                anchors.fill: parent
                anchors.margins: -1
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: "#80000000"
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.CrossCursor

              function pickAt(x, y) {
                var dx = x - wheel.r
                var dy = wheel.r - y
                root.pick(Math.atan2(dy, dx) / (2 * Math.PI), Math.hypot(dx, dy) / wheel.r)
              }

              onPressed: function(mouse) {
                if (Math.hypot(mouse.x - wheel.r, mouse.y - wheel.r) > wheel.r) {
                  mouse.accepted = false
                  return
                }
                pickAt(mouse.x, mouse.y)
              }
              onPositionChanged: function(mouse) { if (pressed) pickAt(mouse.x, mouse.y) }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)
          visible: root.ready

          Text {
            id: brightnessLabel
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Brightness"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - brightnessLabel.width - percent.width - parent.spacing * 2
            bar: root.bar
            value: root.brightness
            onMoved: function(v) { root.setBrightness(v) }
          }

          Text {
            id: percent
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(36)
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: Math.round(root.brightness * 100) + "%"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Toggle {
          width: parent.width
          visible: root.ready
          label: "Keep in sync with theme"
          checked: root.syncTheme
          activeFocusOnTab: false
          foreground: root.foreground
          fontFamily: root.fontFamily
          titleSize: Style.font.body
          onClicked: root.toggleSync()
        }

        Text {
          width: parent.width
          visible: root.ready && root.lastError !== ""
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: root.lastError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.ready
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          text: "Arrows move the colour, + and − the brightness, space syncs with the theme"
          color: root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
