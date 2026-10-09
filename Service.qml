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
    color: Color.bar.background
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
      delegate: Hosted {
        required property var modelData
        entry: modelData
        barWin: section.barWin
        svc: section.svc
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

    readonly property bool needsService: !!info && info.service !== ""

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
      function serviceFor(id) { return String(id) === host.widgetId && svcLoader.item ? svcLoader.item : null }
    }

    Loader {
      id: svcLoader
      active: host.needsService
      source: host.needsService ? "file://" + host.info.service : ""
      onLoaded: {
        item.manifest = { id: host.widgetId, __sourceDir: host.info.dir }
        item.shell = hostShell
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
