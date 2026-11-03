pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtMultimedia

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string script: home + "/.config/omarchy/plugins/lucentdread.live-wallpaper/live-wallpaper.sh"
  readonly property string cleanupHelper: stateHome + "/omarchy/live-wallpaper/cleanup"
  readonly property string layoutPath: stateHome + "/omarchy/live-wallpaper/layout.json"
  property string videoPath: ""
  property var readyScreens: ({})
  property int playGeneration: 0
  property int revealGeneration: 0
  property bool revealVideo: true
  readonly property int maxVideoPathLen: 4096
  readonly property int maxTransitionMs: 4000
  readonly property string allowedConfigPrefix: home + "/.config/omarchy/backgrounds/"
  readonly property string allowedStatePrefix: home + "/.local/state/omarchy/current/theme/backgrounds/"
  readonly property string allowedSystemPrefix: "/usr/share/omarchy/"
  readonly property string allowedLocalSharePrefix: home + "/.local/share/omarchy/"
  readonly property var videoExtensions: ["mp4", "mkv", "webm", "mov", "m4v"]
  readonly property var imageExtensions: ["jpg", "jpeg", "png", "gif", "bmp", "webp"]
  readonly property var fitModes: ["crop", "fit", "stretch"]

  // Per-monitor layout. Every connected screen follows the Background picker
  // ("picker") unless layout.json says otherwise:
  //   screens.<name>: { mode: "picker" | "none" | "media", path, fit }
  //                   { mode: "span", span: "<span id>" }
  //   spans.<id>:     { path, fit, screens: [names in order] }
  // A span stretches one video or image over the bounding box of its screens,
  // like a single canvas laid across neighbouring monitors.
  property var layout: ({ version: 1, screens: {}, spans: {} })
  property int layoutRevision: 0
  // Bumped when monitors are added, removed or moved so span geometry updates.
  property int screenRevision: 0
  // Live MediaPlayer per screen name; span followers read their leader here.
  property var players: ({})

  // Inlined rather than imported from qs.Commons so the plugin carries no
  // shell-internal QML dependency, which can vary or be restricted across
  // Omarchy channels. Percent-encodes each path segment so spaces and special
  // characters in a wallpaper path do not break MediaPlayer.source.
  function fileUrl(path) {
    if (!path) return ""
    return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
  }

  function extensionOf(p) {
    var s = String(p || "")
    var dot = s.lastIndexOf(".")
    if (dot < 0 || dot < s.lastIndexOf("/")) return ""
    return s.substring(dot + 1).toLowerCase()
  }

  function isVideoPath(p) {
    return videoExtensions.indexOf(extensionOf(p)) !== -1
  }

  function isImagePath(p) {
    return imageExtensions.indexOf(extensionOf(p)) !== -1
  }

  function isAllowedPath(p) {
    if (!p) return false
    var s = String(p)
    if (s.length === 0 || s.length > maxVideoPathLen) return false
    if (s.indexOf("\n") !== -1 || s.indexOf("\t") !== -1 || s.indexOf("\0") !== -1) return false
    // must be absolute
    if (s.charAt(0) !== "/") return false
    // reject path traversal attempts with .. (after decode, fileUrl encodes but we check raw)
    if (s.indexOf("..") !== -1) return false
    // allow only under known wallpaper roots (user config, state symlink, system themes)
    return s.indexOf(allowedConfigPrefix) === 0 || s.indexOf(allowedStatePrefix) === 0
      || s.indexOf(allowedSystemPrefix) === 0 || s.indexOf(allowedLocalSharePrefix) === 0
  }

  function isValidVideoPath(p) {
    return isAllowedPath(p) && isVideoPath(p)
  }

  // Per-monitor assignments may also hold a still or animated image.
  function isValidMediaPath(p) {
    return isAllowedPath(p) && (isVideoPath(p) || isImagePath(p))
  }

  function clampTransitionMs(v) {
    var n = Number(v)
    if (!isFinite(n)) return 0
    n = Math.floor(n)
    if (n < 0) return 0
    if (n > maxTransitionMs) return maxTransitionMs
    return n
  }

  function openSelector() {
    if (!pickerProc.running) pickerProc.running = true
  }

  function openThemeSwitcher() {
    if (!themeSwitchProc.running) themeSwitchProc.running = true
  }

  function play(path, transitionMs) {
    revealTimer.stop()
    readyScreens = ({})
    var raw = String(path || "").trim()
    // bound length early
    if (raw.length > maxVideoPathLen) raw = raw.substring(0, maxVideoPathLen)
    var ms = clampTransitionMs(transitionMs)
    // validate; reject invalid paths silently (do not set videoPath)
    if (raw !== "" && !isValidVideoPath(raw)) {
      // invalid path -> treat as stop to avoid arbitrary file load
      videoPath = ""
      playGeneration += 1
      revealVideo = false
      console.warn("live-wallpaper: rejected invalid video path", raw)
      return
    }
    revealVideo = ms <= 0
    videoPath = raw
    playGeneration += 1
    if (!revealVideo) {
      revealGeneration = playGeneration
      revealTimer.interval = ms
      revealTimer.restart()
    }
  }

  function stop() {
    revealTimer.stop()
    revealVideo = false
    videoPath = ""
    readyScreens = ({})
    playGeneration += 1
  }

  function markFrameReady(screenName) {
    if (readyScreens[screenName]) return
    var next = {}
    for (var key in readyScreens) next[key] = readyScreens[key]
    next[screenName] = true
    readyScreens = next
  }

  // ------------------------------------------------------------ screen layout

  function isPlainObject(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v)
  }

  function validName(name) {
    var s = String(name || "")
    return s.length > 0 && s.length <= 64 && /^[A-Za-z0-9._:-]+$/.test(s)
  }

  function validFit(fit) {
    return fitModes.indexOf(String(fit || "")) !== -1 ? String(fit) : "crop"
  }

  function emptyLayout() {
    return { version: 1, screens: {}, spans: {} }
  }

  function copyLayout(src) {
    return JSON.parse(JSON.stringify(src || emptyLayout()))
  }

  // Everything read from disk passes through here, so a hand-edited or stale
  // layout.json can only ever describe media under the allowed roots.
  function normalizeLayout(raw) {
    var out = emptyLayout()
    if (!isPlainObject(raw)) return out

    var spans = isPlainObject(raw.spans) ? raw.spans : {}
    for (var id in spans) {
      var span = spans[id]
      if (!validName(id) || !isPlainObject(span) || !isValidMediaPath(span.path)) continue
      if (!Array.isArray(span.screens)) continue
      var members = []
      for (var i = 0; i < span.screens.length && members.length < 16; i++) {
        var member = String(span.screens[i] || "")
        if (validName(member) && members.indexOf(member) === -1) members.push(member)
      }
      if (members.length < 2) continue
      out.spans[id] = { path: String(span.path), fit: validFit(span.fit), screens: members }
    }

    var screens = isPlainObject(raw.screens) ? raw.screens : {}
    for (var name in screens) {
      var entry = screens[name]
      if (!validName(name) || !isPlainObject(entry)) continue
      var mode = String(entry.mode || "")
      if (mode === "none" || mode === "picker") {
        out.screens[name] = { mode: mode, fit: validFit(entry.fit) }
      } else if (mode === "media" && isValidMediaPath(entry.path)) {
        out.screens[name] = { mode: "media", path: String(entry.path), fit: validFit(entry.fit) }
      } else if (mode === "span" && out.spans[entry.span]
                 && out.spans[entry.span].screens.indexOf(name) !== -1) {
        out.screens[name] = { mode: "span", span: String(entry.span) }
      }
    }

    // A span only owns screens that point back at it.
    for (var sid in out.spans) {
      var kept = out.spans[sid].screens.filter(function(n) {
        return out.screens[n] && out.screens[n].mode === "span" && out.screens[n].span === sid
      })
      if (kept.length < 2) {
        for (var k = 0; k < kept.length; k++)
          out.screens[kept[k]] = { mode: "media", path: out.spans[sid].path, fit: out.spans[sid].fit }
        delete out.spans[sid]
      } else {
        out.spans[sid].screens = kept
      }
    }
    return out
  }

  function applyLayoutText(text) {
    var parsed = null
    try {
      parsed = String(text || "").trim() === "" ? null : JSON.parse(text)
    } catch (e) {
      console.warn("live-wallpaper: ignoring unreadable layout.json", e)
    }
    var next = normalizeLayout(parsed)
    if (JSON.stringify(next) === JSON.stringify(layout)) return
    layout = next
    layoutRevision += 1
  }

  function saveLayout(next) {
    layout = normalizeLayout(next)
    layoutRevision += 1
    layoutFile.setText(JSON.stringify(layout, null, 2) + "\n")
  }

  function connectedScreen(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name === name) return screens[i]
    return null
  }

  // Bounding box of a span's connected screens in the compositor's logical
  // coordinate space. Gaps between monitors stay part of the canvas, so the
  // picture lines up across bezels the way it would on one large display.
  function spanBox(names) {
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    for (var i = 0; i < names.length; i++) {
      var s = connectedScreen(names[i])
      if (!s) continue
      minX = Math.min(minX, s.x)
      minY = Math.min(minY, s.y)
      maxX = Math.max(maxX, s.x + s.width)
      maxY = Math.max(maxY, s.y + s.height)
    }
    if (!isFinite(minX)) return null
    return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
  }

  function spanLeader(spanId) {
    var span = layout.spans[spanId]
    if (!span) return ""
    for (var i = 0; i < span.screens.length; i++)
      if (connectedScreen(span.screens[i])) return span.screens[i]
    return ""
  }

  // The resolved source for one screen. The revision arguments exist only so
  // QML bindings that call this re-evaluate when the layout or monitors change.
  function assignmentFor(name, revision, screensRevision) {
    var entry = layout.screens[name]
    if (!entry) return { mode: "picker", path: "", fit: "crop", span: "", box: null }
    if (entry.mode === "span") {
      var span = layout.spans[entry.span]
      if (!span) return { mode: "picker", path: "", fit: "crop", span: "", box: null }
      return {
        mode: "span",
        path: span.path,
        fit: span.fit,
        span: entry.span,
        screens: span.screens.slice(),
        box: spanBox(span.screens)
      }
    }
    return { mode: entry.mode, path: entry.path || "", fit: entry.fit || "crop", span: "", box: null }
  }

  // Remove a screen from whatever span holds it. A span left with one screen
  // dissolves into a plain assignment of the same media on that screen.
  function detachScreen(next, name) {
    var entry = next.screens[name]
    if (!entry || entry.mode !== "span") return
    var span = next.spans[entry.span]
    delete next.screens[name]
    if (!span) return
    span.screens = span.screens.filter(function(n) { return n !== name })
    if (span.screens.length < 2) {
      for (var i = 0; i < span.screens.length; i++)
        next.screens[span.screens[i]] = { mode: "media", path: span.path, fit: span.fit }
      delete next.spans[entry.span]
    }
  }

  function cleanNames(names) {
    var list = Array.isArray(names) ? names : String(names || "").split(",")
    var out = []
    for (var i = 0; i < list.length; i++) {
      var n = String(list[i] || "").trim()
      if (validName(n) && out.indexOf(n) === -1) out.push(n)
    }
    return out
  }

  // mode: "picker" (follow Style > Background), "none" (show the static
  // wallpaper) or "media" (this screen's own video or image).
  function setScreens(names, mode, path, fit) {
    var list = cleanNames(names)
    mode = String(mode || "")
    if (list.length === 0 || ["picker", "none", "media"].indexOf(mode) === -1) return false
    if (mode === "media" && !isValidMediaPath(path)) return false
    var next = copyLayout(layout)
    for (var i = 0; i < list.length; i++) {
      var previous = assignmentFor(list[i], layoutRevision, screenRevision)
      detachScreen(next, list[i])
      if (mode === "picker") delete next.screens[list[i]]
      else next.screens[list[i]] = { mode: mode, path: mode === "media" ? String(path) : "",
                                     fit: validFit(fit || previous.fit) }
    }
    saveLayout(next)
    return true
  }

  // One picture laid across several screens. Order is kept so the first
  // connected screen leads playback and the others follow its clock.
  function spanScreens(names, path, fit) {
    var list = cleanNames(names)
    if (list.length < 2 || !isValidMediaPath(path)) return false
    var next = copyLayout(layout)
    var previousFit = assignmentFor(list[0], layoutRevision, screenRevision).fit
    for (var i = 0; i < list.length; i++) detachScreen(next, list[i])
    var id = "span-" + Date.now().toString(36)
    while (next.spans[id]) id += "x"
    next.spans[id] = { path: String(path), fit: validFit(fit || previousFit), screens: list }
    for (var j = 0; j < list.length; j++) next.screens[list[j]] = { mode: "span", span: id }
    saveLayout(next)
    return true
  }

  function setFit(names, fit) {
    var list = cleanNames(names)
    fit = validFit(fit)
    var next = copyLayout(layout)
    for (var i = 0; i < list.length; i++) {
      var entry = next.screens[list[i]]
      if (!entry) next.screens[list[i]] = { mode: "picker", fit: fit }
      else if (entry.mode === "span" && next.spans[entry.span]) next.spans[entry.span].fit = fit
      else entry.fit = fit
    }
    saveLayout(next)
    return true
  }

  function resetLayout() {
    saveLayout(emptyLayout())
  }

  function screensJson() {
    var out = []
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      out.push({ name: s.name, model: s.model || "", x: s.x, y: s.y, width: s.width, height: s.height,
                 assignment: assignmentFor(s.name, layoutRevision, screenRevision) })
    }
    return JSON.stringify(out)
  }

  FileView {
    id: layoutFile
    path: root.layoutPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyLayoutText(text())
    onLoadFailed: function(error) { root.applyLayoutText("") }
    // text() is stale inside the change signal; reload routes through onLoaded.
    onFileChanged: reload()
  }

  Connections {
    target: Quickshell
    function onScreensChanged() { root.screenRevision += 1 }
  }

  // Watchdogs: abort hung processes after 15s
  Timer {
    id: pickerWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (pickerProc.running) pickerProc.running = false
  }
  Timer {
    id: resumeWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (resumeProc.running) resumeProc.running = false
  }
  Timer {
    id: wireMenuWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (wireMenuProc.running) wireMenuProc.running = false
  }
  Timer {
    id: preparePickerWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (preparePickerProc.running) preparePickerProc.running = false
  }
  Timer {
    id: changeCheckWatchdog
    interval: 8000
    repeat: false
    onTriggered: if (changeCheckProc.running) changeCheckProc.running = false
  }
  Timer {
    id: themeSwitchWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (themeSwitchProc.running) themeSwitchProc.running = false
  }

  Process {
    id: pickerProc
    command: ["timeout", "30", root.script]
    onRunningChanged: if (running) pickerWatchdog.restart(); else pickerWatchdog.stop()
  }

  Process {
    id: resumeProc
    command: ["timeout", "15", root.script, "--resume"]
    onRunningChanged: if (running) resumeWatchdog.restart(); else resumeWatchdog.stop()
  }

  Process {
    id: wireMenuProc
    command: ["timeout", "15", root.script, "--wire-menu"]
    onRunningChanged: if (running) wireMenuWatchdog.restart(); else wireMenuWatchdog.stop()
  }

  Process {
    id: preparePickerProc
    command: ["timeout", "30", root.script, "--prepare-picker"]
    onRunningChanged: if (running) preparePickerWatchdog.restart(); else preparePickerWatchdog.stop()
  }

  Process {
    id: changeCheckProc
    command: ["timeout", "8", root.script, "--stop-if-changed"]
    onRunningChanged: if (running) changeCheckWatchdog.restart(); else changeCheckWatchdog.stop()
  }

  Process {
    id: themeSwitchProc
    // keep fixed string but wrap with timeout; inner bash already quotes "$theme"
    command: ["bash", "-c", "timeout 12 bash -c 'theme=$(timeout 8 omarchy-theme-switcher); [[ -n $theme ]] && timeout 8 omarchy-theme-set \"$theme\" >/dev/null 2>&1 &'"]
    onRunningChanged: if (running) themeSwitchWatchdog.restart(); else themeSwitchWatchdog.stop()
  }

  Timer {
    id: revealTimer
    repeat: false
    onTriggered: {
      if (root.revealGeneration === root.playGeneration && root.videoPath !== "")
        root.revealVideo = true
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      if (!changeCheckProc.running) changeCheckProc.running = true
    }
  }

  IpcHandler {
    target: "lucentdread.live-wallpaper"

    function play(path: string, transitionMs: int): void { root.play(path, transitionMs) }
    function playSimple(path: string): void { root.play(path, 0) }
    function stop(): void { root.stop() }
    function status(): string {
      return JSON.stringify({
        active: root.videoPath !== "",
        video: root.videoPath,
        readyScreens: Object.keys(root.readyScreens).length,
        revealed: root.revealVideo,
        generation: root.playGeneration,
        layout: root.layout
      })
    }
    // Connected monitors with their geometry and resolved assignment.
    function screens(): string { return root.screensJson() }
    // mode: picker | none | media. path is required for media.
    function setScreen(name: string, mode: string, path: string): string {
      return root.setScreens([name], mode, path, "") ? "ok" : "invalid"
    }
    // names: comma-separated monitor names, e.g. "DP-1,DP-2".
    function span(names: string, path: string): string {
      return root.spanScreens(names, path, "") ? "ok" : "invalid"
    }
    function setFit(names: string, fit: string): string {
      return root.setFit(names, fit) ? "ok" : "invalid"
    }
    function resetLayout(): string {
      root.resetLayout()
      return "ok"
    }
  }

  Component.onCompleted: {
    wireMenuProc.running = true
    resumeProc.running = true
    preparePickerProc.running = true
  }

  // Safe cleanup: verify helper is regular file not symlink before exec, via bash guard
  Component.onDestruction: Quickshell.execDetached(["bash", "-c", 'p="$1"; [[ ! -L "$p" && -f "$p" && -x "$p" ]] && exec "$p" --cleanup-after-unload', "bash", root.cleanupHelper])

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData
      readonly property string screenName: modelData ? String(modelData.name || "") : ""
      readonly property var assignment: root.assignmentFor(screenName, root.layoutRevision, root.screenRevision)
      readonly property bool followsPicker: assignment.mode === "picker"
      readonly property bool spanned: assignment.mode === "span" && !!assignment.box
      readonly property string sourcePath: followsPicker ? root.videoPath
        : (assignment.mode === "none" ? "" : String(assignment.path || ""))
      readonly property bool isVideo: sourcePath !== "" && root.isVideoPath(sourcePath)
      readonly property bool isImage: sourcePath !== "" && root.isImagePath(sourcePath)
        && root.isValidMediaPath(sourcePath)
      readonly property bool reveal: followsPicker ? root.revealVideo : true
      readonly property string fit: followsPicker ? "crop" : root.validFit(assignment.fit)
      readonly property bool isSpanLeader: spanned && root.spanLeader(assignment.span) === screenName
      // A new key restarts the player. Picker screens restart on every global
      // play(); span members restart together whenever their span changes so
      // they start from the same frame.
      readonly property string loadKey: !isVideo ? ""
        : followsPicker ? "picker:" + root.playGeneration + ":" + sourcePath
        : spanned ? "span:" + assignment.span + ":" + sourcePath
        : "media:" + sourcePath
      property string loadedKey: "-"
      property bool frameDecoded: false
      property int playerGeneration: 0
      property int acceptedGeneration: -1

      function syncPlayer() {
        var key = loadKey
        if (key === loadedKey) return
        loadedKey = key
        playerGeneration += 1
        var generation = playerGeneration
        acceptedGeneration = -1
        frameDecoded = false
        player.stop()
        player.playbackRate = 1
        player.source = ""
        if (key === "") return
        // validated on the way in, double-check before use
        if (!root.isValidMediaPath(sourcePath) || !isVideo) {
          console.warn("live-wallpaper: blocked invalid source in syncPlayer")
          return
        }
        player.source = root.fileUrl(sourcePath)
        player.play()
        Qt.callLater(function() {
          if (panel.playerGeneration === generation) panel.acceptedGeneration = generation
        })
      }

      // Followers chase the leader's clock: a small drift is absorbed by
      // nudging the playback rate, a large one (a stall, a loop seam) by a seek.
      function followLeader() {
        var leader = root.players[root.spanLeader(assignment.span)]
        if (!leader || leader === player || leader.playbackState !== MediaPlayer.PlayingState) return
        var duration = player.duration
        if (!(duration > 0)) return
        var diff = leader.position - player.position
        if (diff > duration / 2) diff -= duration
        else if (diff < -duration / 2) diff += duration
        if (Math.abs(diff) > 400) {
          player.playbackRate = 1
          player.setPosition((leader.position + 40) % duration)
        } else if (Math.abs(diff) > 25) {
          player.playbackRate = 1 + Math.max(-0.08, Math.min(0.08, diff / 1000))
        } else if (player.playbackRate !== 1) {
          player.playbackRate = 1
        }
      }

      onLoadKeyChanged: Qt.callLater(syncPlayer)
      onIsSpanLeaderChanged: if (isSpanLeader) player.playbackRate = 1

      screen: modelData
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "lucentdread-live-wallpaper"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      MediaPlayer {
        id: player
        videoOutput: videoOutput
        loops: MediaPlayer.Infinite
        onErrorOccurred: function(error, errorString) {
          console.warn("live-wallpaper: MediaPlayer error", error, errorString, "source", player.source)
          // fail closed: keep static fallback, do not auto-retry invalid media
          panel.frameDecoded = false
        }
      }

      Timer {
        interval: 1000
        repeat: true
        running: panel.spanned && panel.isVideo && panel.frameDecoded && !panel.isSpanLeader
        onTriggered: panel.followLeader()
      }

      Item {
        anchors.fill: parent
        clip: true

        // Screen-sized normally; for a span, the whole span canvas shifted so
        // this screen shows its own slice of it.
        Item {
          id: canvas
          x: panel.spanned ? panel.assignment.box.x - panel.modelData.x : 0
          y: panel.spanned ? panel.assignment.box.y - panel.modelData.y : 0
          width: panel.spanned ? panel.assignment.box.width : parent.width
          height: panel.spanned ? panel.assignment.box.height : parent.height

          Rectangle {
            anchors.fill: parent
            color: "black"
            visible: panel.fit === "fit" && (videoOutput.visible || still.visible || animated.visible)
          }

          VideoOutput {
            id: videoOutput
            anchors.fill: parent
            fillMode: panel.fit === "fit" ? VideoOutput.PreserveAspectFit
              : panel.fit === "stretch" ? VideoOutput.Stretch : VideoOutput.PreserveAspectCrop
            visible: panel.isVideo && panel.frameDecoded && panel.reveal
          }

          Image {
            id: still
            anchors.fill: parent
            asynchronous: true
            cache: false
            source: panel.isImage && root.extensionOf(panel.sourcePath) !== "gif" ? root.fileUrl(panel.sourcePath) : ""
            fillMode: panel.fit === "fit" ? Image.PreserveAspectFit
              : panel.fit === "stretch" ? Image.Stretch : Image.PreserveAspectCrop
            visible: source !== "" && status === Image.Ready
          }

          AnimatedImage {
            id: animated
            anchors.fill: parent
            asynchronous: true
            cache: false
            source: panel.isImage && root.extensionOf(panel.sourcePath) === "gif" ? root.fileUrl(panel.sourcePath) : ""
            fillMode: still.fillMode
            playing: visible
            visible: source !== "" && status === AnimatedImage.Ready
          }
        }
      }

      Connections {
        target: root
        function onRevealVideoChanged() {
          if (panel.followsPicker && root.revealVideo && panel.frameDecoded)
            player.play()
        }
      }

      Connections {
        target: videoOutput.videoSink
        function onVideoFrameChanged() {
          if (panel.isVideo && !panel.frameDecoded
              && panel.acceptedGeneration === panel.playerGeneration) {
            panel.frameDecoded = true
            if (!panel.reveal) player.pause()
            root.markFrameReady(panel.screenName)
          }
        }
      }

      Component.onCompleted: {
        root.players[screenName] = player
        syncPlayer()
      }
      Component.onDestruction: {
        if (root.players[screenName] === player) delete root.players[screenName]
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function(mouse) {
          if (mouse.button === Qt.RightButton) root.openThemeSwitcher()
          else root.openSelector()
          mouse.accepted = true
        }
      }
    }
  }
}
