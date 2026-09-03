import QtQuick
import qs.Commons
import qs.Ui

// Modell-Picker. Kennt keine Prozesse: er meldet die Auswahl nach oben und
// das Panel schreibt sie. Ein Picker, der selbst startet, waere eine zweite
// Stelle mit eigenen Grenzen.
//
// Fix Runde 1 (C1): der Picker lag bisher als durchsichtiges Item ohne
// eigenen Hintergrund ueber der Projektliste -- ein Klick neben eine
// Modellzeile traf die Projektzeile darunter und startete opencode, waehrend
// der Picker noch offen war. Jetzt traegt der Picker (a) einen blickdichten
// Hintergrund in derselben Farbe wie jedes andere Popup dieser Shell und
// (b) eine MouseArea, die JEDEN Klick auf sich selbst abfaengt -- auch auf
// die leere Flaeche zwischen zwei Zeilen. Reihenfolge zaehlt: Hintergrund
// und Abfang-MouseArea stehen als ERSTE Kinder (unterste Ebene), Suchfeld,
// Liste und Fusszeile stehen DANACH (oben) und bekommen ihre eigenen Klicks
// weiterhin zuerst -- nichts hinter diesem Item ist mehr erreichbar,
// solange es sichtbar ist.
//
// Fix Runde 1 (C2): das Panel gab dem Picker frueher nie eigenen
// Tastatur-Fokus. Ein QML-Tastendruck laeuft vom fokussierten Item die
// Elternkette hoch, NIE zu einem Geschwister-Item -- solange also der
// Picker (ein Geschwister von Panel.qmls "keyCatcher") keinen eigenen Fokus
// haelt, landen alle Tasten weiter beim keyCatcher, der "m" auf ein ANDERES
// Projekt umlegen konnte, waehrend der Picker noch fuer das alte offen war.
// "onVisibleChanged" holt sich deshalb beim Oeffnen aktiv den Fokus auf das
// Suchfeld -- ab dann verlaesst kein Tastendruck mehr dieses Item nach
// oben in Richtung des Panels, bis der Picker wieder schliesst.
Item {
  id: sheet
  visible: false
  anchors.fill: parent

  property var models: []
  property bool stale: false
  property string errorCode: ""
  property bool busy: false
  property string filter: ""
  property int cursor: 0
  property color fg: Color.foreground
  property string fontFam: Style.font.family
  // G7 (Gruppierung nach Anbieter): das Panel setzt diese Eigenschaft beim
  // Oeffnen auf das fuer das aktuelle Projekt gemerkte Modell (leer, wenn
  // keines gemerkt ist). Der Picker kannte den aktuellen Stand bisher gar
  // nicht -- ohne ihn koennte "genau die Gruppe mit dem gemerkten Modell
  // aufklappen" nicht entschieden werden.
  property string currentModel: ""

  signal picked(string id)
  signal cleared()
  signal closed()
  signal starToggled(string id)

  readonly property var shown: {
    var f = String(sheet.filter).toLowerCase()
    if (f === "") return sheet.models
    return sheet.models.filter(function (m) {
      return String(m.id).toLowerCase().indexOf(f) !== -1
    })
  }

  // G7: welche Anbieter-Gruppen gerade aufgeklappt sind, als einfaches
  // Objekt provider -> true. Ein Objekt statt eines Arrays, weil das
  // Nachschlagen "ist dieser Anbieter aufgeklappt" so ein einzelner
  // Property-Zugriff bleibt, nicht ein Array-Scan pro Kopfzeile.
  property var expandedProviders: ({})

  function toggleHeader(provider) {
    var next = {}
    for (var k in sheet.expandedProviders) next[k] = sheet.expandedProviders[k]
    next[provider] = !next[provider]
    sheet.expandedProviders = next
  }

  // G7: die Gruppierung als benannte Funktion (wie shortPath() in
  // Panel.qml), damit eine Textregel in test/qml.test.sh sich daran
  // festhalten kann. Reine Arithmetik ohne Datei-IO, wie shortPath():
  //
  // - Gruppenreihenfolge = Reihenfolge des ERSTEN Auftretens jedes
  //   Anbieters in "models". "models" traegt bereits die von opencode
  //   gelieferte Reihenfolge (bin/omarchy-opencode-models sortiert bewusst
  //   NUR nach "starred", siehe Kommentar dort -- ein zweites Kriterium
  //   wuerde genau diese Reihenfolge zerstoeren). Diese Funktion fuegt
  //   KEINE zweite Sortierung ueber die Gruppen hinweg hinzu: sie merkt
  //   sich nur, in welcher Reihenfolge neue Anbieter zum ersten Mal
  //   auftauchen.
  // - Innerhalb einer Gruppe kommen die markierten (starred) Modelle
  //   zuerst -- eine stabile Zweiteilung (erst alle markierten in ihrer
  //   bisherigen Reihenfolge, dann alle unmarkierten in ihrer bisherigen
  //   Reihenfolge), kein zusaetzliches Sortierkriterium. Das gilt
  //   unabhaengig davon, ob die Liste schon global vorsortiert ankommt --
  //   die Funktion verlaesst sich nicht auf eine Eigenschaft ihres
  //   Aufrufers.
  // - Eine Kopfzeile je Gruppe ({kind:"header", provider, count,
  //   expanded}), gefolgt von den Modellzeilen ({kind:"model", model:m})
  //   NUR wenn die Gruppe aufgeklappt ist.
  function buildGroupedRows(models, expanded) {
    var order = []
    var buckets = {}
    for (var i = 0; i < models.length; i++) {
      var m = models[i]
      if (!buckets[m.provider]) { buckets[m.provider] = []; order.push(m.provider) }
      buckets[m.provider].push(m)
    }
    var rows = []
    for (var g = 0; g < order.length; g++) {
      var provider = order[g]
      var bucket = buckets[provider]
      var starredFirst = bucket.filter(function (x) { return x.starred })
        .concat(bucket.filter(function (x) { return !x.starred }))
      var isOpen = !!(expanded && expanded[provider])
      rows.push({ kind: "header", provider: provider, count: bucket.length, expanded: isOpen })
      if (isOpen) {
        for (var j = 0; j < starredFirst.length; j++) rows.push({ kind: "model", model: starredFirst[j] })
      }
    }
    return rows
  }

  // G7: solange gesucht wird, verschwinden Kopfzeilen und Einrueckung --
  // der Picker verhaelt sich dann exakt wie vorher (flache Liste,
  // Freitext-Eingabe bei keinem Treffer). "grouped" haelt fest, WELCHER der
  // beiden Faelle gerade gilt; die Delegate-Einrueckung und der
  // Kopfzeilen-Klick fragen beide danach statt "filter" doppelt zu pruefen.
  readonly property bool grouped: sheet.filter === ""

  // Die Zeilen, die die Liste tatsaechlich zeichnet: im Suchmodus die
  // gefilterten Modelle ohne Kopfzeilen, sonst die gruppierten Zeilen aus
  // buildGroupedRows(). Der Tastatur-Cursor zeigt in DIESE Liste (nicht
  // mehr direkt in "shown"), weil er jetzt auch auf Kopfzeilen stehen kann.
  readonly property var visibleRows: sheet.grouped
    ? sheet.buildGroupedRows(sheet.models, sheet.expandedProviders)
    : sheet.shown.map(function (m) { return { kind: "model", model: m } })

  // Die Cursor-Position darf nie ausserhalb der aktuell sichtbaren Zeilen
  // stehen. Bleibt bewusst ein reines Kuerzen auf die neue Laenge (kein
  // Repositionieren): eine Kopfzeile, die gerade zuklappt, veraendert nie
  // ihren eigenen Index (nur was DANACH stand, verschwindet) -- Enter auf
  // einer Kopfzeile trifft also nach dem Zuklappen wieder dieselbe
  // Kopfzeile. Nur ein Wechsel des Suchtextes (springt zwischen flacher und
  // gruppierter Ansicht) kann den Cursor auf eine voellig andere Zeile
  // legen -- genau das galt schon vor der Gruppierung fuer "shown".
  onVisibleRowsChanged: sheet.cursor = Math.max(0, Math.min(sheet.cursor, sheet.visibleRows.length - 1))

  // W1: eine Meldung, die den tatsaechlichen Grund nennt, statt "Liste aus
  // dem Zwischenspeicher" zu behaupten, wo gar kein Zwischenspeicher
  // existiert. bin/omarchy-opencode-models setzt "error" IMMER zusammen mit
  // "models: []" -- ein Fehlercode und eine gleichzeitig nutzbare
  // Modell-Liste schliessen sich also gegenseitig aus.
  //
  // Ruling 47: alle Zeichenketten, die ein Benutzer liest, sind englisch;
  // die Kommentare bleiben deutsch. Grund ist die Konsistenz mit dem
  // veroeffentlichten Schwesterwidget smartalb.vpn und mit dem Publikum
  // des Marktplatzes.
  readonly property string statusText: {
    if (sheet.errorCode === "opencode-missing") return "opencode is not installed or not executable"
    if (sheet.errorCode === "models-unavailable") return "opencode was unreachable, and there is no cached list"
    if (sheet.errorCode === "models-too-large") return "The model list was too large, and there is no usable cached list"
    if (sheet.errorCode === "cache-too-large") return "The cached model list has grown too large"
    // C4: bislang meldete das Skript auch fuer einen bloss UNLESBAREN
    // Zwischenspeicher "cache-too-large" -- eine 13 Byte grosse Datei mit
    // chmod 000 kam als "zu gross" an. Der eigene Code braucht seinen
    // eigenen Satz.
    if (sheet.errorCode === "cache-unreadable") return "The cached model list cannot be read (check its permissions)"
    if (sheet.errorCode === "cache-not-a-file") return "The model cache path is not a regular file (a symlink, perhaps)"
    if (sheet.errorCode !== "") return "Model list not readable"
    if (sheet.stale) return "List from the cache -- opencode was unreachable"
    if (sheet.models.length === 0) return "No models found"
    return ""
  }

  onVisibleChanged: {
    if (sheet.visible) {
      sheet.filter = ""
      search.text = ""
      // G7: genau die Gruppe mit dem gemerkten Modell klappt auf, alle
      // anderen bleiben zu -- ohne gemerktes Modell bleibt ALLES zu (leeres
      // Objekt). Das Modell selbst wird ueber die ID in "models" gesucht,
      // nicht blind uebernommen: ein "currentModel", das gar nicht (mehr)
      // in der Liste steht (z.B. ein per Freitext gesetztes, dem Katalog
      // unbekanntes), darf keine Gruppe aufklappen, die es gar nicht gibt.
      var expanded = {}
      var found = null
      if (sheet.currentModel !== "") {
        for (var i = 0; i < sheet.models.length; i++) {
          if (sheet.models[i].id === sheet.currentModel) { found = sheet.models[i]; break }
        }
        if (found) expanded[found.provider] = true
      }
      sheet.expandedProviders = expanded
      // Cursor auf die Zeile des gemerkten Modells in der jetzt (durch die
      // Zeile darueber) neu berechneten "visibleRows" -- oder auf die erste
      // Zeile (Kopfzeile), wenn nichts gemerkt oder nichts gefunden wurde.
      var rows = sheet.visibleRows
      var pos = 0
      if (found) {
        for (var j = 0; j < rows.length; j++) {
          if (rows[j].kind === "model" && rows[j].model.id === sheet.currentModel) { pos = j; break }
        }
      }
      sheet.cursor = pos
      // Qt.callLater: der Fokus darf erst NACH dem aktuellen Tastendruck
      // (der den Picker ueberhaupt erst geoeffnet hat) wechseln.
      Qt.callLater(function () { if (sheet.visible) search.forceActiveFocus() })
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Color.popups.background
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
  }

  Item {
    id: col
    anchors.fill: parent
    anchors.margins: Style.spacing.sm

    Column {
      id: header
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(4)

      TextField {
        id: search
        width: parent.width
        placeholderText: "Search models"
        foreground: sheet.fg
        onTextChanged: sheet.filter = text

        Keys.onEscapePressed: sheet.closed()
        // G1: ein getippter Text, der zu keiner Zeile passt, tat bisher
        // gar nichts (Enter waehlte immer shown[0]). Jetzt gilt: gibt es
        // eine Trefferliste, waehlt Enter die aktuell markierte Zeile
        // darin; gibt es KEINE Treffer, geht der getippte Text roh an den
        // Store -- der lehnt eine syntaktisch ungueltige ID mit Exit 4 ab,
        // und genau diese Meldung erscheint dann im Panel. Keine
        // Vorab-Pruefung hier: das waere eine zweite Stelle mit eigenen
        // Regeln fuer dieselbe Frage.
        // G7: Enter wirkt jetzt auf die sichtbare Zeile ("visibleRows"),
        // nicht mehr direkt auf "shown" -- eine Zeile kann jetzt auch eine
        // Kopfzeile sein. Im Suchmodus (grouped === false) enthaelt
        // "visibleRows" nie Kopfzeilen, das Verhalten bleibt dort also
        // BYTEGLEICH zu vorher: Enter waehlt die markierte Zeile, oder,
        // ohne Treffer, geht der getippte Text roh an den Store (siehe G1
        // weiter unten).
        Keys.onReturnPressed: {
          if (sheet.visibleRows.length > 0) {
            var i = Math.max(0, Math.min(sheet.cursor, sheet.visibleRows.length - 1))
            var row = sheet.visibleRows[i]
            if (row.kind === "header") sheet.toggleHeader(row.provider)
            else sheet.picked(row.model.id)
          } else if (search.text.trim() !== "") {
            sheet.picked(search.text.trim())
          }
        }
        // G2/G7: Pfeiltasten verschieben die Auswahl ueber die sichtbaren
        // Zeilen (Kopfzeilen plus die Modelle aufgeklappter Gruppen, oder
        // im Suchmodus die flache Trefferliste); "*" schaltet den Stern der
        // markierten Zeile um, wenn sie ein Modell ist -- auf einer
        // Kopfzeile tut "*" nichts. Der Fokus bleibt dabei die ganze Zeit
        // im Suchfeld -- kein zweiter Fokus-Ort, um den man sich kuemmern
        // muesste (siehe C2 oben). "*" kommt in keiner gueltigen Modell-ID
        // vor (siehe valid_model_id in bin/_common.sh), geht also nie als
        // Zeichen fuer den Filter verloren.
        Keys.onPressed: function (e) {
          if (e.key === Qt.Key_Down) {
            sheet.cursor = Math.min(sheet.cursor + 1, sheet.visibleRows.length - 1)
            e.accepted = true
          } else if (e.key === Qt.Key_Up) {
            sheet.cursor = Math.max(sheet.cursor - 1, 0)
            e.accepted = true
          } else if (e.text === "*" && sheet.visibleRows.length > 0) {
            var row = sheet.visibleRows[Math.max(0, Math.min(sheet.cursor, sheet.visibleRows.length - 1))]
            if (row && row.kind === "model") sheet.starToggled(row.model.id)
            e.accepted = true
          }
        }
      }

      Text {
        width: parent.width
        visible: sheet.statusText !== ""
        text: sheet.statusText
        color: sheet.fg
        font.family: sheet.fontFam
        font.pixelSize: Style.font.caption
        opacity: 0.75
        wrapMode: Text.WordWrap
      }

      // C2: Keys.onReturnPressed oben nimmt einen frei getippten Text als
      // Modell-ID, sobald die Trefferliste leer ist -- Spezifikation 5
      // versprach den Hinweis darauf ausdruecklich, und keine Stelle nannte
      // ihn. Genau die gleiche Bedingung wie dort ("shown.length === 0"),
      // damit der Hinweis erscheint, wenn er zutrifft: bei leerer oder
      // fehlerhafter Liste ebenso wie bei einer Sucheingabe ohne Treffer.
      Text {
        width: parent.width
        visible: sheet.shown.length === 0
        text: "You can also type a full model id (provider/model) and press Enter."
        color: sheet.fg
        font.family: sheet.fontFam
        font.pixelSize: Style.font.caption
        opacity: 0.75
        wrapMode: Text.WordWrap
      }
    }

    // Quality: die Zeilenliste war frueher "parent.height - search.height -
    // 8" auf einer Column mit anchors.fill -- die letzte Zeile lag dadurch
    // ausserhalb des sichtbaren Bereichs. Jetzt haengt die Liste fest
    // zwischen dem Kopf (Suchfeld + Statuszeile) und der Fusszeile
    // (defaultRow), unabhaengig davon, wie hoch beide gerade sind.
    ListView {
      id: list
      anchors.top: header.bottom
      anchors.topMargin: Style.space(4)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: defaultRow.top
      anchors.bottomMargin: Style.space(4)
      clip: true
      model: sheet.visibleRows
      currentIndex: sheet.cursor

      // G7: eine Zeile ist jetzt entweder eine Kopfzeile (kind === "header")
      // oder eine Modellzeile (kind === "model", das eigentliche Modell
      // steht in modelData.model). Beide teilen sich Rahmen, Markierung und
      // Klickflaeche; die beiden Text-/Knopf-Elemente darunter blenden sich
      // je nach Zeilenart gegenseitig aus. Jede Stelle, die auf ein Modell
      // zugreift, fragt zuerst "row.isHeader" ab (Kurzschlussauswertung) --
      // eine Kopfzeile hat kein ".model", ein ungeschuetzter Zugriff wuerde
      // dort einen TypeError werfen.
      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        readonly property bool isHeader: modelData.kind === "header"
        width: ListView.view.width
        height: Style.spacing.popupRowHeight
        radius: Style.cornerRadius
        color: index === sheet.cursor
          ? Style.selectedFill
          : (rowMouse.containsMouse && !sheet.busy ? Style.hoverFill : "transparent")
        opacity: sheet.busy ? 0.6 : 1.0

        // Kopfzeile: Chevron (auf-/zugeklappt) + Anbietername + Anzahl,
        // z.B. "opencode 64". Chevron als \u-Escape, wie jede Glyphe in
        // diesem Projekt (keine Nicht-ASCII-Bytes in QML).
        Text {
          visible: row.isHeader
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.sm
          anchors.rightMargin: Style.spacing.sm
          text: row.isHeader
            ? (modelData.expanded ? "\u25be " : "\u25b8 ") + modelData.provider + " " + modelData.count
            : ""
          color: sheet.fg
          font.family: sheet.fontFam
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        // Modellzeile: wie vor der Gruppierung, zusaetzlich eingerueckt,
        // solange ueberhaupt gruppiert angezeigt wird ("sheet.grouped") --
        // im Suchmodus gibt es keine Kopfzeilen, also auch keine Einrueckung
        // (Spezifikation: Suche zeigt die flache Liste exakt wie vorher).
        Text {
          visible: !row.isHeader
          anchors.left: parent.left
          anchors.right: starButton.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.sm + (sheet.grouped ? Style.space(12) : 0)
          anchors.rightMargin: Style.spacing.xs
          text: row.isHeader ? "" : modelData.model.id
          color: sheet.fg
          font.family: sheet.fontFam
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        // G2: bislang zeichnete der Picker nur den gefuellten Stern
        // (\u2605), ohne dass irgendeine Stelle "store star|unstar"
        // ueberhaupt aufgerufen haette. z:1 haelt den Knopf ueber der
        // Zeilen-MouseArea, damit ein Klick auf den Stern nicht stattdessen
        // die Zeile auswaehlt. G7: auf einer Kopfzeile gibt es keinen
        // Stern-Knopf -- "*" auf einer Kopfzeile tut laut Spezifikation
        // nichts.
        PanelActionButton {
          id: starButton
          visible: !row.isHeader
          z: 1
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.spacing.xs
          size: Style.space(22)
          iconText: !row.isHeader && modelData.model.starred ? "\u2605" : "\u2606"
          tooltipText: !row.isHeader && modelData.model.starred ? "Remove star" : "Add star"
          foreground: sheet.fg
          fontFamily: sheet.fontFam
          enabled: !sheet.busy && !row.isHeader
          onClicked: { if (!row.isHeader) sheet.starToggled(modelData.model.id) }
        }

        MouseArea {
          id: rowMouse
          z: 0
          anchors.fill: parent
          hoverEnabled: !sheet.busy
          enabled: !sheet.busy
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            sheet.cursor = index
            if (row.isHeader) sheet.toggleHeader(modelData.provider)
            else sheet.picked(modelData.model.id)
          }
        }
      }
    }

    // Quality: fest am unteren Rand von "col" verankert -- bleibt dadurch
    // immer erreichbar, unabhaengig davon wie viele Modelle die Liste
    // gerade zeigt (frueher: bei einem einzigen Projekt/Modell war die
    // gesamte Sheet-Hoehe nur ein paar Pixel hoch, siehe minHeight unten
    // und der zugehoerige Kommentar in Panel.qml).
    Rectangle {
      id: defaultRow
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Style.spacing.popupRowHeight
      radius: Style.cornerRadius
      color: defaultMouse.containsMouse && !sheet.busy ? Style.hoverFill : "transparent"
      opacity: sheet.busy ? 0.6 : 1.0

      Text {
        anchors.centerIn: parent
        text: "Use opencode's own default"
        color: sheet.fg
        font.family: sheet.fontFam
        font.pixelSize: Style.font.body
      }

      MouseArea {
        id: defaultMouse
        anchors.fill: parent
        hoverEnabled: !sheet.busy
        enabled: !sheet.busy
        cursorShape: Qt.PointingHandCursor
        onClicked: sheet.cleared()
      }
    }
  }

  // Panel.qml braucht eine Mindesthoehe fuer den Picker, die NICHT von der
  // Projektliste abhaengt (siehe dortiger Kommentar bei "contentHeight").
  readonly property int minHeight: Style.space(320)
}
