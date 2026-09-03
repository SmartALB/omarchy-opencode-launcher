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

  // Quality (Fix Runde 1): sechs Stellen lasen bisher "root.bar.fontFamily"
  // direkt -- "bar" wird erst in Loader.onLoaded eingesetzt, der ERSTE
  // Render-Durchlauf sieht also "null" und jede dieser Stellen protokollierte
  // einen TypeError. Dasselbe Muster wie im Schwesterplugin smartalb.vpn
  // ("fontFam" mit Rueckfall auf Style.fontFamily). root.barForeground ist
  // davon nicht betroffen: die Basis "Panel" (qs.Ui) liefert das bereits
  // abgesichert.
  readonly property string fontFam: root.bar ? root.bar.fontFamily : Style.fontFamily

  // C10: decodeURIComponent ist Pflicht, nicht Kosmetik. Qt.resolvedUrl
  // liefert eine URL, und die kodiert Zeichen prozentweise -- ein
  // Installationsverzeichnis mit einem Leerzeichen kommt als ".../mein%20
  // plugin/bin" heraus. shellEscape() unten macht diesen Wert SICHER
  // (nichts davon wird von der Shell interpretiert), aber nicht RICHTIG:
  // ein Pfad, den es so gar nicht gibt, laesst jeden Skriptaufruf mit
  // "No such file or directory" scheitern. Der frueher hier stehende
  // Kommentar behauptete das Gegenteil.
  readonly property string scriptDir:
    decodeURIComponent(Qt.resolvedUrl(".").toString().replace("file://", "")) + "/bin"

  // scriptCmd() haengt den Skriptnamen an und escaped das Ganze EINMAL, an
  // einer Stelle -- jeder Aufrufer haengt nur noch geschuetzte Argumente an.
  function scriptCmd(name) {
    return root.shellEscape(root.scriptDir + "/" + name)
  }

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
  // Fix Runde 2: ohne diese Klemme zeigt "cursor" nach einem Aktualisieren
  // mit weniger Zeilen als vorher ins Leere -- die Markierung verschwindet,
  // und Enter traefe "undefined" (der bestehende "!entry"-Schutz in
  // openProject() faengt das zwar ab, aber die Markierung soll erst gar
  // nicht verschwinden).
  onProjectsChanged: root.cursor = Math.max(0, Math.min(root.cursor, root.projects.length - 1))
  property var models: []
  property string loadError: ""
  property string launchError: ""
  property bool modelsStale: false
  property string modelsError: ""
  property string sheetPath: ""
  property int cursor: 0
  // Wer den laufenden storeProc-Aufruf ausgeloest hat: das Setzen/Loeschen
  // eines Modells (aktualisiert danach die Projektliste, weil deren
  // "modelLabel" sich geaendert hat) oder das Umschalten eines Sterns
  // (fragt danach die Modell-Liste MIT "--refresh" neu ab). Das "--refresh"
  // ist Pflicht, keine Kosmetik (G2, Fix Runde 2): "starred" wird nur beim
  // tatsaechlichen Abruf von opencode neu in bin/omarchy-opencode-models'
  // Zwischenspeicher geschrieben -- ein Wiedereinlesen OHNE "--refresh"
  // liefert bei einem noch frischen Zwischenspeicher weiterhin den alten
  // Stern-Stand zurueck, und toggleStar() liest "starred" aus genau dieser
  // Liste, um zwischen "star" und "unstar" zu entscheiden. Ein Feld statt
  // zwei getrennter Prozesse: beides sind kurze, seltene Schreibzugriffe
  // auf denselben Store, ein zweiter Process-Typ wuerde nur Component.
  // onDestruction um einen weiteren Eintrag verlaengern, ohne dass irgendwo
  // zwei solche Aufrufe je gleichzeitig liefen.
  property string storeAction: ""

  // C3 (Fix Runde 1): Umschalt+Eingabetaste bei "confirmNewWindow" musste
  // bisher NICHTS merken -- die zweite Umschalt+Eingabetaste nahm denselben
  // Zweig wie die erste, ein zweites Fenster war so nie erreichbar.
  // confirmArmedPath haelt fest, FUER WELCHES Projekt die Bestaetigung
  // schon aussteht; jede andere Taste, ein Zeilenwechsel, ein Klick auf
  // eine andere Zeile, das Schliessen des Panels oder ein Timeout von
  // wenigen Sekunden nehmen sie wieder zurueck (disarmConfirm()) --
  // README.md verspricht "das muss einmal bestaetigt werden", nicht
  // "bleibt beliebig lang scharf".
  property string confirmArmedPath: ""
  property string confirmHint: ""

  function disarmConfirm() {
    root.confirmArmedPath = ""
    root.confirmHint = ""
    confirmTimer.stop()
  }

  function armConfirm(path) {
    root.confirmArmedPath = path
    root.confirmHint = "Press Shift+Enter again to open a second window"
    confirmTimer.restart()
  }

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.disarmConfirm()
  }

  // Einstellungen aus dem shell.json-Eintrag, ueber setting() der Basis.
  // Zahlen werden hier begrenzt, nicht im Skript geglaubt: der Wert wandert
  // in eine Kommandozeile, also darf er nur eine Zahl sein.
  //
  // W2 (Fix Runde 1): "Number(...) || 24" verwandelte ein bewusst
  // konfiguriertes 0 in 24 -- 0 ist im Skript aber bedeutsam ("den
  // Zwischenspeicher nie als frisch behandeln"). numOrDefault() ersetzt nur,
  // was zu NaN wird (ein fehlender Wert, ein nicht-numerischer Text), durch
  // den Standard; eine echte 0 bleibt 0. Richtigstellung (Fix Runde 2):
  // "Number('')" ist 0, nicht NaN -- eine leere Zeichenkette faellt also
  // NICHT auf den Standard zurueck, sondern wird zu 0 (harmlos, weil 0
  // ohnehin im erlaubten Bereich liegt, aber die vorherige Formulierung
  // behauptete faelschlich das Gegenteil). recentCount hatte den
  // urspruenglichen Fehler ("|| 24") nie beobachtbar, weil sein Standard
  // selbst 0 ist -- trotzdem derselbe Helfer, damit die beiden Werte nicht
  // wieder auseinanderlaufen.
  function numOrDefault(raw, fallback) {
    var n = Number(raw)
    return isFinite(n) ? n : fallback
  }

  readonly property string barLabelMode: String(root.setting("barLabel", "Icon"))

  // Anzahl der laufenden opencode-Fenster, fuer den "Running count"-Modus.
  // Eigene Property statt Inline-Ausdruck: sie wird an zwei Stellen
  // gebraucht (Sichtbarkeit und Zahlentext des Zaehlers), und ein Filter
  // ueber root.projects gehoert nicht zweimal in die View.
  readonly property int runningWindowCount:
    root.projects.filter(function (p) { return p.running }).length

  // Stellschrauben fuer das Bar-Icon: Strichstaerke in Pixeln (die Marke ist
  // 4 Striche breit und 5 hoch) und Deckkraft des inneren Blocks.
  readonly property int markStroke: 2
  readonly property real markBlockOpacity: 0.5

  readonly property int recentCount:
    Math.max(0, Math.min(50, root.numOrDefault(root.setting("recentCount", 5), 0)))
  readonly property int refreshHours:
    Math.max(0, Math.min(720, root.numOrDefault(root.setting("catalogRefreshHours", 24), 24)))
  readonly property bool confirmNewWindow: root.setting("confirmNewWindow", false) === true

  // Die Einstellungen erreichen die Skripte als Umgebungszuweisung vor dem
  // Befehl. Beide Werte sind oben auf Zahlen eingeschraenkt.
  readonly property string envPrefix:
    "OC_RECENT_COUNT=" + root.recentCount + " OC_REFRESH_HOURS=" + root.refreshHours + " "

  // Quality: waehrend ein Start oder ein Store-Schreibzugriff laeuft,
  // sperren die Zeilen (Klick, Stern, Chevron) -- wie im Schwesterplugin
  // smartalb.vpn. Verhindert auch, dass ein zweiter, schneller Klick eine
  // laufende Process-Zuweisung ueberschreibt, waehrend die erste noch nicht
  // beendet ist (bekannte Einschraenkung aus dem Vorgaengerbericht).
  readonly property bool busy: launchProc.running || storeProc.running

  // C3: bis hierher wanderte "data.error" ROH in loadError -- im Panel
  // stand dann woertlich "state-not-a-file" oder "config-invalid". Dieselbe
  // Uebersetzungstabelle, die ModelSheet.qml fuer die Modell-Codes schon
  // hat. Der Config-Pfad wird bei den Config-Fehlern mitgenannt: das ist
  // die einzige Datei in dieser Liste, die der Benutzer selbst schreibt --
  // ohne den Pfad weiss er nicht, wo er nachsehen soll.
  readonly property string configPath: "~/.config/omarchy/opencode-launcher.json"
  function projectsErrorText(code) {
    if (code === "opencode-missing") return "opencode is not installed or not executable"
    if (code === "config-invalid") return "The pinned projects in " + root.configPath
      + " have the wrong shape: \"projects\" must be a list, and every entry needs a \"path\". "
      + "README.md has a minimal example."
    if (code === "config-unreadable") return "The pinned projects in " + root.configPath + " are not valid JSON"
    if (code === "config-too-large") return "The pinned projects in " + root.configPath + " are too large to read"
    if (code === "state-not-a-file") return "This plugin's state path is not a regular file (a symlink, perhaps)"
    if (code === "state-invalid") return "This plugin's state file is damaged"
    if (code === "state-schema-unknown") return "This plugin's state file was written by a newer version"
    if (code === "state-too-large") return "This plugin's state file has grown too large"
    if (code === "cache-not-a-file") return "The model cache path is not a regular file (a symlink, perhaps)"
    if (code === "cache-too-large") return "The model cache has grown too large"
    return "Project list not readable"
  }

  Process {
    id: projectsProc
    running: true
    command: root.runnerOut(root.envPrefix + root.scriptCmd("omarchy-opencode-projects") + " list --json")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.trim() === "") { root.projects = []; root.loadError = root.projectsErrorText(""); return }
        try {
          var data = JSON.parse(raw)
          if (Array.isArray(data)) { root.projects = data; root.loadError = "" }
          else { root.projects = []; root.loadError = root.projectsErrorText(String((data && data.error) || "")) }
        } catch (e) { root.projects = []; root.loadError = root.projectsErrorText("") }
      }
    }
  }

  // W1 (Fix Runde 1): "error" wurde bisher nie gelesen. Mit source: "none"
  // zeigte der Picker eine leere Liste PLUS die Meldung "Liste aus dem
  // Zwischenspeicher" -- eine Behauptung ueber einen Zwischenspeicher, der
  // in diesem Fall gar nicht existiert. bin/omarchy-opencode-models setzt
  // "error" immer zusammen mit "models: []"; ModelSheet.statusText
  // uebersetzt den Code in eine Meldung, die den tatsaechlichen Grund
  // nennt. "source" selbst wurde in Runde 1 zusaetzlich durchgereicht,
  // aber nie gelesen: "error" (welcher Fehler) und "stale" (frisch oder
  // aus dem Zwischenspeicher) decken zusammen bereits jeden Fall ab, den
  // "source" haette unterscheiden koennen -- in Runde 2 deshalb wieder
  // entfernt statt eine zweite, ungenutzte Wahrheitsquelle zu pflegen.
  Process {
    id: modelsProc
    command: root.runnerOut(root.envPrefix + root.scriptCmd("omarchy-opencode-models") + " list --json")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        try {
          var d = JSON.parse(raw === "" ? "{}" : raw)
          root.models = Array.isArray(d.models) ? d.models : []
          root.modelsStale = d.stale === true
          root.modelsError = String(d.error || "")
        } catch (e) {
          root.models = []
          root.modelsStale = true
          root.modelsError = "panel-parse-error"
        }
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
    onExited: {
      if (root.storeAction === "star") {
        // G2 (Fix Runde 2): OHNE "--refresh" liest dieser Aufruf bei einem
        // noch frischen Zwischenspeicher denselben "starred"-Stand zurueck,
        // den der Klick gerade aendern sollte -- der Stern haette dann bis
        // zum naechsten Aktualisieren gelogen, und ein zweiter Klick haette
        // "star" ein zweites Mal statt "unstar" gesendet (siehe der
        // Kommentar bei "storeAction" oben).
        modelsProc.running = false
        modelsProc.command = root.runnerOut(root.envPrefix + root.scriptCmd("omarchy-opencode-models") + " list --json --refresh")
        modelsProc.running = true
      } else {
        projectsProc.running = false
        projectsProc.running = true
      }
    }
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
    onExited: {
      projectsProc.running = false
      projectsProc.running = true
    }
  }

  function openProject(entry, newWindow) {
    // Fix Runde 2: "root.busy" statt nur "launchProc.running" -- die
    // Tastatur (Enter/Umschalt+Enter) war bisher waehrend eines laufenden
    // Store-Schreibzugriffs (Modell setzen, Stern umschalten) NICHT
    // gesperrt, obwohl die Maus es schon war (rowMouse/chipMouse binden
    // "enabled" bereits an "!root.busy"). Ein schneller Enter waehrend
    // dieses Fensters haette mit dem VOR dem Schreiben gueltigen Modell
    // gestartet.
    if (!entry || entry.exists === false || root.busy) return
    var c = root.scriptCmd("omarchy-opencode-launch") + " " + root.shellEscape(entry.path)
    if (entry.model) c += " --model " + root.shellEscape(entry.model)
    if (newWindow) c += " --new-window"
    root.launchError = ""
    launchProc.running = false
    launchProc.command = root.runnerErr(c)
    launchProc.running = true
  }

  function setModel(path, id) {
    // Fix Runde 2: ein leerer Pfad ist nie ein gueltiges Ziel -- ohne diese
    // Wache schriebe ein (heute nicht vorkommender, aber nicht
    // ausgeschlossener) leerer sheetPath in ".projects['']".
    if (!path || storeProc.running) return
    root.storeAction = "model"
    var c = id === ""
      ? root.scriptCmd("omarchy-opencode-store") + " unset " + root.shellEscape(path)
      : root.scriptCmd("omarchy-opencode-store") + " set " + root.shellEscape(path)
        + " " + root.shellEscape(id)
    storeProc.running = false
    storeProc.command = root.runnerErr(c)
    storeProc.running = true
  }

  // G2: der Picker zeichnete einen Stern, aber keine Stelle rief je
  // "store star|unstar" auf.
  function findModel(id) {
    for (var i = 0; i < root.models.length; i++) if (root.models[i].id === id) return root.models[i]
    return null
  }

  function toggleStar(id, currentlyStarred) {
    if (storeProc.running) return
    root.storeAction = "star"
    var c = root.scriptCmd("omarchy-opencode-store") + " " + (currentlyStarred ? "unstar" : "star")
      + " " + root.shellEscape(id)
    storeProc.running = false
    storeProc.command = root.runnerErr(c)
    storeProc.running = true
  }

  // C11: EIN Neustart-Idiom fuer jeden erneuten Lauf mit geaenderten
  // Argumenten -- erst "running = false", dann (falls noetig) das neue
  // "command", dann "running = true". Zwei Idiome standen bisher
  // nebeneinander, und nur dieses ist richtig: "running = true" auf einem
  // NOCH LAUFENDEN Process tut nichts, ein direkt davor zugewiesenes
  // "command" waere also stillschweigend verloren. Absichtlich als
  // ausgeschriebene Zeilen an jeder Stelle statt als Hilfsfunktion: die
  // Regel test_kein_prozessstart_ausserhalb_der_helfer in test/qml.test.sh
  // verlangt, dass JEDE Zuweisung an die Kommando-Eigenschaft den
  // runner-Helfer auf derselben Zeile nennt -- eine zentrale Funktion, die
  // sie aus einem Parameter belegt, wuerde diese Regel aushebeln, statt sie
  // zu erfuellen. (Und ja, dieser Kommentar darf die Eigenschaft deshalb
  // nicht woertlich schreiben: die Regel liest Text, nicht Bedeutung.)
  //
  // Nicht betroffen sind die beiden Stellen, die bewusst nur STARTEN, wenn
  // nichts laeuft (onOpenedChanged, openSheetFor): dort ist "nicht neu
  // starten" die Absicht, kein Versehen.
  function refreshAll() {
    root.launchError = ""
    root.disarmConfirm()
    projectsProc.running = false
    projectsProc.running = true
    modelsProc.running = false
    modelsProc.command = root.runnerOut(root.envPrefix + root.scriptCmd("omarchy-opencode-models")
      + " list --json --refresh")
    modelsProc.running = true
  }

  function openSheetFor(path) {
    root.sheetPath = path
    if (root.models.length === 0) modelsProc.running = true
    sheet.visible = true
  }

  // C2 (Fix Runde 1, zweiter Teil): schliesst der Picker nicht auch beim
  // Schliessen des Panels (Aussenklick, Klick auf ein anderes Bar-Icon,
  // IPC "close"), bleibt "sheetPath" auf dem alten Projekt stehen -- beim
  // naechsten Oeffnen erschiene der Picker ueber dem FALSCHEN Projekt.
  // sheetPath wird deshalb hier, nicht erst beim naechsten openSheetFor(),
  // zurueckgesetzt.
  function closeSheet() {
    sheet.visible = false
    root.sheetPath = ""
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  readonly property bool listCapped:
    root.projects.length > 0 && root.projects[0].capped === true

  // Beim Oeffnen des Panels einen frischen Stand holen: der Laufzustand
  // (welches Projekt gerade laeuft) veraendert sich zwischen zwei Oeffnungen.
  //
  // C2 (Fix Runde 1): der else-Zweig ist neu -- ein Panel, das schliesst,
  // muss den Picker mitschliessen (siehe closeSheet()) und eine noch
  // scharfe Zweites-Fenster-Bestaetigung zuruecknehmen, sonst wirkt ein
  // Umschalt+Eingabetaste nach dem Wiederoeffnen auf ein Projekt, das der
  // Benutzer laengst nicht mehr vor Augen hat.
  onOpenedChanged: {
    if (root.opened) {
      root.launchError = ""
      if (!projectsProc.running) projectsProc.running = true
    } else {
      root.closeSheet()
      root.disarmConfirm()
    }
  }

  // The opencode logomark: the blocky "o" from the official wordmark, redrawn
  // as rectangles instead of shipping a bitmap. Two reasons: it stays crisp at
  // any bar size, and it takes the bar's foreground colour like every other
  // icon rather than pasting a black tile into the bar.
  //
  // The official favicon is built entirely from one unit -- its 64-unit stroke
  // on a 512 grid. In those terms the mark is 4 strokes wide and 5 tall, the
  // opening is 2x3, and the counter block is 2x2 sitting at the bottom of the
  // opening. Deriving every dimension from an integer stroke keeps all four
  // edges on whole pixels; computing them independently and rounding lets the
  // block grow wider than the opening at bar size, which smears the lower half
  // into a blob.
  Component {
    id: opencodeMark

    Item {
      id: mark

      // Stroke in pixels. 2 keeps the official proportions legible at the
      // bar's 16px icon canvas; 3 fills more of the slot but reads heavy.
      readonly property int s: root.markStroke
      readonly property color markColor: root.barForeground

      Item {
        anchors.centerIn: parent
        width: mark.s * 4
        height: mark.s * 5

        // The ring, drawn as four bars so the opening is exactly 2s x 3s.
        Rectangle { width: parent.width; height: mark.s; anchors.top: parent.top; color: mark.markColor }
        Rectangle { width: parent.width; height: mark.s; anchors.bottom: parent.bottom; color: mark.markColor }
        Rectangle { width: mark.s; height: parent.height; anchors.left: parent.left; color: mark.markColor }
        Rectangle { width: mark.s; height: parent.height; anchors.right: parent.right; color: mark.markColor }

        // Counter block: fills the opening's width and its lower two thirds.
        Rectangle {
          x: mark.s
          y: mark.s * 2
          width: mark.s * 2
          height: mark.s * 2
          color: mark.markColor
          opacity: root.markBlockOpacity
        }
      }
    }
  }

  // iconRow statt eines einzelnen anchors.fill-Buttons: BarIconButton kann
  // Icon und Text nicht zugleich zeigen (siehe zwei Schwesterwidgets fuer
  // dieselbe Erkenntnis), UND sein fixedWidth ist fest auf slotSize genagelt
  // -- ein an "text" angehaengter Zaehler wuerde also nie Platz bekommen und
  // liefe bestenfalls unsichtbar, schlimmstenfalls abgeschnitten mit
  // benachbarten Widgets ueberlappend. Der Zaehler ist deshalb ein eigenes
  // Text-Element neben dem Button; implicitWidth des Panels haengt jetzt an
  // iconRow (das unsichtbare Kinder von seiner Breitenrechnung ausnimmt), also
  // bleibt der Icon-Modus exakt so schmal wie zuvor.
  implicitWidth: iconRow.implicitWidth
  implicitHeight: iconRow.implicitHeight

  Row {
    id: iconRow
    anchors.centerIn: parent
    spacing: Style.spacing.xs

    BarIconButton {
      id: button
      bar: root.bar
      iconComponent: opencodeMark
      slotSize: Style.bar.statusSlot
      fontSize: Style.font.caption
      tooltipText: "opencode Launcher"
      // Nur Links- und Mittelklick sind belegt. Das von WidgetButton geerbte
      // Mausrad-Signal bleibt hier absichtlich unverbunden: ein Scrollen ueber
      // der Bar darf keinen Start und keine Aenderung ausloesen.
      onPressed: function (b) {
        if (b === Qt.MiddleButton) root.refreshAll()
        else root.toggle()
      }
    }

    Text {
      id: countLabel
      visible: root.barLabelMode === "Running count"
      anchors.verticalCenter: parent.verticalCenter
      text: String(root.runningWindowCount)
      color: root.barForeground
      font.family: root.fontFam
      font.pixelSize: Style.font.caption
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
    // Quality (Fix Runde 1): die Hoehe kam bisher NUR aus der Projektliste
    // (panelColumn.implicitHeight) -- bei einem einzigen Projekt war der
    // geoeffnete Picker dadurch nur ein paar Pixel hoch, weil die Zeilen
    // des Pickers selbst nichts zur Hoehe des Panels beitrugen. sheet.
    // minHeight ist die vom Picker selbst verlangte Mindesthoehe.
    contentHeight: panel.fittedContentHeight(
      sheet.visible ? Math.max(panelColumn.implicitHeight, sheet.minHeight) : panelColumn.implicitHeight,
      Style.space(480))

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
        // C2 (Fix Runde 1): zusaetzliche, explizite Absicherung neben dem
        // Fokuswechsel in ModelSheet.onVisibleChanged (siehe dort). Ein
        // Tastendruck darf NIE hier ankommen, solange der Picker offen ist
        // -- egal ob der Fokus schon umgezogen ist oder (im theoretischen
        // Fall eines verzoegerten Qt.callLater) noch nicht.
        if (sheet.visible) { e.accepted = false; return }
        var list = root.projects
        if (e.key === Qt.Key_Down) {
          root.disarmConfirm()
          root.cursor = Math.min(root.cursor + 1, list.length - 1); e.accepted = true
        }
        else if (e.key === Qt.Key_Up) {
          root.disarmConfirm()
          root.cursor = Math.max(root.cursor - 1, 0); e.accepted = true
        }
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
          var entry = list[root.cursor]
          var second = (e.modifiers & Qt.ShiftModifier) !== 0
          // C3 (Fix Runde 1): echte einmalige Bestaetigung statt eines
          // Zustands, der beim zweiten Umschalt+Eingabetaste denselben Zweig
          // erneut nimmt. Scharf ist die Bestaetigung nur fuer GENAU das
          // Projekt, das beim ersten Mal gemeint war (confirmArmedPath) --
          // ein Cursorwechsel dazwischen (siehe oben, disarmConfirm())
          // nimmt sie zurueck.
          if (second && root.confirmNewWindow) {
            if (entry && root.confirmArmedPath === entry.path) {
              root.disarmConfirm()
              root.openProject(entry, true)
            } else if (entry) {
              root.armConfirm(entry.path)
            }
          } else {
            root.disarmConfirm()
            root.openProject(entry, second)
          }
          e.accepted = true
        }
        else if (e.key === Qt.Key_M) {
          root.disarmConfirm()
          if (list[root.cursor]) root.openSheetFor(list[root.cursor].path); e.accepted = true
        }
        else if (e.key === Qt.Key_R) { root.disarmConfirm(); root.refreshAll(); e.accepted = true }
        else if (e.key === Qt.Key_Escape) {
          root.disarmConfirm()
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

          // W4 (Fix Runde 1): manifest.json und README sprachen von "dem
          // Aktualisieren-Knopf im Panel" -- den gab es nicht, nur den
          // unsichtbaren Mittelklick auf das Bar-Icon und die Taste "r".
          // Jetzt gibt es ihn wirklich, neben der Ueberschrift.
          Item {
            id: headerRow
            width: panelColumn.width
            height: Math.max(header.implicitHeight, refreshButton.implicitHeight)

            PanelSectionHeader {
              id: header
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "OPENCODE"
              foreground: root.barForeground
              fontFamily: root.fontFam
            }

            PanelActionButton {
              id: refreshButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              // nf-fa-refresh, im Basic Multilingual Plane -- anders als
              // der Roboter oben passt der Codepunkt in EIN \u-Escape,
              // ohne Ersatzpaar.
              iconText: "\uF021"
              tooltipText: "Refresh the list"
              foreground: root.barForeground
              fontFamily: root.fontFam
              enabled: !projectsProc.running && !modelsProc.running
              onClicked: root.refreshAll()
            }
          }

          Text {
            width: panelColumn.width
            visible: root.loadError !== ""
            text: root.loadError
            color: root.barForeground
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            width: panelColumn.width
            visible: root.launchError !== ""
            text: root.launchError
            color: root.barForeground
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Text {
            width: panelColumn.width
            visible: root.confirmHint !== ""
            text: root.confirmHint
            color: root.barForeground
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            opacity: 0.85
            wrapMode: Text.WordWrap
          }
          Text {
            width: panelColumn.width
            visible: root.listCapped
            text: "List capped at 200 projects"
            color: root.barForeground
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            opacity: 0.7
            wrapMode: Text.WordWrap
          }
          // G4: eine leere Liste ohne Fehler zeigte bisher nur die
          // Ueberschrift -- keine Erklaerung und kein Hinweis, wo
          // angeheftete Projekte ueberhaupt eingetragen werden.
          Text {
            width: panelColumn.width
            visible: root.loadError === "" && root.projects.length === 0 && !projectsProc.running
            // C7: die Datei zu NENNEN half niemandem, der nicht weiss, was
            // hineingehoert -- README.md hat jetzt ein Minimalbeispiel, und
            // diese Zeile verweist darauf.
            text: "No projects yet. Pinned projects go in " + root.configPath
              + " (README.md has a minimal example); recently used ones are added "
              + "automatically from opencode."
            color: root.barForeground
            font.family: root.fontFam
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
              // G3: der Tastatur-Cursor (root.cursor, treibt Enter/"m"/
              // Umschalt+Enter) war bisher unsichtbar -- nur Maus-Hover
              // zeigte etwas. Jetzt hat die per Tastatur markierte Zeile
              // eine eigene, von Hover unterscheidbare Farbe.
              color: index === root.cursor
                ? Style.selectedFill
                : ((rowMouse.containsMouse && modelData.exists && !root.busy) ? Style.hoverFill : "transparent")
              opacity: (modelData.exists === false || root.busy) ? 0.45 : 1.0

              Column {
                id: rowColumn
                anchors.left: parent.left
                anchors.right: modelChip.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(2)

                // G5: Name und Pfad standen bisher als zwei Zeilen
                // uebereinander, obwohl beide fuer jedes automatisch
                // aufgenommene Projekt denselben Text zeigten -- das
                // Skript setzt "name" nur dann auf den abgekuerzten Pfad,
                // wenn die Config keinen eigenen Namen liefert. Jetzt gibt
                // es nur noch diese eine Zeile: einen echten Namen (kurz,
                // elidiert praktisch nie) oder, wenn keiner da ist, den
                // abgekuerzten Pfad. ElideLeft statt ElideRight, damit bei
                // langen Pfaden das ENDE erhalten bleibt (der aussagekraeftige
                // Teil) und die Ellipse vorne sitzt; der volle, absolute Pfad
                // (nicht die Tilde-Form) steht im Hover-Tooltip auf rowMouse.
                Text {
                  width: parent.width
                  text: (modelData.running ? "\u25CF  " : "\u25CB  ")
                    + (modelData.name !== modelData.displayPath ? modelData.name : modelData.displayPath)
                  color: root.barForeground
                  font.family: root.fontFam
                  font.pixelSize: Style.font.body
                  elide: Text.ElideLeft
                }
              }

              // G5: derselbe PanelToolTip-auf-eigener-MouseArea wie bei
              // PanelActionButton (siehe /usr/share/omarchy/shell/Ui/
              // PanelActionButton.qml) -- an rowMouse gehaengt statt an
              // eine zweite MouseArea. modelData.path, nicht der oben
              // gezeigte abgekuerzte Pfad -- "voll" meint die absolute
              // Form. Dieselbe Kombination -- PanelToolTip in
              // einer clip:true-Liste -- traegt bereits die Bluetooth- und
              // Netzwerk-Panels der Shell (deren "Forget"-Knopf-Tooltip
              // sitzt genauso in einem geclippten ListView/Flickable ohne
              // Sonderbehandlung); Popups laufen ueber den Window-Overlay
              // und nicht ueber den normalen, geclippten Item-Baum.
              PanelToolTip {
                visible: rowMouse.containsMouse
                text: modelData.path
                fontFamily: root.fontFam
              }

              // W3 (Fix Runde 1): der Chevron war reiner Text INNERHALB der
              // Zeile -- ein Klick darauf traf die Zeile und startete
              // opencode, statt den Picker zu oeffnen. Jetzt ist er ein
              // eigenstaendiges Steuerelement mit eigener Trefferflaeche
              // (z:1, ueber der Zeilen-MouseArea).
              Rectangle {
                id: modelChip
                z: 1
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: Style.space(6)
                radius: Style.cornerRadius
                color: (chipMouse.containsMouse && !root.busy) ? Style.hoverFill : "transparent"
                implicitWidth: chipText.implicitWidth + Style.space(12)
                implicitHeight: chipText.implicitHeight + Style.space(6)

                Text {
                  id: chipText
                  anchors.centerIn: parent
                  text: (modelData.modelLabel
                          ? modelData.modelLabel + (modelData.modelKnown === false ? " (?)" : "")
                          : "Default") + "  \u2304"
                  color: root.barForeground
                  font.family: root.fontFam
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: !root.busy
                  enabled: !root.busy
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.disarmConfirm()
                    root.cursor = index
                    root.openSheetFor(modelData.path)
                  }
                }
              }

              MouseArea {
                id: rowMouse
                z: 0
                anchors.fill: parent
                hoverEnabled: !root.busy
                enabled: !root.busy
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: modelData.exists ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: function (e) {
                  root.disarmConfirm()
                  root.cursor = index
                  if (e.button === Qt.RightButton) root.openSheetFor(modelData.path)
                  else if (modelData.exists) root.openProject(modelData, false)
                }
              }
            }
          }

          // C6: Spezifikation 4 sah eine Fusszeile vor ("Enter oeffnen,
          // m Modell"), und keine gab es -- "m", "r", "*", Esc, die
          // Pfeiltasten und der Rechtsklick auf eine Zeile waren nirgends
          // im Programm zu entdecken; die README nannte nur Shift+Enter.
          // Unter der Liste, nicht darueber: die Liste ist der Inhalt, die
          // Legende die Randnotiz. Sichtbar nur, solange ueberhaupt Zeilen
          // da sind -- eine Tastenlegende ohne Zeilen, auf die sie sich
          // beziehen koennte, waere Zierrat.
          //
          // Pfeile und Trennpunkte als \u-Escapes, wie der Roboter und der
          // Chevron oben: eine Glyphe direkt in der Datei geht beim
          // Kopieren durch Werkzeuge verloren.
          Text {
            width: panelColumn.width
            visible: root.projects.length > 0
            text: "\u2191\u2193 move  \u00B7  Enter open  \u00B7  Shift+Enter new window"
              + "  \u00B7  m or right-click model  \u00B7  r refresh  \u00B7  Esc close"
            color: root.barForeground
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            opacity: 0.55
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    ModelSheet {
      id: sheet
      anchors.fill: parent
      models: root.models
      stale: root.modelsStale
      errorCode: root.modelsError
      busy: storeProc.running
      fg: root.barForeground
      fontFam: root.fontFam
      onPicked: function (id) { root.setModel(root.sheetPath, id); root.closeSheet() }
      onCleared: { root.setModel(root.sheetPath, ""); root.closeSheet() }
      onClosed: root.closeSheet()
      onStarToggled: function (id) {
        var m = root.findModel(id)
        root.toggleStar(id, !!(m && m.starred))
      }
    }
  }
}
