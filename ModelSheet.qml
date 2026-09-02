import QtQuick
import QtQuick.Controls

// Modell-Picker. Kennt keine Prozesse: er meldet die Auswahl nach oben und
// das Panel schreibt sie. Ein Picker, der selbst startet, waere eine zweite
// Stelle mit eigenen Grenzen.
Item {
  id: sheet
  visible: false
  anchors.fill: parent

  property var models: []
  property bool stale: false
  property string filter: ""

  signal picked(string id)
  signal cleared()
  signal closed()

  readonly property var shown: {
    var f = String(sheet.filter).toLowerCase()
    if (f === "") return sheet.models
    return sheet.models.filter(function (m) {
      return String(m.id).toLowerCase().indexOf(f) !== -1
    })
  }

  Keys.onEscapePressed: sheet.closed()

  Column {
    anchors.fill: parent
    spacing: 4

    TextField {
      id: search
      width: parent.width
      placeholderText: "Modell suchen"
      onTextChanged: sheet.filter = text
      Keys.onReturnPressed: if (sheet.shown.length > 0) sheet.picked(sheet.shown[0].id)
    }

    Text {
      visible: sheet.stale
      text: "Liste aus dem Zwischenspeicher - opencode war nicht erreichbar"
    }

    ListView {
      width: parent.width
      height: parent.height - search.height - 8
      model: sheet.shown
      clip: true
      delegate: ItemDelegate {
        width: ListView.view.width
        // \u2605: markiert die vom Benutzer favorisierten Modelle.
        text: (modelData.starred ? "\u2605 " : "") + modelData.id
        onClicked: sheet.picked(modelData.id)
      }
    }

    ItemDelegate {
      width: parent.width
      text: "Voreinstellung von opencode benutzen"
      onClicked: sheet.cleared()
    }
  }
}
