import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
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
  readonly property string iconPower: "\uf011"       // fa-power-off, U+F011

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
  property bool ledsOff: setting("off", false) === true
  property bool multiColour: setting("multi", false) === true
  // One {h, s} per LED. Brightness stays global, so the ring dims as a whole.
  property var ledColours: setting("leds", [])
  property int selectedLed: 0
  property bool offWhenAsleep: setting("offWhenAsleep", false) === true

  // The screen is asleep once the shell has locked and blanked it. The shell
  // does that on its own idle timer, so the plugin runs the same countdown
  // rather than touching anyone's configuration: the lock delay from the
  // shell's idle config, plus the few seconds the lock waits before blanking.
  // "Asleep" means the displays are actually off, which covers both the idle
  // timer running out and a lock asked for by hand. Quickshell has no DPMS
  // signal, so the monitor list is refreshed on a slow timer, which is an IPC
  // call inside the shell rather than another process.
  property bool idleAsleep: false
  readonly property bool asleep: idleAsleep

  function refreshDpms() {
    Hyprland.refreshMonitors()
    var monitors = Hyprland.monitors ? Hyprland.monitors.values : []
    if (!monitors || monitors.length === 0) return
    var anyOn = false
    for (var i = 0; i < monitors.length; i++) {
      var info = monitors[i] ? monitors[i].lastIpcObject : null
      if (!info || info.disabled) continue
      if (info.dpmsStatus !== false) anyOn = true
    }
    root.idleAsleep = !anyOn
  }

  // An achromatic accent reports hsvHue -1; white LEDs is the honest answer.
  readonly property color accent: Color.accent
  readonly property real shownHue: syncTheme ? Math.max(0, accent.hsvHue) : hue

  // A light theme has a pale accent, and a pale colour on an LED reads as
  // white rather than as the theme. Following the theme takes its hue and
  // lifts the saturation to something the fan can actually show.
  readonly property real minimumSaturation: 0.75
  readonly property real shownSaturation: syncTheme ? Math.max(minimumSaturation, accent.hsvSaturation) : saturation

  // What the marker on the wheel points at: the selected LED when there are
  // several, the one colour otherwise.
  readonly property real markerHue: multiColour && ledPalette.length ? ledPalette[Math.max(0, Math.min(ledCount - 1, selectedLed))].h : shownHue
  readonly property real markerSaturation: multiColour && ledPalette.length ? ledPalette[Math.max(0, Math.min(ledCount - 1, selectedLed))].s : shownSaturation

  // Off is a state of its own rather than zero brightness, so switching the
  // LEDs back on returns them to the brightness that was set before.
  readonly property bool lightsOut: ledsOff || (offWhenAsleep && asleep)
  readonly property real shownBrightness: lightsOut ? 0 : brightness
  readonly property color ledColor: Qt.hsva(shownHue, shownSaturation, shownBrightness, 1)

  readonly property int ledCount: 8

  // A theme gives one accent, not a palette. The ring starts on the accent
  // itself, drifts away around the fan and comes back to it, so the colour the
  // theme actually uses is visible on both sides rather than nowhere.
  readonly property real themeSpread: 0.22

  function ledPairs() {
    var out = []
    var i
    if (!root.multiColour) {
      for (i = 0; i < root.ledCount; i++) out.push({ h: root.shownHue, s: root.shownSaturation })
      return out
    }
    if (root.syncTheme) {
      for (i = 0; i < root.ledCount; i++) {
        // Triangle over the ring rather than a line across it: 0 at the first
        // LED, furthest away opposite it, back to the accent at the end.
        var u = i / root.ledCount
        var t = 1 - Math.abs(2 * u - 1)
        out.push({ h: wrapHue(root.shownHue + t * root.themeSpread), s: root.shownSaturation })
      }
      return out
    }
    var stored = Array.isArray(root.ledColours) ? root.ledColours : []
    for (i = 0; i < root.ledCount; i++) {
      var c = stored[i]
      if (c && isFinite(Number(c.h)) && isFinite(Number(c.s)))
        out.push({ h: wrapHue(Number(c.h)), s: clamp01(Number(c.s)) })
      else
        out.push({ h: wrapHue(root.hue + (i / root.ledCount) * root.themeSpread * 2), s: root.saturation })
    }
    return out
  }

  readonly property var ledPalette: ledPairs()

  function colourAt(i) {
    var c = root.ledPalette[i] || { h: root.shownHue, s: root.shownSaturation }
    return Qt.hsva(c.h, c.s, root.shownBrightness, 1)
  }

  // What goes to the helper: one colour when the ring is one colour, eight
  // when it is not, so an older setup that only allows a single colour keeps
  // working for the plain case.
  readonly property string ledHex: {
    if (!root.multiColour || !root.multiAllowed) return toHex(root.ledColor)
    var parts = []
    for (var i = 0; i < root.ledCount; i++) parts.push(toHex(root.colourAt(i)))
    return parts.join(",")
  }

  function wrapHue(h) { return ((h % 1) + 1) % 1 }

  property bool desktop: true
  property bool ready: false
  property bool multiAllowed: false
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
    var hue = wrapHue(h)
    var sat = clamp01(s)
    if (root.multiColour) {
      // In multi-colour mode the wheel edits the LED that is selected below it.
      var next = []
      var pairs = root.ledPalette
      for (var i = 0; i < root.ledCount; i++)
        next.push(i === root.selectedLed ? { h: hue, s: sat } : { h: pairs[i].h, s: pairs[i].s })
      root.syncTheme = false
      root.ledColours = next
    } else {
      root.syncTheme = false
      root.hue = hue
      root.saturation = sat
    }
    persistTimer.restart()
  }

  function toggleMulti() {
    if (!root.multiColour) {
      // Start from what is on the ring now, so switching over never goes dark.
      root.ledColours = root.ledPairs()
      root.selectedLed = 0
    }
    root.multiColour = !root.multiColour
    root.attemptedHex = ""
    persistTimer.restart()
  }

  function selectLed(i) {
    if (i < 0 || i >= root.ledCount) return
    root.selectedLed = i
  }

  function setBrightness(v) {
    root.brightness = clamp01(v)
    // Reaching for the slider means the lights should be on; all the way down
    // is the same as off, so the button follows the slider either way.
    root.ledsOff = root.brightness <= 0
    persistTimer.restart()
  }

  function toggleOff() {
    if (root.ledsOff && root.brightness <= 0) root.brightness = 1
    root.ledsOff = !root.ledsOff
    persistTimer.restart()
  }

  function toggleOffWhenAsleep() {
    root.offWhenAsleep = !root.offWhenAsleep
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
      root.multiAllowed = data !== null && data.multi === true
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
      syncTheme: root.syncTheme,
      multi: root.multiColour,
      leds: root.ledColours,
      off: root.ledsOff,
      offWhenAsleep: root.offWhenAsleep
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

  Timer {
    interval: 10000
    repeat: true
    triggeredOnStart: true
    running: root.ready && root.offWhenAsleep
    onTriggered: root.refreshDpms()
    onRunningChanged: if (!running) root.idleAsleep = false
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
        else if (event.key === Qt.Key_O) root.toggleOff()
        else if (event.key === Qt.Key_M) root.toggleMulti()
        else if (root.multiColour && event.key >= Qt.Key_1 && event.key <= Qt.Key_8) root.selectLed(event.key - Qt.Key_1)
        else if (event.key === Qt.Key_S) root.toggleOffWhenAsleep()
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

            // One marker per LED, so the wheel shows the whole ring rather than
            // only the colour being edited. With a single colour there is one.
            Repeater {
              model: root.multiColour ? root.ledCount : 1

              delegate: Rectangle {
                required property int index

                readonly property bool single: !root.multiColour
                readonly property bool picked: single || (!root.syncTheme && index === root.selectedLed)
                readonly property real markerH: single ? root.markerHue : root.ledPalette[index].h
                readonly property real markerS: single ? root.markerSaturation : root.ledPalette[index].s
                readonly property real angle: markerH * 2 * Math.PI
                readonly property real dist: markerS * (wheel.r - width / 2)

                width: picked ? Style.space(18) : Style.space(13)
                height: width
                radius: width / 2
                z: picked ? 2 : 1
                x: wheel.r + Math.cos(angle) * dist - width / 2
                y: wheel.r - Math.sin(angle) * dist - height / 2
                color: Qt.hsva(markerH, markerS, 1, 1)
                border.width: picked ? Math.max(2, Style.space(3)) : Math.max(1, Style.space(2))
                border.color: picked ? "white" : "#C0FFFFFF"

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: -1
                  radius: width / 2
                  color: "transparent"
                  border.width: 1
                  border.color: "#80000000"
                }
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

        // One dot per LED, to point the wheel at the one being edited. Left
        // out while the theme drives the ring: there is nothing to pick then,
        // and the markers on the wheel already show what the sweep does.
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.ready && root.multiColour && !root.syncTheme

          Repeater {
            model: root.ledCount

            delegate: Item {
              required property int index
              width: (parent.width - Style.space(6) * (root.ledCount - 1)) / root.ledCount
              height: Style.space(26)

              readonly property bool picked: index === root.selectedLed

              Rectangle {
                anchors.centerIn: parent
                width: Math.min(parent.width, Style.space(22))
                height: width
                radius: width / 2
                color: root.colourAt(index)
                opacity: root.lightsOut ? 0.35 : 1
                border.width: parent.picked ? Math.max(2, Style.space(2)) : 1
                border.color: parent.picked ? root.foreground : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectLed(index)
              }
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)
          visible: root.ready

          Button {
            id: powerButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.iconPower
            tooltipText: root.lightsOut ? "Turn the LEDs on" : "Turn the LEDs off"
            bordered: true
            active: !root.lightsOut
            foreground: root.lightsOut ? root.muted : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.toggleOff()
          }

          PanelSlider {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - powerButton.width - percent.width - parent.spacing * 2
            bar: root.bar
            value: root.shownBrightness
            onMoved: function(v) { root.setBrightness(v) }
          }

          Text {
            id: percent
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(36)
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: root.lightsOut ? "Off" : Math.round(root.brightness * 100) + "%"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Compact rows rather than the kit's boxed Toggle: two full-height
        // cards under the wheel take more room than the wheel itself.
        Column {
          width: parent.width
          visible: root.ready
          spacing: Style.space(4)

          Repeater {
            model: [
              { key: "sync", label: "Keep in sync with theme" },
              { key: "multi", label: "Multiple colours" },
              { key: "sleep", label: "Off when the screen sleeps" }
            ]

            delegate: Item {
              required property var modelData
              width: parent.width
              height: Math.max(sw.implicitHeight, rowLabel.implicitHeight)

              readonly property bool on: modelData.key === "sync" ? root.syncTheme
                : modelData.key === "multi" ? root.multiColour : root.offWhenAsleep

              Text {
                id: rowLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - sw.implicitWidth - Style.space(8)
                textFormat: Text.PlainText
                text: modelData.label
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              ToggleSwitch {
                id: sw
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: parent.on
                interactive: false
                trackHeight: Math.max(14, Math.round(Style.spacing.controlHeight * 0.34))
                cursorRing: false
                foreground: root.foreground
                accent: Color.accent
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: modelData.key === "sync" ? root.toggleSync()
                  : modelData.key === "multi" ? root.toggleMulti() : root.toggleOffWhenAsleep()
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.ready && root.multiColour && !root.multiAllowed

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "Several colours need the setup once more, because the helper only accepts one. Until then the ring stays one colour."
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            text: grantProc.running ? "Waiting for the terminal…" : "Run setup in a terminal"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: if (!grantProc.running) grantProc.running = true
          }
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

      }
    }
  }
}
