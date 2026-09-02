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
  // Die Cursor-Position darf nie ausserhalb der (sich mit jedem Tastendruck
  // im Suchfeld aendernden) gefilterten Liste stehen.
  onShownChanged: sheet.cursor = Math.max(0, Math.min(sheet.cursor, sheet.shown.length - 1))

  // W1: eine Meldung, die den tatsaechlichen Grund nennt, statt "Liste aus
  // dem Zwischenspeicher" zu behaupten, wo gar kein Zwischenspeicher
  // existiert. bin/omarchy-opencode-models setzt "error" IMMER zusammen mit
  // "models: []" -- ein Fehlercode und eine gleichzeitig nutzbare
  // Modell-Liste schliessen sich also gegenseitig aus.
  readonly property string statusText: {
    if (sheet.errorCode === "opencode-missing") return "opencode ist nicht installiert oder nicht ausfuehrbar"
    if (sheet.errorCode === "models-unavailable") return "opencode war nicht erreichbar, kein Zwischenspeicher vorhanden"
    if (sheet.errorCode === "models-too-large") return "Die Modell-Liste war zu gross, kein brauchbarer Zwischenspeicher vorhanden"
    if (sheet.errorCode === "cache-too-large") return "Der Zwischenspeicher selbst ist zu gross geworden"
    if (sheet.errorCode === "cache-not-a-file") return "Der Zwischenspeicher-Pfad ist kein normaler Ordnereintrag (evtl. ein Symlink)"
    if (sheet.errorCode !== "") return "Modell-Liste nicht lesbar"
    if (sheet.stale) return "Liste aus dem Zwischenspeicher -- opencode war nicht erreichbar"
    if (sheet.models.length === 0) return "Keine Modelle gefunden"
    return ""
  }

  onVisibleChanged: {
    if (sheet.visible) {
      sheet.filter = ""
      search.text = ""
      sheet.cursor = 0
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

  Keys.onEscapePressed: sheet.closed()

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
        placeholderText: "Modell suchen"
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
        Keys.onReturnPressed: {
          if (sheet.shown.length > 0) {
            var i = Math.max(0, Math.min(sheet.cursor, sheet.shown.length - 1))
            sheet.picked(sheet.shown[i].id)
          } else if (search.text.trim() !== "") {
            sheet.picked(search.text.trim())
          }
        }
        // G2: Pfeiltasten verschieben die Auswahl in der (evtl. gefilterten)
        // Liste; "*" schaltet den Stern der markierten Zeile um. Der Fokus
        // bleibt dabei die ganze Zeit im Suchfeld -- kein zweiter Fokus-Ort,
        // um den man sich kuemmern muesste (siehe C2 oben). "*" kommt in
        // keiner gueltigen Modell-ID vor (siehe valid_model_id in
        // bin/_common.sh), geht also nie als Zeichen fuer den Filter
        // verloren.
        Keys.onPressed: function (e) {
          if (e.key === Qt.Key_Down) {
            sheet.cursor = Math.min(sheet.cursor + 1, sheet.shown.length - 1)
            e.accepted = true
          } else if (e.key === Qt.Key_Up) {
            sheet.cursor = Math.max(sheet.cursor - 1, 0)
            e.accepted = true
          } else if (e.text === "*" && sheet.shown.length > 0) {
            var m = sheet.shown[Math.max(0, Math.min(sheet.cursor, sheet.shown.length - 1))]
            if (m) sheet.starToggled(m.id)
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
      model: sheet.shown
      currentIndex: sheet.cursor

      delegate: Rectangle {
        required property var modelData
        required property int index
        width: ListView.view.width
        height: Style.spacing.popupRowHeight
        radius: Style.cornerRadius
        color: index === sheet.cursor
          ? Style.selectedFill
          : (rowMouse.containsMouse && !sheet.busy ? Style.hoverFill : "transparent")
        opacity: sheet.busy ? 0.6 : 1.0

        Text {
          anchors.left: parent.left
          anchors.right: starButton.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.sm
          anchors.rightMargin: Style.spacing.xs
          text: modelData.id
          color: sheet.fg
          font.family: sheet.fontFam
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        // G2: bislang zeichnete der Picker nur den gefuellten Stern
        // (\u2605), ohne dass irgendeine Stelle "store star|unstar"
        // ueberhaupt aufgerufen haette. z:1 haelt den Knopf ueber der
        // Zeilen-MouseArea, damit ein Klick auf den Stern nicht stattdessen
        // die Zeile auswaehlt.
        PanelActionButton {
          id: starButton
          z: 1
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.spacing.xs
          size: Style.space(22)
          iconText: modelData.starred ? "\u2605" : "\u2606"
          tooltipText: modelData.starred ? "Stern entfernen" : "Favorisieren"
          foreground: sheet.fg
          fontFamily: sheet.fontFam
          enabled: !sheet.busy
          onClicked: sheet.starToggled(modelData.id)
        }

        MouseArea {
          id: rowMouse
          z: 0
          anchors.fill: parent
          hoverEnabled: !sheet.busy
          enabled: !sheet.busy
          cursorShape: Qt.PointingHandCursor
          onClicked: { sheet.cursor = index; sheet.picked(modelData.id) }
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
        text: "Voreinstellung von opencode benutzen"
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
