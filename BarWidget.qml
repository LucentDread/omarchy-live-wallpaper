import QtQuick

// Bar button that opens the per-monitor live wallpaper editor. Left click
// opens the editor, right click opens the Background picker.
Item {
  id: root

  property var bar: null
  property var settings: ({})
  property string moduleName: ""

  readonly property string pluginId: "lucentdread.live-wallpaper"
  readonly property string script: "~/.config/omarchy/plugins/lucentdread.live-wallpaper/live-wallpaper.sh"
  readonly property int slot: bar && bar.barSize > 0 ? bar.barSize : 26
  readonly property bool vertical: bar ? bar.vertical === true : false

  implicitWidth: vertical ? slot : Math.max(slot, glyph.implicitWidth + 14)
  implicitHeight: vertical ? Math.max(slot, glyph.implicitHeight + 10) : slot

  function run(command) {
    if (bar && typeof bar.run === "function") bar.run(command)
  }

  function openEditor() {
    if (bar && bar.shell && typeof bar.shell.toggle === "function"
        && bar.shell.toggle(pluginId, "{}")) return
    run("omarchy-shell shell toggle " + pluginId + " '{}'")
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    text: ""
    color: root.bar && root.bar.foreground ? root.bar.foreground : "white"
    font.family: root.bar && root.bar.fontFamily ? root.bar.fontFamily : "monospace"
    font.pixelSize: Math.max(11, Math.round(root.slot * 0.5))
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar && typeof root.bar.showTooltip === "function")
      root.bar.showTooltip(root, "Live wallpaper screens")
    onExited: if (root.bar && typeof root.bar.hideTooltip === "function") root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (root.bar && typeof root.bar.hideTooltip === "function") root.bar.hideTooltip(root)
      if (mouse.button === Qt.RightButton) root.run(root.script)
      else root.openEditor()
    }
  }
}
