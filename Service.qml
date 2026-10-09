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
  // Bumped whenever a bar is added or removed, so every bar window is rebuilt in the right order
  // (the compositor gives screen edges to windows in creation order).
  property int surfaceGen: 0
  property string lastSignature: ""
  property var catalog: ({})   // widget id -> { path, defaults }

  // Top and bottom bars are created first: the compositor hands out screen edges in
  // creation order, so the side bars end up between them instead of overlapping the corners.
  readonly property var surfaces: {
    var out = []
    var order = ["top", "bottom", "left", "right"]
    var sorted = bars.slice().sort(function(a, b) { return order.indexOf(a.position) - order.indexOf(b.position) })
    for (var b = 0; b < sorted.length; b++)
      for (var s = 0; s < Quickshell.screens.length; s++)
        out.push({ cfg: sorted[b], screen: Quickshell.screens[s], gen: surfaceGen })
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
    var sig = next.map(function(b) { return b.position }).sort().join(",")
    if (sig !== lastSignature) {
      var first = lastSignature === ""
      lastSignature = sig
      surfaceGen++
      if (!first) { surfacesOn = false; rebuild.restart() }   // adding/removing a bar: rebuild all, top and bottom first
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
            map[p.id] = { name: String(p.name || p.id),
                          path: String(p.barWidgetPath),
                          dir: String(p.sourceDir || ""),
                          service: svc,
                          defaults: (p.barWidget && p.barWidget.defaults) || {} }
          }
          root.catalog = map
        } catch (e) { console.warn("extra-bars: catalog parse failed: " + e) }
      }
    }
  }

  // ------------------------------------------------------------ drag and drop
  // Press and drag a widget to move it: onto any section of any extra bar (before the
  // widget under the pointer), or onto a section of the main bar. The move is applied by
  // Bar Manager's `barctl drop`, so the config files stay the single source of truth.
  property var dragSource: null          // { id, name }
  property bool dragLive: false
  property real dragGX: 0
  property real dragGY: 0
  property var dropTarget: null          // { edge, section, before, rect: {x, y, w, h} } in screen coordinates
  property var layerRects: ({})          // layer-shell namespace -> { x, y, w, h }
  property var barItems: ({})            // edge -> ExtraBar
  property var lastScene: null           // { win, x, y } until the layer geometry has loaded
  readonly property string barctlPath: Quickshell.env("HOME") + "/.config/omarchy/plugins/s3pp3ku.bar-manager/bin/barctl"

  function parseLayers(text) {
    var rects = {}
    try {
      var data = JSON.parse(text)
      for (var mon in data) {
        var levels = data[mon].levels || {}
        for (var lv in levels) {
          var arr = levels[lv]
          for (var i = 0; i < arr.length; i++) {
            var l = arr[i]
            if (String(l.namespace).indexOf("omarchy-bar") === 0 || String(l.namespace).indexOf("omarchy-extra-bar-") === 0)
              rects[l.namespace] = { x: l.x, y: l.y, w: l.w, h: l.h }
          }
        }
      }
    } catch (e) { console.warn("extra-bars: could not read layer geometry: " + e) }
    layerRects = rects
    if (lastScene && dragLive) updateDrag(lastScene.win, lastScene.x, lastScene.y)
  }

  function beginDrag(host) {
    var info = catalog[host.widgetId]
    dragSource = { id: host.widgetId, name: info && info.name ? info.name : host.widgetId }
    dropTarget = null
    lastScene = null
    dragLive = true
    layersProc.running = false
    layersProc.running = true
  }

  function updateDrag(win, sceneX, sceneY) {
    if (!dragLive) return
    lastScene = { win: win, x: sceneX, y: sceneY }
    var r = layerRects["omarchy-extra-bar-" + win.pos]
    if (!r) return                                   // geometry still loading
    dragGX = r.x + sceneX
    dragGY = r.y + sceneY
    dropTarget = findTarget(dragGX, dragGY)
  }

  function inRect(r, x, y, slack) {
    return x >= r.x - slack && x <= r.x + r.w + slack && y >= r.y - slack && y <= r.y + r.h + slack
  }

  function findTarget(gx, gy) {
    var edges = ["top", "bottom", "left", "right"]
    for (var i = 0; i < edges.length; i++) {
      var r = layerRects["omarchy-extra-bar-" + edges[i]]
      var win = barItems[edges[i]]
      if (!r || !win || !inRect(r, gx, gy, 12)) continue
      var d = win.dropAt(gx - r.x, gy - r.y, dragSource ? dragSource.id : "")
      if (d) return { edge: edges[i], section: d.section, before: d.before,
                      rect: { x: r.x + d.ind.x, y: r.y + d.ind.y, w: d.ind.w, h: d.ind.h } }
    }
    var m = layerRects["omarchy-bar"]
    if (m && inRect(m, gx, gy, 12)) {
      var edge = shell && shell.bar ? shell.bar.position : "top"
      var vertical = edge === "left" || edge === "right"
      var a = vertical ? gy - m.y : gx - m.x
      var len = vertical ? m.h : m.w
      var third = Math.max(0, Math.min(2, Math.floor(a / (len / 3))))
      var names = ["left", "center", "right"]
      return { edge: edge, section: names[third], before: "",
               rect: vertical ? { x: m.x, y: m.y + third * len / 3, w: m.w, h: len / 3 }
                              : { x: m.x + third * len / 3, y: m.y, w: len / 3, h: m.h } }
    }
    return null
  }

  function endDrag() {
    var tgt = dropTarget, src = dragSource
    dragLive = false
    dragSource = null
    dropTarget = null
    lastScene = null
    if (!tgt || !src) return
    dropProc.command = [barctlPath, "drop", src.id, tgt.edge, tgt.section, tgt.before]
    dropProc.running = false
    dropProc.running = true
  }

  Process {
    id: layersProc
    command: ["hyprctl", "layers", "-j"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseLayers(text) }
  }
  Process {
    id: dropProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim()) console.warn("extra-bars: move failed: " + text.trim())
    }
  }

  // The ghost label and drop marker, drawn above everything. Click-through (empty input mask).
  Variants {
    model: Quickshell.screens
    delegate: Component {
      PanelWindow {
        required property var modelData
        screen: modelData
        visible: root.dragLive
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        mask: Region {}
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "omarchy-extra-bar-drag"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        Rectangle {
          visible: root.dropTarget !== null
          x: root.dropTarget ? root.dropTarget.rect.x : 0
          y: root.dropTarget ? root.dropTarget.rect.y : 0
          width: root.dropTarget ? root.dropTarget.rect.w : 0
          height: root.dropTarget ? root.dropTarget.rect.h : 0
          color: Color.accent
          opacity: root.dropTarget && root.dropTarget.rect.w > 12 && root.dropTarget.rect.h > 12 ? 0.25 : 0.95
          radius: 2
        }
        Rectangle {
          visible: root.dropTarget !== null
          x: root.dragGX + 14
          y: root.dragGY + 14
          width: ghostLabel.implicitWidth + 16
          height: ghostLabel.implicitHeight + 8
          color: Color.bar.background
          border.color: Color.accent
          border.width: 1
          radius: 4
          Text {
            id: ghostLabel
            anchors.centerIn: parent
            text: root.dragSource ? root.dragSource.name : ""
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: 12
          }
        }
      }
    }
  }

  // All bar windows live under this Loader so they can be torn down and rebuilt together.
  property bool surfacesOn: true
  Timer { id: rebuild; interval: 120; onTriggered: root.surfacesOn = true }
  Loader {
    active: root.surfacesOn
    sourceComponent: Component {
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
    WlrLayershell.namespace: "omarchy-extra-bar-" + win.pos
    WlrLayershell.layer: WlrLayer.Top

    // Widgets with a text input (wantsKeyboard) get the keyboard only while
    // they say so; otherwise the bar never takes it from your windows. It is
    // On-Demand plus a Hyprland focus grab, never Exclusive: clicking anywhere
    // outside the bar clears the grab and every holder is told to let go, so
    // the keyboard can always be taken back.
    property var kbHolders: ({})   // widget id -> widget item
    readonly property bool kbWanted: Object.keys(kbHolders).length > 0
    WlrLayershell.keyboardFocus: kbWanted ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    Component.onCompleted: if (svc) svc.barItems[pos] = win

    // Where a widget dropped at (lx, ly) in this bar would land: the section, the widget it goes
    // before, and a marker rectangle (all in this window's coordinates).
    function dropAt(lx, ly, excludeId) {
      var secs = [{ name: "left", item: secL }, { name: "center", item: secC }, { name: "right", item: secR }]
      var a = vert ? ly : lx
      var len = vert ? height : width
      var chosen = null
      for (var i = 0; i < 3 && !chosen; i++) {
        var it = secs[i].item
        var size = vert ? it.height : it.width
        if (size <= 0) continue
        var p = it.mapToItem(win.contentItem, 0, 0)
        var start = vert ? p.y : p.x
        if (a >= start - 10 && a <= start + size + 10) chosen = secs[i]
      }
      if (!chosen) chosen = a < len / 3 ? secs[0] : (a < 2 * len / 3 ? secs[1] : secs[2])
      var slots = chosen.item.slotRects(excludeId)
      var origin = chosen.item.mapToItem(win.contentItem, 0, 0)
      var ox = vert ? origin.y : origin.x
      var before = "", mark = 0, found = false
      for (var j = 0; j < slots.length; j++) {
        var s = slots[j]
        var centre = ox + (vert ? s.y + s.h / 2 : s.x + s.w / 2)
        if (a < centre) { before = s.id; mark = ox + (vert ? s.y : s.x); found = true; break }
      }
      if (!found) {
        if (slots.length) {
          var last = slots[slots.length - 1]
          mark = ox + (vert ? last.y + last.h : last.x + last.w)
        } else mark = chosen.name === "left" ? 10 : (chosen.name === "center" ? len / 2 : len - 10)
      }
      return { section: chosen.name, before: before,
               ind: vert ? { x: 3, y: mark - 1.5, w: width - 6, h: 3 } : { x: mark - 1.5, y: 3, w: 3, h: height - 6 } }
    }

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
      id: secL
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
      id: secC
      barWin: win
      svc: win.svc
      ids: win.config.center
      anchors.centerIn: parent
    }
    Section {
      id: secR
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

    function slotRects(excludeId) {
      var out = []
      for (var i = 0; i < slotRepeater.count; i++) {
        var it = slotRepeater.itemAt(i)
        if (!it || it.width <= 0 || it.height <= 0) continue
        var id = section.svc.entryId(it.modelData)
        if (id === excludeId) continue
        var p = it.mapToItem(section, 0, 0)
        out.push({ id: id, x: p.x, y: p.y, w: it.width, h: it.height })
      }
      return out
    }

    Repeater {
      id: slotRepeater
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
    // A widget can opt out of being dragged (e.g. one with a text field) with `readonly property bool draggable: false`.
    readonly property bool noDrag: !!loader.item && loader.item.draggable === false

    DragHandler {
      id: dragger
      enabled: !host.noDrag
      target: null
      acceptedButtons: Qt.LeftButton
      dragThreshold: 10
      grabPermissions: PointerHandler.CanTakeOverFromItems | PointerHandler.CanTakeOverFromHandlersOfDifferentType | PointerHandler.ApprovesTakeOverByAnything
      onActiveChanged: { if (active) host.svc.beginDrag(host); else host.svc.endDrag() }
      onCentroidChanged: if (active) host.svc.updateDrag(host.barWin, centroid.scenePosition.x, centroid.scenePosition.y)
    }

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
      // Clicks fire on release so that a press-and-drag (see the DragHandler) can move the widget instead.
      property var pendingTarget: null
      property int pendingButton: 0
      onPressed: function (m) {
        var t = host.clickTargetAt(m.x, m.y)
        if (t) { pendingTarget = t; pendingButton = m.button; m.accepted = true }
        else m.accepted = false
      }
      onReleased: function (m) {
        var t = pendingTarget
        pendingTarget = null
        if (t) t.triggerPress(pendingButton)
      }
      onCanceled: pendingTarget = null
    }
  }
}
