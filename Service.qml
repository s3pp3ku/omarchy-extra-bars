import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Extra bars. The Omarchy shell runs one bar; this service adds more on the
// other screen edges and hosts ordinary bar widgets in them, handing each one
// a bar facade that reports the real edge (so popups open away from it).
//
// Config: ~/.config/omarchy/extra-bars.json
//   { "bars": [ { "position": "bottom",
//                 "left":   ["com.leafbox.f1", { "id": "s3pp3ku.mlb" }],
//                 "center": ["io.github.qempexe.omaudix"],
//                 "right":  ["danielmrdev.sysinfo"] } ] }
// position is bottom, left or right (the main bar owns the other edge).
// An entry is a widget id, or an object with "id" plus per-widget settings.
Item {
  id: root

  property var shell: null

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/extra-bars.json"
  property var bars: []
  property var catalog: ({})   // widget id -> { path, defaults }

  readonly property var surfaces: {
    var out = []
    for (var b = 0; b < bars.length; b++)
      for (var s = 0; s < Quickshell.screens.length; s++)
        out.push({ cfg: bars[b], screen: Quickshell.screens[s] })
    return out
  }

  function entryId(e) { return typeof e === "string" ? e : (e && e.id ? String(e.id) : "") }
  function entrySettings(e) {
    var o = {}
    if (e && typeof e === "object") for (var k in e) if (k !== "id") o[k] = e[k]
    return o
  }

  function parseConfig(text) {
    var next = []
    try {
      var data = JSON.parse(text)
      var list = Array.isArray(data.bars) ? data.bars : []
      for (var i = 0; i < list.length; i++) {
        var b = list[i]
        if (["bottom", "left", "right", "top"].indexOf(b.position) === -1) continue
        next.push({
          position: b.position,
          left: Array.isArray(b.left) ? b.left : [],
          center: Array.isArray(b.center) ? b.center : [],
          right: Array.isArray(b.right) ? b.right : []
        })
      }
    } catch (e) {
      console.warn("extra-bars: could not read " + configPath + ": " + e)
    }
    bars = next
  }

  // Follow the main bar's transparency so every edge matches
  // (Style > Menu Bar > Transparency toggles `bar.transparent` in shell.json).
  property bool transparent: false
  FileView {
    id: shellCfg
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.transparent = JSON.parse(shellCfg.text()).bar.transparent === true } catch (e) {}
    }
    onFileChanged: shellCfg.reload()
  }

  FileView {
    id: cfg
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseConfig(cfg.text())
    onLoadFailed: root.bars = []
    onFileChanged: cfg.reload()
  }

  // Where each widget's component lives, and its default settings.
  Process {
    id: catalogProc
    command: ["omarchy-plugin-catalog"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var arr = JSON.parse(text), map = {}
          for (var i = 0; i < arr.length; i++) {
            var p = arr[i]
            if (!p.barWidgetPath) continue
            var svc = (Array.isArray(p.kinds) && p.kinds.indexOf("service") !== -1 && p.entryPoints && p.entryPoints.service)
              ? p.sourceDir + "/" + p.entryPoints.service : ""
            map[p.id] = { path: String(p.barWidgetPath),
                          dir: String(p.sourceDir || ""),
                          service: svc,
                          defaults: (p.barWidget && p.barWidget.defaults) || {} }
          }
          root.catalog = map
        } catch (e) { console.warn("extra-bars: catalog parse failed: " + e) }
      }
    }
  }

  Variants {
    model: root.surfaces
    delegate: Component {
      ExtraBar {
        required property var modelData
        svc: root
        screen: modelData.screen
        config: modelData.cfg
      }
    }
  }

  // ---------------------------------------------------------------- the bar
  component ExtraBar: PanelWindow {
    id: win
    property var svc: null
    property var config: ({ position: "bottom", left: [], center: [], right: [] })

    readonly property string pos: config.position
    readonly property bool vert: pos === "left" || pos === "right"
    readonly property int size: vert ? Style.bar.sizeVertical : Style.bar.sizeHorizontal

    anchors {
      top: win.pos === "top" || win.vert
      bottom: win.pos === "bottom" || win.vert
      left: win.pos === "left" || !win.vert
      right: win.pos === "right" || !win.vert
    }
    implicitWidth: vert ? size : 0
    implicitHeight: vert ? 0 : size
    exclusionMode: ExclusionMode.Auto
    color: svc && svc.transparent ? "transparent" : Color.bar.background
    surfaceFormat.opaque: false
    WlrLayershell.namespace: "omarchy-extra-bar"
    WlrLayershell.layer: WlrLayer.Top

    // Widgets with a text input (wantsKeyboard) get the keyboard only while
    // they say so; otherwise the bar never takes it from your windows. It is
    // On-Demand plus a Hyprland focus grab, never Exclusive: clicking anywhere
    // outside the bar clears the grab and every holder is told to let go, so
    // the keyboard can always be taken back.
    property var kbHolders: ({})   // widget id -> widget item
    readonly property bool kbWanted: Object.keys(kbHolders).length > 0
    WlrLayershell.keyboardFocus: kbWanted ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    function releaseKeyboards() {
      var held = kbHolders
      kbHolders = ({})
      for (var k in held) {
        var item = held[k]
        if (item && typeof item.releaseKeyboard === "function") item.releaseKeyboard()
      }
    }

    HyprlandFocusGrab {
      active: win.kbWanted
      windows: [win]
      onCleared: win.releaseKeyboards()
    }

    Section {
      barWin: win
      svc: win.svc
      ids: win.config.left
      anchors.left: win.vert ? undefined : parent.left
      anchors.leftMargin: Style.space(8)
      anchors.top: win.vert ? parent.top : undefined
      anchors.topMargin: Style.space(8)
      anchors.verticalCenter: win.vert ? undefined : parent.verticalCenter
      anchors.horizontalCenter: win.vert ? parent.horizontalCenter : undefined
    }
    Section {
      barWin: win
      svc: win.svc
      ids: win.config.center
      anchors.centerIn: parent
    }
    Section {
      barWin: win
      svc: win.svc
      ids: win.config.right
      anchors.right: win.vert ? undefined : parent.right
      anchors.rightMargin: Style.space(8)
      anchors.bottom: win.vert ? parent.bottom : undefined
      anchors.bottomMargin: Style.space(8)
      anchors.verticalCenter: win.vert ? undefined : parent.verticalCenter
      anchors.horizontalCenter: win.vert ? parent.horizontalCenter : undefined
    }
  }

  // A row (or column, on a side bar) of hosted widgets.
  component Section: Grid {
    id: section
    property var barWin: null
    property var svc: null
    property var ids: []
    flow: barWin.vert ? Grid.TopToBottom : Grid.LeftToRight
    columns: barWin.vert ? 1 : Math.max(1, ids.length)
    rows: barWin.vert ? Math.max(1, ids.length) : 1
    spacing: Style.space(2)

    Repeater {
      model: section.ids
      delegate: Loader {
        id: slot
        required property var modelData
        readonly property bool isTray: !!modelData && typeof modelData === "object"
          && String(modelData.id || "").indexOf("tray:") === 0
        sourceComponent: isTray ? trayGroup : hostedWidget
        Component { id: hostedWidget; Hosted { entry: slot.modelData; barWin: section.barWin; svc: section.svc } }
        Component { id: trayGroup; TrayGroup { entry: slot.modelData; barWin: section.barWin; svc: section.svc } }
      }
    }
  }

  // A drawer holding its own list of widgets: a chevron that slides them out.
  // Any number can sit on any bar; each is {"id": "tray:<name>", "widgets": [ids]}.
  // It opens toward the middle of the bar (right/down from the start half,
  // left/up from the end half) and the chevron points the way it will open.
  component TrayGroup: Item {
    id: tg
    property var barWin: null
    property var svc: null
    property var entry: null
    readonly property var members: entry && entry.widgets && entry.widgets.length !== undefined ? entry.widgets : []
    readonly property bool vert: !!barWin && barWin.vert
    readonly property real thick: barWin ? barWin.size : 30
    readonly property real chevSize: Style.bar.iconSlot
    property bool pinned: false
    property bool held: false
    property bool reverse: false
    readonly property bool open: pinned || held
    property real reveal: open ? 1 : 0
    Behavior on reveal { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    readonly property real innerExtent: vert ? inner.implicitHeight : inner.implicitWidth
    readonly property real shown: innerExtent * reveal
    implicitWidth: vert ? thick : chevSize + shown
    implicitHeight: vert ? chevSize + shown : thick

    // Which way it opens; measured only while closed so opening can't flip it.
    function measure() {
      if (reveal > 0.001 || !barWin || !barWin.contentItem) return
      var p = chev.mapToItem(barWin.contentItem, chev.width / 2, chev.height / 2)
      var pos = vert ? p.y : p.x
      var len = vert ? barWin.contentItem.height : barWin.contentItem.width
      if (len > 0) reverse = pos > len / 2
    }
    Timer { interval: 400; running: true; repeat: true; triggeredOnStart: true; onTriggered: tg.measure() }

    // Keep it open a moment after the pointer leaves, so moving onto a popup doesn't snap it shut.
    Timer { id: closeDelay; interval: 700; onTriggered: tg.held = false }
    HoverHandler {
      id: hover
      onHoveredChanged: { if (hovered) { closeDelay.stop(); tg.held = true } else closeDelay.restart() }
    }

    Item {
      id: chev
      width: tg.vert ? tg.thick : tg.chevSize
      height: tg.vert ? tg.chevSize : tg.thick
      x: tg.vert ? 0 : (tg.reverse ? tg.shown : 0)
      y: tg.vert ? (tg.reverse ? tg.shown : 0) : 0
      Text {
        anchors.centerIn: parent
        color: tg.open ? Color.accent : Color.foreground
        font.family: Style.font.family
        font.pixelSize: 14
        // points the way it opens; flips to point back while it is open
        text: {
          var towardEnd = !tg.reverse
          if (tg.open) towardEnd = !towardEnd
          if (tg.vert) return towardEnd ? "\uf078" : "\uf077"
          return towardEnd ? "\uf054" : "\uf053"
        }
      }
      MouseArea {
        anchors.fill: parent
        onClicked: tg.pinned = !tg.pinned
      }
    }

    Item {
      id: clip
      clip: true
      width: tg.vert ? tg.thick : tg.shown
      height: tg.vert ? tg.shown : tg.thick
      x: tg.vert ? 0 : (tg.reverse ? 0 : tg.chevSize)
      y: tg.vert ? (tg.reverse ? 0 : tg.chevSize) : 0
      Grid {
        id: inner
        // pinned to the edge next to the chevron, so contents slide out from it
        x: tg.vert ? 0 : (tg.reverse ? clip.width - width : 0)
        y: tg.vert ? (tg.reverse ? clip.height - height : 0) : 0
        flow: tg.vert ? Grid.TopToBottom : Grid.LeftToRight
        columns: tg.vert ? 1 : Math.max(1, tg.members.length)
        rows: tg.vert ? Math.max(1, tg.members.length) : 1
        spacing: Style.space(2)
        Repeater {
          model: tg.members
          delegate: Hosted {
            required property var modelData
            entry: modelData
            barWin: tg.barWin
            svc: tg.svc
          }
        }
      }
    }
  }

  // One widget plus the bar facade it expects from its host.
  component Hosted: Item {
    id: host
    property var barWin: null
    property var svc: null
    property var entry: null
    readonly property string widgetId: svc.entryId(entry)
    readonly property var info: svc.catalog[widgetId] || null

    // Widgets that read their data from a companion service (bar.shell.
    // serviceFor) get their own copy of it, created before the widget.
    readonly property bool wantsKeyboard: !!loader.item && loader.item.wantsKeyboard === true
    onWantsKeyboardChanged: {
      var m = {}
      for (var k in barWin.kbHolders) m[k] = true
      if (wantsKeyboard) m[widgetId] = loader.item
      else delete m[widgetId]
      barWin.kbHolders = m
    }

    readonly property var realService: svc && svc.shell && typeof svc.shell.serviceFor === "function"
      ? svc.shell.serviceFor(widgetId) : null
    readonly property bool needsService: !!info && info.service !== "" && !realService

    function targetClickable(t) {
      return t && t.visible !== false && t.opacity !== 0 && t.interactive !== false
        && t.pressable !== false && t.concealed !== true && typeof t.triggerPress === "function"
    }

    // Widgets like sysinfo register a click target and wait for the bar to
    // hand them presses; do that here.
    function clickTargetAt(x, y) {
      var list = api.clickTargets
      for (var i = list.length - 1; i >= 0; i--) {
        var t = list[i]
        if (!targetClickable(t)) continue
        try {
          var p = host.mapToItem(t, x, y)
          if (p.x >= 0 && p.x <= t.width && p.y >= 0 && p.y <= t.height) return t
        } catch (e) {}
      }
      return null
    }

    implicitWidth: loader.item ? loader.item.implicitWidth : 0
    implicitHeight: barWin.vert ? (loader.item ? loader.item.implicitHeight : 0) : barWin.size

    PluginBarApi {
      id: api
      pluginId: host.widgetId
      moduleName: host.widgetId
      foreground: Color.foreground
      barForeground: Color.bar.text
      background: Color.bar.background
      urgent: Color.urgent
      fontFamily: Style.font.family
      position: barWin.pos
      vertical: barWin.vert
      barSize: barWin.size
      transparent: false

      shell: hostShell
      _registerClickTarget: function (target) {
        if (api.clickTargets.indexOf(target) === -1) api.clickTargets = api.clickTargets.concat([target])
      }
      _unregisterClickTarget: function (target) {
        api.clickTargets = api.clickTargets.filter(function (t) { return t !== target })
      }
      _run: function (command) { Quickshell.execDetached(["bash", "-c", command]) }
      _requestPopout: function (owner) { api.activePopout = owner }
      _releasePopout: function (owner) { if (api.activePopout === owner) api.activePopout = null }
      _moduleWidgets: function (id) { return id === host.widgetId && loader.item ? [loader.item] : [] }
      _targetBelongsToWindow: function (target, window) { return !!target && target.QsWindow.window === window }
    }

    QtObject {
      id: hostShell
      // The real shell's service wins when it is running (so a widget shares state with the rest of
      // Omarchy and nothing runs twice); otherwise the widget gets its own copy from svcLoader.
      function serviceFor(id) {
        if (String(id) !== host.widgetId) return null
        return host.realService || (svcLoader.item ? svcLoader.item : null)
      }
      function firstPartyServiceFor(id) { return serviceFor(id) }
    }

    Loader {
      id: svcLoader
      active: host.needsService
      source: host.needsService ? "file://" + host.info.service : ""
      onLoaded: {
        if ("manifest" in item) item.manifest = { id: host.widgetId, __sourceDir: host.info.dir }
        if ("shell" in item) item.shell = hostShell
        // Services that host other bar widgets (the Tray's drawer) need the shell's widget registry.
        var real = host.svc ? host.svc.shell : null
        if ("barWidgetRegistry" in item && real && typeof real.pluginBarWidgetRegistryFor === "function")
          item.barWidgetRegistry = real.pluginBarWidgetRegistryFor({ id: host.widgetId, __sourceDir: host.info.dir })
      }
    }

    Loader {
      id: loader
      anchors.centerIn: parent
      active: host.info !== null && (!host.needsService || svcLoader.item !== null)
      source: host.info ? "file://" + host.info.path : ""
      onLoaded: {
        var s = {}
        var d = host.info.defaults
        for (var k in d) s[k] = d[k]
        var o = host.svc.entrySettings(host.entry)
        for (var j in o) s[j] = o[j]
        item.bar = api
        item.moduleName = host.widgetId
        item.settings = s
      }
    }

    // Hands presses to registered click targets (see clickTargetAt); any press
    // that misses them falls through to the widget's own mouse handling.
    MouseArea {
      anchors.fill: parent
      z: 1000
      acceptedButtons: Qt.AllButtons
      onPressed: function (m) {
        var t = host.clickTargetAt(m.x, m.y)
        if (t) { t.triggerPress(m.button); m.accepted = true }
        else m.accepted = false
      }
    }
  }
}
