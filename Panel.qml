import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar-Button und Panel in einer Datei, weil KeyboardPanel seinen anchorItem
// auf den Button richten muss.
Panel {
  id: root
  moduleName: "smartalb.opencode"
  ipcTarget: "smartalb.opencode"
  manageIpc: true

  // Zweite Kopie dessen, was manifest.json sagt -- QML kann das Manifest
  // nicht lesen (Omarchys PluginRegistry ist eine Instanz, kein Singleton).
  // test_panel_version_entspricht_dem_manifest haelt beide zusammen.
  readonly property string pluginVersion: "1.0.0"

  readonly property string scriptDir:
    Qt.resolvedUrl(".").toString().replace("file://", "") + "/bin"

  // Der Launcher ruft nur eigene Skripte; 20 s sind reichlich und kurz
  // genug, dass ein verklemmter Aufruf das Panel nicht festhaelt.
  readonly property int runSeconds: 20
  readonly property int maxOutBytes: 262144

  // Jeder Prozessstart des Panels laeuft hier durch. Eine Grenze, die man
  // an jeder Aufrufstelle erinnern muesste, wird an einer davon vergessen --
  // deshalb stehen die absoluten Pfade fest hier und nirgends sonst. Wer ein
  // Programm gleichen Namens weiter vorn in den PATH legt, bestimmte sonst,
  // was das Panel ausfuehrt.
  function runner(cmd) {
    return ["/usr/bin/timeout", "-k", "5", String(root.runSeconds), "/usr/bin/bash", "-c", cmd]
  }
  // Fuer einen Aufruf, dessen stdout gesammelt wird: die Grenze gehoert auf
  // die Erzeugerseite, damit die Bytes gar nicht erst gehalten werden.
  // Der Exit-Status danach ist der von /usr/bin/head -- deshalb melden die
  // Skripte Fehler im JSON, nicht nur ueber den Status.
  function runnerOut(cmd) {
    return root.runner("{ " + cmd + " ; } | /usr/bin/head -c " + root.maxOutBytes)
  }
  // Und fuer einen Aufruf, dessen stderr gesammelt wird. Prozess-Substitution
  // statt Pipe, weil eine Pipe den Exit-Status ersetzte, den der Aufrufer
  // liest.
  function runnerErr(cmd) {
    return root.runner("{ " + cmd + " ; } 2> >(/usr/bin/head -c "
      + root.maxOutBytes + " >&2)")
  }

  function shellEscape(s) {
    if (s === undefined || s === null) return "''"
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // Ein Panel, das verschwindet, darf keine Arbeit hinter sich herlaufen
  // lassen.
  Component.onDestruction: {
    projectsProc.running = false
    modelsProc.running = false
    launchProc.running = false
    storeProc.running = false
  }

  property var projects: []
  property var models: []
  property string loadError: ""
  property string launchError: ""
  property bool modelsStale: false
  property string sheetPath: ""
  property int cursor: 0

  // Einstellungen aus dem shell.json-Eintrag, ueber setting() der Basis.
  // Zahlen werden hier begrenzt, nicht im Skript geglaubt: der Wert wandert
  // in eine Kommandozeile, also darf er nur eine Zahl sein.
  readonly property string barLabelMode: String(root.setting("barLabel", "Icon"))
  readonly property int recentCount:
    Math.max(0, Math.min(50, Number(root.setting("recentCount", 5)) || 0))
  readonly property int refreshHours:
    Math.max(0, Math.min(720, Number(root.setting("catalogRefreshHours", 24)) || 24))
  readonly property bool confirmNewWindow: root.setting("confirmNewWindow", false) === true

  // Die Einstellungen erreichen die Skripte als Umgebungszuweisung vor dem
  // Befehl. Beide Werte sind oben auf Zahlen eingeschraenkt.
  readonly property string envPrefix:
    "OC_RECENT_COUNT=" + root.recentCount + " OC_REFRESH_HOURS=" + root.refreshHours + " "

  Process {
    id: projectsProc
    running: true
    command: root.runnerOut(root.envPrefix + root.scriptDir + "/omarchy-opencode-projects list --json")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.trim() === "") { root.projects = []; root.loadError = "Projektliste nicht lesbar"; return }
        try {
          var data = JSON.parse(raw)
          if (Array.isArray(data)) { root.projects = data; root.loadError = "" }
          else { root.projects = []; root.loadError = String((data && data.error) || "Projektliste nicht lesbar") }
        } catch (e) { root.projects = []; root.loadError = "Projektliste nicht lesbar" }
      }
    }
  }

  Process {
    id: modelsProc
    command: root.runnerOut(root.envPrefix + root.scriptDir + "/omarchy-opencode-models list --json")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || "{}"))
          root.models = d.models || []
          root.modelsStale = d.stale === true
        } catch (e) { root.models = []; root.modelsStale = true }
      }
    }
  }

  Process {
    id: storeProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text || "").trim()
        if (m !== "") root.launchError = m.split("\n").pop()
      }
    }
    onExited: projectsProc.running = true
  }

  Process {
    id: launchProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var m = String(text || "").trim()
        if (m !== "") root.launchError = m.split("\n").pop()
      }
    }
    onExited: projectsProc.running = true
  }

  function openProject(entry, newWindow) {
    if (!entry || entry.exists === false) return
    var c = root.scriptDir + "/omarchy-opencode-launch " + root.shellEscape(entry.path)
    if (entry.model) c += " --model " + root.shellEscape(entry.model)
    if (newWindow) c += " --new-window"
    root.launchError = ""
    launchProc.command = root.runnerErr(c)
    launchProc.running = true
  }

  function setModel(path, id) {
    var c = id === ""
      ? root.scriptDir + "/omarchy-opencode-store unset " + root.shellEscape(path)
      : root.scriptDir + "/omarchy-opencode-store set " + root.shellEscape(path)
        + " " + root.shellEscape(id)
    storeProc.command = root.runnerErr(c)
    storeProc.running = true
  }

  function refreshAll() {
    projectsProc.running = false; projectsProc.running = true
    modelsProc.command = root.runnerOut(root.envPrefix + root.scriptDir
      + "/omarchy-opencode-models list --json --refresh")
    modelsProc.running = true
  }

  function openSheetFor(path) {
    root.sheetPath = path
    if (root.models.length === 0) modelsProc.running = true
    sheet.visible = true
  }

  function closeSheet() {
    sheet.visible = false
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  readonly property bool listCapped:
    root.projects.length > 0 && root.projects[0].capped === true

  // Beim Oeffnen des Panels einen frischen Stand holen: der Laufzustand
  // (welches Projekt gerade laeuft) veraendert sich zwischen zwei Oeffnungen.
  onOpenedChanged: if (root.opened && !projectsProc.running) projectsProc.running = true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-robot_outline (U+F06A9), als Ersatzpaar-Escape: eine
    // Nerd-Font-Glyphe direkt in der Datei geht beim Kopieren durch
    // Werkzeuge verloren.
    text: "\uDB81\uDEA9" + (root.barLabelMode === "Running count"
            ? " " + root.projects.filter(function (p) { return p.running }).length
            : "")
    tooltipText: "opencode Launcher"
    // Nur Links- und Mittelklick sind belegt. Das von WidgetButton geerbte
    // Mausrad-Signal ("wheelMoved") bleibt hier absichtlich unverbunden:
    // ein Scrollen ueber der Bar darf keinen Start und keine Aenderung
    // ausloesen.
    onPressed: function (b) {
      if (b === Qt.MiddleButton) root.refreshAll()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(480))

    // Tastenfuehrung der Projektliste. Ein eigener Handler statt
    // PanelKeyCatcher, weil Umschalt+Eingabetaste (zweites Fenster) den
    // Modifizierer der Taste braucht -- PanelKeyCatchers Signale reichen ihn
    // nicht durch. focus:true plus Keys.priority sorgen dafuer, dass diese
    // Item-Instanz die Tasten bekommt, sobald focusTarget sie aktiviert.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (e) {
        var list = root.projects
        if (e.key === Qt.Key_Down) { root.cursor = Math.min(root.cursor + 1, list.length - 1); e.accepted = true }
        else if (e.key === Qt.Key_Up) { root.cursor = Math.max(root.cursor - 1, 0); e.accepted = true }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
          var second = (e.modifiers & Qt.ShiftModifier) !== 0
          if (second && root.confirmNewWindow) { root.launchError = "Umschalt+Eingabetaste noch einmal fuer ein zweites Fenster"; e.accepted = true; return }
          root.openProject(list[root.cursor], second); e.accepted = true
        }
        else if (e.key === Qt.Key_M) { if (list[root.cursor]) root.openSheetFor(list[root.cursor].path); e.accepted = true }
        else if (e.key === Qt.Key_R) { root.refreshAll(); e.accepted = true }
        else if (e.key === Qt.Key_Escape) {
          if (sheet.visible) root.closeSheet(); else root.close()
          e.accepted = true
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "OPENCODE"
            foreground: root.barForeground
            fontFamily: root.bar.fontFamily
          }

          Text {
            width: panelColumn.width
            visible: root.loadError !== ""
            text: root.loadError
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            width: panelColumn.width
            visible: root.launchError !== ""
            text: root.launchError
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            width: panelColumn.width
            visible: root.listCapped
            text: "Liste bei 200 Projekten gekappt"
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.7
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.projects
            delegate: Rectangle {
              required property var modelData
              required property int index

              width: panelColumn.width
              implicitHeight: rowColumn.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: (rowMouse.containsMouse && modelData.exists) ? Style.hoverFill : "transparent"
              opacity: modelData.exists === false ? 0.45 : 1.0

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: (modelData.running ? "\u25CF  " : "\u25CB  ") + modelData.name
                    + (modelData.modelLabel
                        ? "   \u2304 " + modelData.modelLabel + (modelData.modelKnown === false ? " (?)" : "")
                        : "   \u2304 (Std.)")
                  color: root.barForeground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: modelData.displayPath
                  color: root.barForeground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  opacity: 0.6
                  elide: Text.ElideMiddle
                }
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: modelData.exists ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: function (e) {
                  root.cursor = index
                  if (e.button === Qt.RightButton) root.openSheetFor(modelData.path)
                  else if (modelData.exists) root.openProject(modelData, false)
                }
              }
            }
          }
        }
      }
    }

    ModelSheet {
      id: sheet
      anchors.fill: parent
      models: root.models
      stale: root.modelsStale
      onPicked: function (id) { root.setModel(root.sheetPath, id); root.closeSheet() }
      onCleared: { root.setModel(root.sheetPath, ""); root.closeSheet() }
      onClosed: root.closeSheet()
    }
  }
}
