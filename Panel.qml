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

  // G6: die Namenszeile zeigt fuer Projekte ohne echten Namen den
  // abgekuerzten Pfad -- der konnte trotzdem so lang werden, dass
  // ElideLeft (unten am Text) fast staendig zuschlug. shortPath() kuerzt
  // schon vorher auf die letzten drei Segmente; ElideLeft bleibt als
  // zweites Netz fuer den Fall, dass selbst drei Segmente die Zeile noch
  // sprengen. Ein Segment ist ein "/"-getrennter Teil, das fuehrende "~"
  // zaehlt als eines mit -- "~/a/b/c/d" hat fuenf, die letzten drei
  // ueberleben. Ein echter Name (siehe Aufrufstelle) laeuft NIE hier
  // durch: der wird nie gekuerzt. Das Auslassungszeichen steht als
  // \u-Escape im Code (nicht als rohes Byte): dieses Projekt verbietet
  // Nicht-ASCII-Bytes in QML.
  //
  // Absoluter Pfad ohne Tilde ("/srv/work/api"): der erste "/" erzeugt
  // beim Split ein leeres Fuehrungssegment, das nach Regel 1 mitzaehlt
  // ("/srv/work/api" hat vier Segmente). Sichtbar wird dieses leere
  // Segment nie: slice(-3) nimmt ohnehin nur die letzten drei echten
  // Teile, und nur wenn segs.length <= 3 ist (das leere Segment selbst
  // unter den letzten drei), greift der fruehe Rueckgabezweig und liefert
  // den Pfad unveraendert -- dann bleibt genau ein Schraegstrich vorn
  // stehen, nie zwei hintereinander nach dem Auslassungspraefix.
  //
  // Ein schliessender Schraegstrich ("a/b/c/") wuerde ein leeres LETZTES
  // Segment erzeugen; das Feld aus dem Skript kommt nie so an, aber die
  // Funktion bleibt robust und schneidet einen einzelnen schliessenden
  // Slash vor dem Split ab, damit kein leeres Segment mitzaehlt.
  function shortPath(p) {
    return root.segmentsAtMost(p, 3)
  }

  // G8 (Fix nach Screenshot-Fund): shortPath() kappt zuverlaessig auf
  // hoechstens drei Segmente, aber wenn selbst DAS noch nicht in die Zeile
  // passt, schlug bisher ElideLeft mitten in einem Segment zu -- ein
  // dreisegmentiger Konfigurationspfad wurde so zu "\u2026nfig/opencode",
  // einer bedeutungslosen Zeichenkette, statt ein ganzes Segment
  // wegzulassen. Die Behebung wirft ab jetzt GANZE Segmente von links weg,
  // bevor ElideLeft ueberhaupt zum Zug kommt.
  //
  // segmentsAtMost(p, n) ist dieselbe Rechenregel wie shortPath() oben,
  // nur mit einer variablen Stufe n statt der fest verdrahteten 3 --
  // shortPath(p) ist nichts anderes als segmentsAtMost(p, 3). Eigene
  // Funktion statt Inline-Code an der Aufrufstelle, weil pathCandidates()
  // unten dieselbe Rechenregel dreimal braucht (n = 3, 2, 1).
  function segmentsAtMost(p, n) {
    var s = (p.length > 1 && p.endsWith("/")) ? p.slice(0, -1) : p
    var segs = s.split("/")
    if (segs.length <= n) return p
    return "\u2026/" + segs.slice(-n).join("/")
  }

  // Die Kandidatenleiter fuer eine zu schmale Zeile: von drei Segmenten
  // (identisch mit shortPath(p)) ueber zwei bis zu einem einzigen, jede
  // Stufe mit dem "\u2026/"-Praefix, sobald dabei tatsaechlich etwas
  // abgeschnitten wurde. Zwei aufeinanderfolgende Stufen liefern denselben
  // Text, wenn der Pfad gar nicht so viele Segmente hat, dass bei DIESER
  // Stufe schon etwas wegfiele -- "~/foo" hat nur zwei Segmente: die
  // Drei-Segment-Stufe UND die Zwei-Segment-Stufe sind beide der
  // unveraenderte Pfad. Solche Duplikate werden herausgefiltert, sonst
  // bekaeme ein zweisegmentiger Pfad eine "Drei-Segment"-Kandidatin, die es
  // inhaltlich gar nicht gibt (siehe test_pfadleiter_kandidaten unten). Ein
  // einzelnes Segment liefert immer nur einen einzigen Eintrag: da gibt es
  // nichts mehr wegzuwerfen.
  function pathCandidates(p) {
    var out = []
    for (var n = 3; n >= 1; n--) {
      var c = root.segmentsAtMost(p, n)
      if (out.length === 0 || out[out.length - 1] !== c) out.push(c)
    }
    return out
  }

  // Waehlt aus pathCandidates() die BREITESTE Kandidatin, die noch in
  // availableWidth passt -- gemessen mit dem TextMetrics-Element, das die
  // Aufrufstelle uebergibt. Dieses TextMetrics muss dieselbe Schrift
  // tragen wie das Label, sonst misst es eine andere Breite als die, die
  // tatsaechlich gerendert wird (siehe pathMetrics an der Aufrufstelle
  // unten: font.family und font.pixelSize sind woertlich dieselben wie am
  // Label). Passt selbst die letzte Kandidatin (ein einzelnes Segment)
  // nicht, bleibt nichts mehr zum Wegwerfen -- fitPath() liefert sie
  // trotzdem zurueck, und ElideLeft an der Text-Eigenschaft selbst (siehe
  // rowLine unten) bleibt als letztes Netz stehen und schneidet in diesem
  // einen verbleibenden Fall mitten im Zeichen ab.
  function fitPath(p, availableWidth, metrics) {
    var candidates = root.pathCandidates(p)
    for (var i = 0; i < candidates.length; i++) {
      metrics.text = candidates[i]
      if (metrics.advanceWidth <= availableWidth) return candidates[i]
    }
    return candidates[candidates.length - 1]
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

  // G7 (Gruppierung nach Anbieter im Picker): "modelId" ist das fuer DIESES
  // Projekt gemerkte Modell (modelData.model an der Aufrufstelle, leer/
  // undefined, wenn keines gemerkt ist) -- der Picker selbst kennt den
  // aktuellen Stand nicht, er bekommt ihn hier gereicht. sheet.
  // onVisibleChanged (siehe ModelSheet.qml) klappt daraus genau die Gruppe
  // auf, die dieses Modell traegt.
  function openSheetFor(path, modelId) {
    root.sheetPath = path
    sheet.currentModel = modelId || ""
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
          if (list[root.cursor]) root.openSheetFor(list[root.cursor].path, list[root.cursor].model); e.accepted = true
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
                // elidiert praktisch nie, NIE gekuerzt) oder, wenn keiner
                // da ist, der Pfad-Fallback -- der laeuft durch
                // root.fitPath() (siehe dort, G8) und waehlt die breiteste
                // der hoechstens drei Kandidaten (drei/zwei/ein Segment),
                // die noch in die verfuegbare Breite passt. ElideLeft
                // bleibt zusaetzlich stehen (statt ElideRight) als
                // allerletztes Netz, falls selbst ein einzelnes Segment
                // noch nicht passt -- REGEL, NICHT DEKORATION: sie ist die
                // einzige Absicherung fuer genau diesen Grenzfall, ihr
                // Entfernen faellt in test_projektzeile_elidiert_links auf.
                // Der volle, absolute Pfad (nicht die Tilde-Form, nicht
                // gekuerzt) steht im Hover-Tooltip auf rowMouse.
                // Marker und Beschriftung sind ZWEI Texte, nicht einer:
                // ElideLeft kuerzt von links, und in einer gemeinsamen
                // Zeichenkette stand der Kringel genau dort -- bei einer zu
                // breiten Zeile verschwand also zuerst die Laufanzeige.
                // Getrennt kann nur noch der Pfad elidiert werden.
                Row {
                  id: rowLine
                  width: parent.width

                  // G9 (Fix Runde 2 -- Bindungsschleife im Shell-Log
                  // gefunden, 369 Warnungen "Binding loop detected for
                  // property text" nach dem Neustart der Shell): der
                  // vorherige Kommentar an dieser Stelle argumentierte,
                  // ein Schreibzugriff auf ein FREMDES Element (pathMetrics)
                  // waehrend der Auswertung dieser "text"-Bindung sei
                  // unbedenklich, weil es keine erneute Auswertung
                  // DERSELBEN Bindung braucht. Das war falsch: fitPath()
                  // schrieb pathMetrics.text und las danach
                  // pathMetrics.advanceWidth -- der Lesezugriff macht
                  // advanceWidth zu einer Abhaengigkeit DIESER "text"-
                  // Bindung, und der vorangegangene Schreibzugriff
                  // veraendert genau diese Abhaengigkeit WAEHREND die
                  // Bindung noch laeuft. Das ist die Schleife, die Qt
                  // gemeldet hat -- sie braucht keine Rekursion in dieselbe
                  // Bindung, nur eine sich selbst aendernde Abhaengigkeit
                  // waehrend der eigenen Auswertung. Und weil pathMetrics
                  // EIN gemeinsames Element fuer alle Zeilen war, machte
                  // der Schreibzugriff einer Zeile die Bindung JEDER
                  // ANDEREN Zeile ungueltig -- daher 369 statt einer
                  // Warnung.
                  //
                  // Behebung: die Messung findet nicht mehr INNERHALB
                  // einer Bindung statt. "fittedPath" ist eine gewoehnliche
                  // Eigenschaft (ein imperativ zugewiesener Wert, kein
                  // Bindungsausdruck) -- refreshFittedPath() schreibt sie
                  // aus einem Signal-Handler heraus (onWidthChanged,
                  // Component.onCompleted), nie aus einer Bindung. Das
                  // Label unten bindet an "rowLine.fittedPath", nicht mehr
                  // an einen fitPath()-Aufruf selbst: "fittedPath" haengt
                  // fuer die "text"-Bindung von nichts ab, das sich waehrend
                  // ihrer eigenen Auswertung aendert, also gibt es keine
                  // Schleife mehr. Schreibzugriffe auf das gemeinsame
                  // pathMetrics bleiben unbedenklich, weil sie ausschliesslich
                  // in refreshFittedPath() passieren -- also ausserhalb jeder
                  // Bindung.
                  property string fittedPath: ""

                  function refreshFittedPath() {
                    rowLine.fittedPath = root.fitPath(modelData.displayPath, rowLine.width - rowMarker.width, pathMetrics)
                  }

                  onWidthChanged: rowLine.refreshFittedPath()
                  Component.onCompleted: rowLine.refreshFittedPath()

                  Text {
                    id: rowMarker
                    text: modelData.running ? "\u25CF  " : "\u25CB  "
                    color: root.barForeground
                    font.family: root.fontFam
                    font.pixelSize: Style.font.body
                    onWidthChanged: rowLine.refreshFittedPath()
                  }

                  // G8: dieselbe Schrift wie das Label darunter -- eine
                  // TextMetrics mit einer anderen Familie/Groesse misst
                  // eine Breite, die mit der tatsaechlich gerenderten
                  // nichts zu tun hat, und fitPath() waehlt dann anhand
                  // einer bedeutungslosen Zahl. Rein rechnerisches Element
                  // ohne eigene Flaeche -- als Kind eines Row ohne Wirkung
                  // auf dessen Layout. Ein einzelnes, geteiltes Element fuer
                  // alle Zeilen ist hier unbedenklich (siehe G9 oben): es
                  // wird nur noch ausserhalb jeder Bindung beschrieben.
                  TextMetrics {
                    id: pathMetrics
                    font.family: root.fontFam
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    width: rowLine.width - rowMarker.width
                    text: (modelData.name !== modelData.displayPath ? modelData.name : rowLine.fittedPath)
                    color: root.barForeground
                    font.family: root.fontFam
                    font.pixelSize: Style.font.body
                    elide: Text.ElideLeft
                  }
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
                    root.openSheetFor(modelData.path, modelData.model)
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
                  if (e.button === Qt.RightButton) root.openSheetFor(modelData.path, modelData.model)
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
            // Nur die vier haeufigsten Tasten. Die vollstaendige Tabelle steht
            // im README ("Keys and clicks"); eine Fusszeile, die alles auffuehrt,
            // brach auf zwei Zeilen um und kostete mehr Hoehe als sie half.
            text: "\u2191\u2193  \u00B7  Enter  \u00B7  m  \u00B7  Esc"
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
