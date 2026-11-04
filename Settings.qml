pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

// Screen layout editor, summoned from the bar widget, the Omarchy menu or
// `live-wallpaper.sh --settings`. It draws the monitors as Hyprland arranges
// them; pick one or more, then pick a video or image to show on each of them
// or to stretch across all of them.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  property string omarchyPath: ""

  readonly property string pluginId: "lucentdread.live-wallpaper"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string script: home + "/.config/omarchy/plugins/lucentdread.live-wallpaper/live-wallpaper.sh"
  readonly property var svc: service
    || (shell && typeof shell.serviceFor === "function" ? shell.serviceFor(pluginId) : null)
  readonly property int revision: svc ? svc.layoutRevision + svc.screenRevision * 100000 : 0

  property bool opened: false
  property var targetScreen: null
  property var selected: []
  property bool spanMode: false
  property var media: []
  property bool mediaLoading: false
  property string filter: "all"

  // Theme palette, read from the active theme so the editor matches the shell.
  property color background: "#1e1e2e"
  property color surface: "#313244"
  property color foreground: "#cdd6f4"
  property color muted: "#6c7086"
  property color accent: "#89b4fa"
  readonly property string fontFamily: "monospace"

  function open(payloadJson) {
    targetScreen = focusedScreen()
    selected = selected.filter(function(n) { return !!root.screenByName(n) })
    if (selected.length === 0 && targetScreen) selected = [targetScreen.name]
    syncSpanMode()
    opened = true
    refreshMedia()
  }

  function close() {
    opened = false
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function" && shell.hide((manifest && manifest.id) || pluginId)) return
    close()
  }

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
  }

  function loadColors(text) {
    var lines = String(text || "").split("\n")
    var map = {}
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6,8})"/)
      if (m) map[m[1]] = m[2]
    }
    if (map.background) background = map.background
    if (map.lighter_background || map.selection) surface = map.lighter_background || map.selection
    if (map.foreground) foreground = map.foreground
    if (map.dark_foreground || map.muted) muted = map.dark_foreground || map.muted
    if (map.accent) accent = map.accent
  }

  function refreshMedia() {
    if (listProc.running) return
    mediaLoading = true
    listProc.running = true
  }

  function parseMedia(text) {
    var out = []
    var seen = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length && out.length < 500; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 2 || parts[0] === "" || seen[parts[0]]) continue
      seen[parts[0]] = true
      var path = parts[0]
      var segments = path.split("/")
      out.push({
        path: path,
        thumb: parts[1],
        name: segments[segments.length - 1],
        folder: segments.length > 1 ? segments[segments.length - 2] : "",
        video: svc ? svc.isVideoPath(path) : /\.(mp4|mkv|webm|mov|m4v)$/i.test(path)
      })
    }
    out.sort(function(a, b) {
      if (a.video !== b.video) return a.video ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    media = out
    mediaLoading = false
  }

  function thumbFor(path) {
    for (var i = 0; i < media.length; i++) if (media[i].path === path) return media[i].thumb
    return ""
  }

  function tint(c, a) {
    return Qt.rgba(c.r, c.g, c.b, a)
  }

  function fileUrl(path) {
    if (!path) return ""
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
  }

  function assignmentOf(name) {
    return svc ? svc.assignmentFor(name, svc.layoutRevision, svc.screenRevision)
      : { mode: "picker", path: "", fit: "crop", span: "", box: null }
  }

  function displayPath(assignment) {
    if (assignment.mode === "picker") return svc ? svc.videoPath : ""
    if (assignment.mode === "none") return ""
    return assignment.path || ""
  }

  function isSelected(name) {
    return selected.indexOf(name) !== -1
  }

  function clickScreen(name, modifiers) {
    var next = selected.slice()
    if (modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) {
      var at = next.indexOf(name)
      if (at === -1) next.push(name)
      else if (next.length > 1) next.splice(at, 1)
    } else {
      // A plain click on a spanned screen selects its whole span.
      var a = assignmentOf(name)
      next = a.mode === "span" && a.screens ? a.screens.filter(function(n) {
        return !!screenByName(n)
      }) : [name]
    }
    selected = orderedSelection(next)
    syncSpanMode()
  }

  function selectAll() {
    var all = []
    for (var i = 0; i < Quickshell.screens.length; i++) all.push(Quickshell.screens[i].name)
    selected = orderedSelection(all)
    syncSpanMode()
  }

  // Left-to-right, then top-to-bottom, so the span leader is predictable.
  function orderedSelection(names) {
    return names.slice().sort(function(a, b) {
      var sa = screenByName(a), sb = screenByName(b)
      if (!sa || !sb) return 0
      return sa.x !== sb.x ? sa.x - sb.x : sa.y - sb.y
    })
  }

  function screenByName(name) {
    for (var i = 0; i < Quickshell.screens.length; i++)
      if (Quickshell.screens[i].name === name) return Quickshell.screens[i]
    return null
  }

  function syncSpanMode() {
    if (selected.length < 2) {
      spanMode = false
      return
    }
    var first = assignmentOf(selected[0])
    spanMode = first.mode === "span" && selected.every(function(n) {
      var a = assignmentOf(n)
      return a.mode === "span" && a.span === first.span
    })
  }

  function currentFit() {
    return selected.length > 0 ? assignmentOf(selected[0]).fit || "crop" : "crop"
  }

  function applyMedia(path) {
    if (!svc || selected.length === 0) return
    if (spanMode && selected.length >= 2) svc.spanScreens(selected, path, currentFit())
    else svc.setScreens(selected, "media", path, currentFit())
  }

  function applyMode(mode) {
    if (!svc || selected.length === 0) return
    svc.setScreens(selected, mode, "", currentFit())
    spanMode = false
  }

  function toggleSpan() {
    if (selected.length < 2 || !svc) return
    spanMode = !spanMode
    // Turning span on with a picture already chosen lays it across at once;
    // turning it off gives every selected screen its own copy of it.
    var path = displayPath(assignmentOf(selected[0]))
    if (path === "" || !svc.isValidMediaPath(path)) return
    if (spanMode) svc.spanScreens(selected, path, currentFit())
    else svc.setScreens(selected, "media", path, currentFit())
  }

  function modeLabel(a) {
    if (a.mode === "picker") return "Background picker"
    if (a.mode === "none") return "Static wallpaper"
    if (a.mode === "span") return "Spanned × " + (a.screens ? a.screens.length : 2)
    return svc && svc.isVideoPath(a.path) ? "Own video" : "Own image"
  }

  onRevisionChanged: if (opened) syncSpanMode()

  FileView {
    path: root.stateHome + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadColors(text())
    onFileChanged: reload()
  }

  Process {
    id: listProc
    command: ["timeout", "90", root.script, "--list-media"]
    stdout: StdioCollector {
      onStreamFinished: root.parseMedia(text)
    }
    onExited: root.mediaLoading = false
  }

  PanelWindow {
    id: window
    visible: root.opened && !!root.targetScreen
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: Qt.rgba(0, 0, 0, 0.45)

    WlrLayershell.namespace: "lucentdread-live-wallpaper-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.dismiss()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
          root.selectAll()
          event.accepted = true
        }
      }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: Math.min(1040, parent.width - 64)
      height: Math.min(780, parent.height - 64)
      radius: 12
      color: root.background
      border.color: root.tint(root.foreground, 0.12)
      border.width: 1

      // Swallow clicks so only the scrim dismisses.
      MouseArea { anchors.fill: parent; onClicked: keys.forceActiveFocus() }

      Column {
        id: content
        anchors.fill: parent
        anchors.margins: 24
        spacing: 16

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: 36

          Column {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
              text: "Live Wallpaper"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 18
              font.bold: true
            }
            Text {
              text: "Click a screen to select it, Shift-click to add more. Ctrl+A selects all."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: 12
            }
          }

          Chip {
            id: closeChip
            theme: root
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            label: "✕"
            onClicked: root.dismiss()
          }

          // Global: paused players keep their last frame while a fullscreen
          // app covers their screen.
          Chip {
            theme: root
            anchors.right: closeChip.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            readonly property bool pauseOn: {
              var dummy = root.revision
              return !root.svc || !root.svc.layout.options || root.svc.layout.options.pauseOnFullscreen !== false
            }
            label: pauseOn ? "Pause behind fullscreen: on" : "Pause behind fullscreen: off"
            active: pauseOn
            onClicked: if (root.svc) root.svc.setPauseOnFullscreen(!pauseOn)
          }
        }

        // ------------------------------------------------------ screen layout
        Rectangle {
          id: layoutArea
          width: parent.width
          height: 230
          radius: 10
          color: root.tint(root.surface, 0.5)

          readonly property var bounds: {
            var dummy = root.revision
            var screens = Quickshell.screens
            var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
            for (var i = 0; i < screens.length; i++) {
              minX = Math.min(minX, screens[i].x)
              minY = Math.min(minY, screens[i].y)
              maxX = Math.max(maxX, screens[i].x + screens[i].width)
              maxY = Math.max(maxY, screens[i].y + screens[i].height)
            }
            if (!isFinite(minX)) return { x: 0, y: 0, width: 1, height: 1 }
            return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
          }
          readonly property real ratio: Math.min((width - 32) / bounds.width, (height - 32) / bounds.height)
          readonly property real offsetX: (width - bounds.width * ratio) / 2
          readonly property real offsetY: (height - bounds.height * ratio) / 2

          Repeater {
            model: Quickshell.screens

            Rectangle {
              id: screenTile
              required property var modelData
              readonly property string name: String(modelData.name || "")
              readonly property var assignment: {
                var dummy = root.revision
                return root.assignmentOf(name)
              }
              readonly property string path: root.displayPath(assignment)
              readonly property bool chosen: {
                var dummy = root.selected
                return root.isSelected(name)
              }

              x: layoutArea.offsetX + (modelData.x - layoutArea.bounds.x) * layoutArea.ratio + 3
              y: layoutArea.offsetY + (modelData.y - layoutArea.bounds.y) * layoutArea.ratio + 3
              width: modelData.width * layoutArea.ratio - 6
              height: modelData.height * layoutArea.ratio - 6
              radius: 6
              color: root.background
              clip: true
              border.width: chosen ? 3 : 1
              border.color: chosen ? root.accent : root.tint(root.foreground, 0.25)

              // The preview mirrors the real thing: a span shows each screen
              // its own slice of one picture.
              Item {
                anchors.fill: parent
                anchors.margins: screenTile.border.width
                clip: true

                Image {
                  readonly property var box: screenTile.assignment.mode === "span" ? screenTile.assignment.box : null
                  x: box ? (box.x - screenTile.modelData.x) * layoutArea.ratio : 0
                  y: box ? (box.y - screenTile.modelData.y) * layoutArea.ratio : 0
                  width: box ? box.width * layoutArea.ratio : parent.width
                  height: box ? box.height * layoutArea.ratio : parent.height
                  source: root.fileUrl(root.thumbFor(screenTile.path))
                  asynchronous: true
                  fillMode: screenTile.assignment.fit === "fit" ? Image.PreserveAspectFit
                    : screenTile.assignment.fit === "stretch" ? Image.Stretch : Image.PreserveAspectCrop
                  opacity: screenTile.assignment.mode === "none" ? 0 : 0.85
                }
              }

              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: screenTile.border.width
                height: tileLabel.implicitHeight + 10
                color: root.tint(root.background, 0.82)

                Column {
                  id: tileLabel
                  anchors.centerIn: parent
                  width: parent.width - 8
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: screenTile.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: 12
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    text: root.modeLabel(screenTile.assignment)
                    color: screenTile.assignment.mode === "span" ? root.accent : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: 11
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: function(mouse) { root.clickScreen(screenTile.name, mouse.modifiers) }
              }
            }
          }
        }

        // ---------------------------------------------------------- controls
        Flow {
          width: parent.width
          spacing: 8

          Chip {
            theme: root
            label: "Follow picker"
            active: root.selected.length > 0 && root.selected.every(function(n) {
              var dummy = root.revision
              return root.assignmentOf(n).mode === "picker"
            })
            onClicked: root.applyMode("picker")
          }
          Chip {
            theme: root
            label: "Static wallpaper"
            active: root.selected.length > 0 && root.selected.every(function(n) {
              var dummy = root.revision
              return root.assignmentOf(n).mode === "none"
            })
            onClicked: root.applyMode("none")
          }
          Chip {
            theme: root
            label: root.spanMode ? "Span: on" : "Span: off"
            active: root.spanMode
            enabled: root.selected.length >= 2
            onClicked: root.toggleSpan()
          }

          Item { width: 16; height: 1 }

          Repeater {
            model: [{ key: "crop", label: "Fill" }, { key: "fit", label: "Fit" }, { key: "stretch", label: "Stretch" }]
            Chip {
              theme: root
              required property var modelData
              label: modelData.label
              active: {
                var dummy = root.revision + root.selected.length
                return root.currentFit() === modelData.key
              }
              enabled: root.selected.length > 0
              onClicked: if (root.svc) root.svc.setFit(root.selected, modelData.key)
            }
          }

          Item { width: 16; height: 1 }

          Chip {
            theme: root
            label: "Select all"
            onClicked: root.selectAll()
          }
          Chip {
            theme: root
            label: "Reset all"
            onClicked: if (root.svc) root.svc.resetLayout()
          }
        }

        // ------------------------------------------------------------- media
        Item {
          width: parent.width
          height: 24
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.selected.length === 0 ? "Select a screen first"
              : (root.spanMode ? "Pick what to stretch across " : "Pick what to show on ")
                + root.selected.join(", ")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: 13
          }
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Repeater {
              model: [{ key: "all", label: "All" }, { key: "video", label: "Videos" }, { key: "image", label: "Images" }]
              Chip {
                theme: root
                required property var modelData
                label: modelData.label
                small: true
                active: root.filter === modelData.key
                onClicked: root.filter = modelData.key
              }
            }
            Chip {
              theme: root
              label: root.mediaLoading ? "Loading…" : "Refresh"
              small: true
              onClicked: root.refreshMedia()
            }
          }
        }

        Rectangle {
          width: parent.width
          height: parent.height - y
          radius: 10
          color: root.tint(root.surface, 0.35)
          clip: true

          GridView {
            id: grid
            anchors.fill: parent
            anchors.margins: 10
            cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 190)))
            cellHeight: 132
            boundsBehavior: Flickable.StopAtBounds
            model: root.media.filter(function(m) {
              return root.filter === "all" || (root.filter === "video") === m.video
            })

            delegate: Item {
              id: tile
              required property var modelData
              width: grid.cellWidth
              height: grid.cellHeight
              readonly property bool current: {
                var dummy = root.revision
                return root.selected.length > 0 && root.selected.every(function(n) {
                  return root.displayPath(root.assignmentOf(n)) === tile.modelData.path
                    && root.assignmentOf(n).mode !== "picker"
                })
              }

              Rectangle {
                anchors.fill: parent
                anchors.margins: 5
                radius: 8
                color: root.background
                border.width: tile.current ? 3 : (hover.containsMouse ? 2 : 1)
                border.color: tile.current || hover.containsMouse ? root.accent : root.tint(root.foreground, 0.15)
                clip: true

                Image {
                  anchors.fill: parent
                  anchors.margins: parent.border.width
                  anchors.bottomMargin: 22
                  source: root.fileUrl(tile.modelData.thumb)
                  sourceSize.width: 360
                  asynchronous: true
                  fillMode: Image.PreserveAspectCrop
                }

                Rectangle {
                  visible: tile.modelData.video
                  anchors.top: parent.top
                  anchors.right: parent.right
                  anchors.margins: 8
                  width: 22
                  height: 22
                  radius: 11
                  color: root.tint(root.background, 0.8)
                  Text {
                    anchors.centerIn: parent
                    text: "▶"
                    color: root.accent
                    font.pixelSize: 11
                  }
                }

                Text {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: 6
                  text: tile.modelData.name
                  elide: Text.ElideMiddle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: 11
                }

                MouseArea {
                  id: hover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.applyMedia(tile.modelData.path)
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: grid.count === 0
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.mediaLoading ? "Generating previews…"
              : "No media found. Put videos or images in ~/.config/omarchy/backgrounds/ (any subfolder)."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: 13
          }
        }
      }
    }
  }

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property bool active: false
    property bool small: false
    property var theme: null
    signal clicked()

    implicitWidth: chipText.implicitWidth + (small ? 16 : 24)
    implicitHeight: small ? 24 : 32
    width: implicitWidth
    height: implicitHeight
    radius: height / 2
    opacity: enabled ? 1 : 0.4
    color: active ? chip.theme.accent : (chipMouse.containsMouse ? chip.theme.tint(chip.theme.foreground, 0.12) : chip.theme.tint(chip.theme.foreground, 0.06))
    border.width: 1
    border.color: active ? chip.theme.accent : chip.theme.tint(chip.theme.foreground, 0.15)

    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      color: chip.active ? chip.theme.background : chip.theme.foreground
      font.family: chip.theme.fontFamily
      font.pixelSize: chip.small ? 11 : 12
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }
}
