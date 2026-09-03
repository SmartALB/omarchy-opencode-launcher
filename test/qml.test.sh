#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
ROOT="$DIR/.."

test_kein_prozessstart_ausserhalb_der_helfer() {
  # Jede Zuweisung an "command" muss durch runner, runnerOut oder runnerErr
  # gehen -- egal ob als statische QML-Eigenschaft ("command:") oder als
  # spaetere Laufzeitzuweisung ("xProc.command ="). Nur nach "command:" zu
  # suchen liesse sich durch genau diese Verschiebung umgehen: launchProc
  # und storeProc setzen ihr Kommando erst beim Aufruf, per "=", und waeren
  # fuer eine reine "command:"-Suche unsichtbar.
  #
  # Fix Runde 1: blind fuer "Quickshell.execDetached([...])" -- ein zweiter
  # Weg, einen Prozess zu starten, der an "command"/runner()/runnerOut()/
  # runnerErr() ganz vorbeigeht und deshalb keine der dortigen Grenzen
  # (absoluter Pfad, Frist, Ausgabe-Deckel) traegt. Probe: eine Zeile
  # "Quickshell.execDetached([root.scriptDir + \"/x\"])" in Panel.qml
  # eingefuegt -> faellt jetzt durch, vorher unsichtbar.
  bad="$( { grep -nE 'command[[:space:]]*[:=]' "$ROOT"/*.qml | grep -v 'root.runner'; \
            grep -nE 'Quickshell\.execDetached[[:space:]]*\(' "$ROOT"/*.qml; } || true)"
  assert_eq "$bad" ""
}

test_kein_path_aufgeloester_interpreter() {
  # bash/timeout/head duerfen nur mit absolutem Pfad vorkommen. Der
  # Lookbehind prueft das direkt an der Fundstelle: eine Zeile, in der schon
  # ein korrektes "/usr/bin/timeout" steht, darf ein daneben stehendes
  # nacktes "bash" nicht mehr tarnen -- eine reine zeilenweite
  # Ausschlussregel ("hat die Zeile irgendwo einen gueltigen Pfad") wuerde
  # genau das zulassen, und root.runner() traegt mehrere dieser Namen auf
  # einer Zeile.
  # Ein Bash-Inline-Kommentar (Code, dann " # Erklaerung") wird vor der
  # Pruefung abgeschnitten -- sonst faellt schon eine Erklaerung wie
  # "edit() { # edit <jq-programm>" durch, obwohl dort kein Aufruf steht.
  # QML kennt keine "#"-Kommentare, das Abschneiden trifft dort also nie.
  # Fix Runde 1: "sh" fehlte in der Positivliste -- ein "/usr/bin/env sh"
  # oder ein nacktes "sh -c" waere PATH-aufgeloest gewesen und diese Regel
  # haette es nicht gesehen. Probe: eine Zeile "\"sh\", \"-c\"" in runner()
  # eingesetzt -> faellt jetzt durch (vorher: durchgerutscht, weil "sh"
  # nicht in der Liste stand).
  bad="$(for f in "$ROOT"/*.qml "$ROOT"/bin/*; do
           sed -E 's/^[[:space:]]*#.*$//; s/([[:space:]])#.*$/\1/' "$f" \
             | grep -noP '(?<!/usr/bin/)(?<![[:alnum:]_.-])(bash|sh|timeout|head|jq|sqlite3|hyprctl)\b' \
             | sed "s|^|$f:|"
         done \
          | grep -vE 'BIN_[A-Z0-9]+=' || true)"
  assert_eq "$bad" ""
}

test_beide_sammler_helfer_tragen_eine_erzeugergrenze() {
  out="$(grep -A3 'function runnerOut' "$ROOT/Panel.qml")"
  assert_contains "$out" "/usr/bin/head -c"
  err="$(grep -A3 'function runnerErr' "$ROOT/Panel.qml")"
  assert_contains "$err" "/usr/bin/head -c"
}

test_runner_traegt_frist_und_kill_nachlauf() {
  out="$(grep -A3 'function runner(' "$ROOT/Panel.qml")"
  assert_contains "$out" "/usr/bin/timeout"
  assert_contains "$out" '"-k", "5"'
}

test_stderr_helfer_nutzt_prozess_substitution_keine_pipe() {
  # Eine Pipe ersetzte den Exit-Status, den der Aufrufer liest.
  err="$(grep -A3 'function runnerErr' "$ROOT/Panel.qml")"
  assert_contains "$err" "2> >("
}

test_abbau_deckt_jeden_erklaerten_prozess() {
  declared="$(grep -oE 'id: [a-zA-Z]+Proc' "$ROOT/Panel.qml" | awk '{print $2}' | sort -u)"
  # Fix Runde 1: die alte Fassung suchte im onDestruction-Block nach JEDEM
  # Vorkommen von "[a-zA-Z]+Proc" -- ganz gleich, ob der Name dort wirklich
  # gestoppt wurde oder nur ERWAEHNT ist. Der Reviewer zeigte zwei Wege, das
  # auszunutzen: (a) alle vier "= false" durch "= true" ersetzen -- der Name
  # steht immer noch in der Zeile "projectsProc.running = true", die alte
  # Regel sah nur den Namen, nicht den Wert, und blieb GRUEN, obwohl damit
  # nichts mehr gestoppt wird; (b) den ganzen Block durch einen Kommentar
  # ersetzen, der die vier Namen nur noch AUFZAEHLT ("stoppt projectsProc,
  # modelsProc, ..."), ohne sie tatsaechlich zu stoppen -- auch das blieb
  # GRUEN, weil ein Kommentar fuer diese Regel nicht von echtem Code zu
  # unterscheiden war.
  #
  # Die neue Fassung verlangt die woertliche Teilkette
  # "<name>.running = false" (mit variablem Leerraum um "=") an der
  # Fundstelle selbst -- ein Name, der nur erwaehnt oder auf "true" gesetzt
  # wird, zaehlt nicht mehr als gestoppt.
  #
  # Proben (siehe Task-6-Fix-Runde-1-Report fuer die tatsaechlich
  # ausgefuehrten Kommandos und ihre Ausgabe):
  #   (a) "= false" -> "= true" bei allen vieren: FAELLT jetzt (vorher:
  #       blieb gruen).
  #   (b) den Block durch "// stoppt projectsProc, modelsProc, launchProc,
  #       storeProc" ersetzt: FAELLT jetzt (vorher: blieb gruen).
  #   (c) ein fuenfter, nie deklarierter Prozess "ghostProc" wird im Block
  #       zusaetzlich per "ghostProc.running = false" gestoppt: FAELLT (die
  #       Regel ist eine echte Mengengleichheit, kein reines Enthaltensein).
  #   (d) ein fuenfter, deklarierter Prozess ("id: ghostProc") wird NICHT
  #       im Block gestoppt: FAELLT.
  stopped="$(sed -n '/Component.onDestruction/,/^  }/p' "$ROOT/Panel.qml" \
             | grep -oE '[a-zA-Z]+Proc\.running[[:space:]]*=[[:space:]]*false' \
             | grep -oE '^[a-zA-Z]+Proc' | sort -u || true)"
  assert_eq "$declared" "$stopped"
}

test_zahlenwerte_aus_einstellungen_sind_begrenzt() {
  # Ein Wert aus shell.json wandert in eine Kommandozeile. Er darf nur als
  # eingeschraenkte Zahl dorthin gelangen, nie als Zeichenkette.
  #
  # C12 (Abschluss-Review): die alte Fassung suchte nur nach den
  # ZEICHENKETTEN "Math.max"/"Math.min" -- eine reine Anwesenheitsregel.
  # Der Reviewer hat die Obergrenze auf 99999999 aufgeweitet und die Regel
  # blieb gruen: sie sah, DASS geklammert wird, nie WORAUF. Und refreshHours
  # war nur halb so streng geprueft wie recentCount ("Math.min" ja,
  # "Math.max" nein). Jetzt zaehlen beide Grenzen woertlich, fuer beide
  # Werte.
  #
  # Leerraum wird vorher entfernt, damit eine Umformatierung (Zeilenumbruch
  # hinter "Math.max(") die Regel nicht aus einem Grund rot macht, der
  # nichts mit der Grenze zu tun hat.
  out="$(grep -A2 'readonly property int recentCount' "$ROOT/Panel.qml" | tr -d ' \n')"
  assert_contains "$out" "Math.max(0,Math.min(50,"
  out="$(grep -A2 'readonly property int refreshHours' "$ROOT/Panel.qml" | tr -d ' \n')"
  assert_contains "$out" "Math.max(0,Math.min(720,"
}

test_mausrad_ist_unbelegt() {
  # Fix Runde 1: blind fuer "WheelHandler { onRotationChanged: ... }" -- ein
  # WheelHandler kann das Mausrad ueber JEDES eigene Signal abgreifen
  # (onRotationChanged, onActiveRotationChanged, ...), nicht nur ueber ein
  # nach "onWheel" benanntes. Die reine Textsuche nach "onWheel" sah so ein
  # Konstrukt gar nicht. Probe: "WheelHandler { onRotationChanged: root.
  # refreshAll() }" in Panel.qml eingefuegt -> faellt jetzt durch.
  bad="$(grep -nE 'onWheel|WheelHandler' "$ROOT"/*.qml || true)"
  assert_eq "$bad" ""
}

test_panel_version_entspricht_dem_manifest() {
  mv="$(jq -r .version "$ROOT/manifest.json")"
  pv="$(grep -oE 'pluginVersion: "[^"]+"' "$ROOT/Panel.qml" | cut -d'"' -f2)"
  assert_eq "$pv" "$mv"
}

test_kein_schreibpfad_nach_config_opencode() {
  bad="$(grep -rn '\.config/opencode' "$ROOT/bin" "$ROOT"/*.qml \
          | grep -vE 'opencode-launcher|opencode-projects' \
          | grep -vE '^[^:]+:[0-9]+: *#' || true)"
  assert_eq "$bad" ""
}

test_stern_umschalten_erzwingt_frischen_katalog() {
  # Ruling 45 (Fix Runde 2, G2): "store star|unstar" schreibt zuverlaessig,
  # aber "starred" wird von bin/omarchy-opencode-models nur beim
  # tatsaechlichen Abruf aus opencode neu in den Zwischenspeicher
  # geschrieben (siehe emit() dort) -- ein Wiedereinlesen OHNE "--refresh"
  # liefert bei frischem Zwischenspeicher denselben, jetzt veralteten
  # Stern-Stand zurueck. toggleStar() liest "starred" aus genau dieser
  # Liste, um zwischen "star" und "unstar" zu entscheiden: ohne "--refresh"
  # waere "unstar" bis zum naechsten manuellen Aktualisieren unerreichbar,
  # und ein zweiter Klick haette "star" ein zweites Mal gesendet.
  #
  # Nicht ueber Verhalten pruefbar -- kein Bash-Test kann den gerenderten
  # Stern lesen --, wohl aber ueber den Kommandostring selbst, dieselbe
  # Methode wie bei der Prozess-Substitution und den absoluten
  # Interpreter-Pfaden.
  # Kommentarzeilen ausgeschnitten, bevor geprueft wird: ein Kommentar, der
  # "--refresh" nur ERWAEHNT (wie der direkt daneben stehende, der genau
  # diese Regel erklaert), darf die Regel nicht faelschlich gruen halten --
  # gemessen an einer echten Probe (siehe Fix-Runde-2-Report): das
  # "--refresh" aus der Kommandozeile entfernt, waehrend der erklaerende
  # Kommentar (der das Wort selbst nennt) stehen blieb, hielt die
  # ungefilterte Fassung dieser Regel faelschlich gruen.
  out="$(sed -n '/root.storeAction === "star"/,/^      } else {/p' "$ROOT/Panel.qml" \
          | grep -v '^[[:space:]]*//')"
  assert_contains "$out" "--refresh"
}

test_displayPath_erscheint_hoechstens_einmal() {
  # G5 (Panel-Redesign): die Projektzeile zeigte bisher Name und
  # displayPath als zwei uebereinanderstehende Zeilen -- fuer jedes
  # automatisch aufgenommene Projekt derselbe Text zweimal. Jetzt gibt es
  # nur noch die eine Namenszeile, die "displayPath" genau EINMAL nennt
  # (die Unterscheidung "echter Name oder abgekuerzter Pfad"). Ein
  # spaeterer Refactor, der die zweite Zeile stillschweigend wieder
  # einfuehrt, fuegt zwangslaeufig eine ZWEITE Fundstelle hinzu -- diese
  # Regel zaehlt Zeilen, nicht Vorkommen, weil die eine legitime Zeile den
  # Bezeichner selbst zweimal traegt (Vergleich und Rueckfallzweig).
  count="$(grep -c 'displayPath' "$ROOT/Panel.qml")"
  assert_eq "$count" "1"
}

test_projektzeile_elidiert_links() {
  # G5: die Namenszeile muss ElideLeft tragen -- bei einem langen
  # abgekuerzten Pfad soll das ENDE (der aussagekraeftige Teil) sichtbar
  # bleiben und die Ellipse vorne stehen, nicht wie zuvor ElideRight.
  out="$(grep -A6 'modelData.name !== modelData.displayPath' "$ROOT/Panel.qml")"
  assert_contains "$out" "Text.ElideLeft"
}

test_pfad_fallback_wird_gekuerzt() {
  # G6: der Pfad-Fallback in der Namenszeile (der Zweig OHNE echten Namen)
  # muss auf die letzten drei Segmente gekuerzt sein -- nicht der rohe,
  # ungekuerzte displayPath. Zwei Pruefungen, damit ein Umgehen an beiden
  # moeglichen Stellen auffliegt:
  #   1) die Bindung selbst muss root.shortPath(modelData.displayPath)
  #      aufrufen (ein Bypass, der wieder das nackte modelData.displayPath
  #      einsetzt, faellt hier durch)
  #   2) die Funktion shortPath(p) muss ueberhaupt definiert sein (ein
  #      Loeschen der Funktion, bei dem irgendwo noch "shortPath" als Text
  #      auftaucht, faellt hier durch, weil hier nach der Funktions-
  #      SIGNATUR gesucht wird, nicht nur nach dem Namen)
  out="$(grep -A6 'modelData.name !== modelData.displayPath' "$ROOT/Panel.qml")"
  assert_contains "$out" "root.shortPath(modelData.displayPath)"

  def_count="$(grep -c 'function shortPath(p)' "$ROOT/Panel.qml")"
  assert_eq "$def_count" "1"
}

test_shortpath_segmentarithmetik() {
  # shortPath() in Panel.qml ist reine String-Arithmetik ohne Datei-IO:
  # Segmente an "/" zaehlen, das fuehrende "~" zaehlt mit, ab mehr als drei
  # Segmenten ueberleben nur die letzten drei, mit "…/" davor.
  #
  # ACHTUNG (ehrlich, nicht schoengeredet): dies ist KEIN Aufruf der
  # echten QML-Funktion. Panel.qml importiert Quickshell.Io und
  # qs.Commons/qs.Ui, die ausserhalb der laufenden Omarchy-Shell nicht
  # aufloesbar sind -- weder "qml" (Qt6) noch irgendein anderes Werkzeug
  # in dieser Sandbox kann die Datei isoliert ausfuehren. Was hier steht,
  # ist eine PARALLELE Nachrechnung derselben Segment-Arithmetik in Bash,
  # gegen dieselben Beispiele wie in der Aufgabenstellung. Sie deckt die
  # Rechenregel ab (Segmentzahl, Grenzfall <=3, welche drei ueberleben,
  # der abgeschnittene schliessende Slash) -- nicht den tatsaechlich in
  # Panel.qml ausgefuehrten Bytecode. Eine Aenderung an shortPath(), die
  # diese Rechenregel nicht mitaendert, bleibt fuer DIESEN Test unsichtbar;
  # die Textregel oben (test_pfad_fallback_wird_gekuerzt) plus qmllint
  # plus die visuelle Kontrolle im Panel schliessen diese Luecke.
  ellipsis="$(printf '…')"

  short_path_bash() {
    local p="$1" s
    if [ "${#p}" -gt 1 ] && [ "${p: -1}" = "/" ]; then s="${p%/}"; else s="$p"; fi
    local segs=()
    IFS='/' read -ra segs <<< "$s"
    local n="${#segs[@]}"
    if [ "$n" -le 3 ]; then printf '%s' "$p"; return 0; fi
    local start=$((n - 3))
    local last3=("${segs[@]:$start:3}")
    local joined
    joined="$(IFS=/; printf '%s' "${last3[*]}")"
    printf '%s/%s' "$ellipsis" "$joined"
  }

  assert_eq "$(short_path_bash '~')" "~"
  assert_eq "$(short_path_bash '~/.config')" "~/.config"
  assert_eq "$(short_path_bash '~/Development/Sources/Extern/shannon')" \
    "${ellipsis}/Sources/Extern/shannon"
  assert_eq "$(short_path_bash '/srv/work/api')" "${ellipsis}/srv/work/api"
  # Schliessender Slash -> leeres letztes Segment; muss dasselbe liefern
  # wie ohne den Slash (der abgeschnittene Fall aus dem Kommentar oben).
  assert_eq "$(short_path_bash '~/Development/Sources/Extern/shannon/')" \
    "${ellipsis}/Sources/Extern/shannon"
}

test_laufanzeige_steht_nicht_im_elidierten_text() {
  # Der Marker (voller/leerer Kringel) darf NICHT in demselben Text stehen,
  # der ElideLeft traegt: ElideLeft kuerzt von links, also verschwaende genau
  # der Marker als erstes, sobald die Zeile zu breit wird. Genau das ist
  # passiert und im Screenshot aufgefallen. Der Marker gehoert in ein eigenes,
  # nicht elidiertes Text-Element.
  block="$(sed -n '/id: rowLine/,/^                }/p' "$ROOT/Panel.qml")"
  elided="$(printf '%s' "$block" | grep -B8 'elide: Text.ElideLeft')"
  assert_not_contains "$elided" '\u25CF'
  assert_not_contains "$elided" '\u25CB'
  # ... und der Marker muss trotzdem irgendwo in der Zeile vorkommen.
  assert_contains "$block" '\u25CF'
}

test_gruppierungsfunktion_definiert_und_von_liste_aufgerufen() {
  # G7 (Gruppierung nach Anbieter): buildGroupedRows() ist die benannte
  # Funktion, an der sich diese Regel festhaelt -- wie shortPath() in
  # Panel.qml (siehe test_pfad_fallback_wird_gekuerzt). Zwei Pruefungen,
  # damit ein Umgehen an beiden moeglichen Stellen auffliegt:
  #   1) die Funktion muss ueberhaupt (genau einmal) definiert sein
  #   2) die Zeilenliste ("model:" der ListView) muss an "visibleRows"
  #      gebunden sein, und "visibleRows" selbst muss buildGroupedRows()
  #      AUFRUFEN -- ein Umbau, der die Funktion zwar behaelt, sie aber aus
  #      visibleRows entfernt (z.B. durch eine eigene, kopierte Schleife),
  #      faellt hier durch, obwohl die Funktion selbst weiter existiert.
  def_count="$(grep -c 'function buildGroupedRows(models, expanded)' "$ROOT/ModelSheet.qml")"
  assert_eq "$def_count" "1"

  bound="$(grep -c 'model: sheet.visibleRows' "$ROOT/ModelSheet.qml")"
  assert_eq "$bound" "1"

  vr="$(grep -A4 'readonly property var visibleRows:' "$ROOT/ModelSheet.qml")"
  assert_contains "$vr" "sheet.buildGroupedRows("
}

test_suche_ueberspringt_gruppierung() {
  # Sobald das Suchfeld nicht leer ist ("filter" != "", "grouped" wird
  # false), muss "visibleRows" OHNE buildGroupedRows() auskommen -- die
  # Suche zeigt die flache Trefferliste ohne Kopfzeilen (jede Zeile
  # "kind: model"), exakt wie vor der Gruppierung.
  g="$(grep -A1 'readonly property bool grouped:' "$ROOT/ModelSheet.qml")"
  assert_contains "$g" 'sheet.filter === ""'

  vr="$(grep -A4 'readonly property var visibleRows:' "$ROOT/ModelSheet.qml")"
  assert_contains "$vr" "sheet.grouped"
  assert_contains "$vr" "sheet.shown.map("
  assert_contains "$vr" '"model"'
}

test_enter_auf_kopfzeile_schaltet_um_statt_zu_waehlen() {
  # G7: Enter auf einer Kopfzeile klappt sie auf/zu (toggleHeader);
  # Enter auf einer Modellzeile waehlt sie (picked). Beide Zweige muessen
  # im selben Keys.onReturnPressed stehen -- ein Umbau, der "picked" auch
  # fuer Kopfzeilen aufruft (oder "toggleHeader" ganz entfernt), faellt hier
  # durch.
  out="$(grep -A10 'Keys.onReturnPressed' "$ROOT/ModelSheet.qml")"
  assert_contains "$out" 'row.kind === "header"'
  assert_contains "$out" 'sheet.toggleHeader(row.provider)'
  assert_contains "$out" 'sheet.picked(row.model.id)'
}

test_gruppierung_arithmetik_erstauftreten_und_sterne() {
  # ACHTUNG (ehrlich, nicht schoengeredet): dies ist KEIN Aufruf der echten
  # QML-Funktion buildGroupedRows() aus ModelSheet.qml. ModelSheet.qml
  # importiert qs.Commons/qs.Ui, die ausserhalb der laufenden Omarchy-Shell
  # nicht aufloesbar sind -- dieselbe Einschraenkung wie bei
  # test_shortpath_segmentarithmetik oben, aus demselben Grund (siehe dort).
  # Was hier steht, ist eine PARALLELE Nachrechnung derselben Arithmetik in
  # Bash: Gruppenreihenfolge nach dem ERSTEN Auftreten des Anbieters in der
  # (absichtlich mit Anbietern durchmischten) Eingabe, die Anzahl je Gruppe,
  # und innerhalb einer Gruppe eine stabile Zweiteilung (erst alle
  # markierten in ihrer bisherigen Reihenfolge, dann alle unmarkierten in
  # ihrer bisherigen Reihenfolge). Sie deckt die Rechenregel ab -- nicht den
  # tatsaechlich in ModelSheet.qml ausgefuehrten Bytecode. Eine Aenderung an
  # buildGroupedRows(), die diese Rechenregel nicht mitaendert, bleibt fuer
  # DIESEN Test unsichtbar; die drei Textregeln oben plus qmllint plus die
  # visuelle Kontrolle im Panel schliessen diese Luecke.
  declare -A seen=()
  order=()
  declare -A starred_ids=()
  declare -A unstarred_ids=()
  declare -A counts=()

  add_model() {  # add_model <id> <provider> <starred:0|1>
    local id="$1" provider="$2" starred="$3"
    if [ -z "${seen[$provider]:-}" ]; then
      seen[$provider]=1
      order+=("$provider")
    fi
    counts[$provider]=$(( ${counts[$provider]:-0} + 1 ))
    if [ "$starred" = "1" ]; then
      starred_ids[$provider]="${starred_ids[$provider]:-} $id"
    else
      unstarred_ids[$provider]="${unstarred_ids[$provider]:-} $id"
    fi
  }

  # Eingabe bewusst interleaved (nicht nach Anbieter sortiert) und mit
  # einem Stern MITTEN in einer sonst unmarkierten Gruppe -- genau der
  # Fall, den eine simple "die Liste kam schon vorsortiert an"-Annahme
  # uebersehen wuerde.
  add_model "opencode/a" opencode 0
  add_model "lmstudio/x" lmstudio 0
  add_model "opencode/b" opencode 1
  add_model "openai/gpt" openai 0
  add_model "lmstudio/y" lmstudio 1
  add_model "opencode/c" opencode 0

  # Gruppenreihenfolge: opencode zuerst (sein erstes Modell steht insgesamt
  # zuerst), dann lmstudio, dann openai -- unabhaengig von Sternen oder
  # Gruppengroesse.
  assert_eq "${order[*]}" "opencode lmstudio openai"

  # Anzahl je Gruppe.
  assert_eq "${counts[opencode]}" "3"
  assert_eq "${counts[lmstudio]}" "2"
  assert_eq "${counts[openai]}" "1"

  # Innerhalb "opencode": b ist markiert, a und c nicht -- b muss VOR a und
  # c stehen; a und c behalten ihre relative Reihenfolge (a vor c).
  assert_eq "${starred_ids[opencode]}${unstarred_ids[opencode]}" \
    " opencode/b opencode/a opencode/c"

  # Innerhalb "lmstudio": y ist markiert, x nicht -- y vor x.
  assert_eq "${starred_ids[lmstudio]}${unstarred_ids[lmstudio]}" " lmstudio/y lmstudio/x"

  # "openai" hat keinen Stern -- die Gruppe bleibt einfach in ihrer
  # Reihenfolge.
  assert_eq "${unstarred_ids[openai]}" " openai/gpt"
  assert_eq "${starred_ids[openai]:-}" ""
}

test_untergruppen_schwelle_lebt_in_gruppierungsfunktion() {
  # G8 (dritte Ebene): die Schwellen-Entscheidung ("mindestens zwei
  # Untergruppen mit je mindestens zwei Mitgliedern") muss INNERHALB von
  # buildGroupedRows() stehen -- nicht als eigene Kopie in einem Binding
  # (z.B. "visibleRows") daneben. Zwei Pruefungen:
  #   1) die Woerter "qualifying" und "subdivided" (die Namen der
  #      Schwellen-Variablen) muessen im FUNKTIONSKOERPER vorkommen --
  #      extrahiert per sed-Bereich von der Funktionssignatur bis zur
  #      naechsten schliessenden Klammer auf Funktionsebene, dieselbe
  #      Methode wie test_abbau_deckt_jeden_erklaerten_prozess oben.
  #   2) dieselben Woerter duerfen NICHT im "visibleRows"-Binding
  #      auftauchen -- ein Umbau, der die Schwelle zusaetzlich (oder
  #      stattdessen) dort nachbaut, faellt hier durch.
  body="$(sed -n '/^  function buildGroupedRows(models, expanded) {/,/^  }/p' "$ROOT/ModelSheet.qml")"
  assert_contains "$body" "qualifying"
  assert_contains "$body" "subdivided"

  vr="$(grep -A4 'readonly property var visibleRows:' "$ROOT/ModelSheet.qml")"
  assert_not_contains "$vr" "qualifying"
  assert_not_contains "$vr" "subdivided"
}

test_untergruppen_kopfzeile_aus_funktionsausgabe_gerendert() {
  # G8: die Untergruppen-Kopfzeile im Delegate muss aus dem, was
  # buildGroupedRows() liefert, gerendert werden ("modelData.subgroup",
  # "modelData.indent") -- nicht aus einer eigenen, im Delegate
  # nachgerechneten Groesse. Die Kopfzeile unterscheidet Anbieter- von
  # Untergruppen-Kopfzeile ueber "modelData.subgroup !== undefined", und
  # die Einrueckung (auch der Modellzeile) haengt an "modelData.indent".
  hdr="$(grep -A10 'visible: row.isHeader' "$ROOT/ModelSheet.qml")"
  assert_contains "$hdr" "modelData.subgroup"
  assert_contains "$hdr" "modelData.indent"

  mdl="$(grep -A10 'visible: !row.isHeader' "$ROOT/ModelSheet.qml")"
  assert_contains "$mdl" "modelData.indent"
}

test_genau_drei_ebenen_keine_vierte() {
  # G8: hoechstens indent 0/1/2 duerfen je vorkommen -- ein "indent: 3"
  # (eine Unter-Unterteilung EINER Untergruppe) waere die im Auftrag
  # ausdruecklich ausgeschlossene vierte Ebene.
  bad="$(grep -n 'indent: 3' "$ROOT/ModelSheet.qml" || true)"
  assert_eq "$bad" ""
}

test_untergruppen_schwelle_arithmetik() {
  # ACHTUNG (ehrlich, nicht schoengeredet): dies ist KEIN Aufruf der echten
  # QML-Funktion buildGroupedRows() -- dieselbe Einschraenkung wie bei
  # test_gruppierung_arithmetik_erstauftreten_und_sterne oben (ModelSheet.qml
  # importiert qs.Commons/qs.Ui, ausserhalb der laufenden Omarchy-Shell
  # nicht aufloesbar). Was hier steht, ist eine PARALLELE Nachrechnung
  # derselben Schwellen- und Namens-Arithmetik in Bash -- konstruiert, um
  # GENAU die auf dieser Maschine gemessene reale Verteilung nachzubilden
  # (siehe Auftrag): opencode 64 Modelle (gpt 20, claude 12, gemini 7,
  # kimi 4, muse 3, minimax 3, zwei weitere qualifizierende Gruppen zu je 5
  # macht 10, plus 5 Einzelgaenger -- 20+12+7+4+3+3+10+5 = 64), lmstudio 46
  # (qwen 11, google 10, mistralai 6, nvidia 4, zai-org 2, openai 2, eine
  # weitere qualifizierende Gruppe zu 4, plus 7 Einzelgaenger --
  # 11+10+6+4+2+2+4+7 = 46), openai 13 (alle 13 IDs ergeben dieselbe
  # Untergruppe "gpt" -- eine einzige Gruppe, keine Trennung). Deckt die
  # RECHENREGEL ab (Namensquelle je ID-Form, die Zwei-mal-zwei-Schwelle,
  # Einzelgaenger-Reihenfolge NACH allen Untergruppen) -- nicht den
  # tatsaechlich in ModelSheet.qml ausgefuehrten Bytecode; die beiden
  # Textregeln oben plus qmllint plus die visuelle Kontrolle im Panel
  # schliessen diese Luecke.
  subgroup_bash() {  # subgroup_bash <id>
    local id="$1"
    IFS='/' read -ra segs <<< "$id"
    local n="${#segs[@]}"
    if [ "$n" -ge 3 ]; then printf '%s' "${segs[1]}"; return 0; fi
    local last="${segs[$((n - 1))]}"
    printf '%s' "${last%%-*}"
  }

  # Namensquelle je ID-Form pruefen, unabhaengig vom Schwellenlauf unten.
  assert_eq "$(subgroup_bash 'lmstudio/google/gemma-4-12b')" "google"
  assert_eq "$(subgroup_bash 'opencode/claude-opus-4-5')" "claude"

  # gen_ids <provider> <subgroup-praefix> <anzahl> <dreisegmentig:0|1>
  # gibt eine ID je Zeile auf stdout aus -- erzeugt IDs beider im Auftrag
  # genannten Formen: "provider/vendor/model" (dreisegmentig) oder
  # "provider/name-N" (zweisegmentig, Name vor Bindestrich = Praefix).
  gen_ids() {
    local provider="$1" prefix="$2" count="$3" threeseg="$4" k
    for ((k = 1; k <= count; k++)); do
      if [ "$threeseg" = "1" ]; then
        printf '%s/%s/model-%d\n' "$provider" "$prefix" "$k"
      else
        printf '%s/%s-%d\n' "$provider" "$prefix" "$k"
      fi
    done
  }

  # order/sizes/qualifying/subdivided sind absichtlich GLOBAL innerhalb
  # dieser Testfunktion (kein "local"/eigenes "declare" in
  # provider_grouping_bash) -- bash reicht sie ueber dynamischen Scope an
  # die aufgerufene Funktion durch, und der Aufrufer liest sie danach
  # weiter aus (die Reihenfolge-Pruefung fuer lmstudio unten braucht genau
  # das). Direkte Argumente statt einer Pipe/stdin: eine Pipe wuerde
  # provider_grouping_bash in eine eigene Subshell stellen, in der jede
  # Zuweisung an diese Variablen verlorenginge, sobald die Pipe endet.
  declare -A sizes=()
  order=()
  qualifying=0
  subdivided=0

  provider_grouping_bash() {  # provider_grouping_bash <id...>
    sizes=()
    order=()
    local id sub
    for id in "$@"; do
      sub="$(subgroup_bash "$id")"
      if [ -z "${sizes[$sub]:-}" ]; then order+=("$sub"); fi
      sizes[$sub]=$(( ${sizes[$sub]:-0} + 1 ))
    done
    qualifying=0
    local s
    for s in "${order[@]}"; do
      [ "${sizes[$s]}" -ge 2 ] && qualifying=$((qualifying + 1))
    done
    subdivided=0
    # ACHTUNG (set -e-Falle): "[ ... ] && subdivided=1" als LETZTE Anweisung
    # dieser Funktion wuerde deren eigenen Exit-Status auf den der
    # gescheiterten Bedingung setzen, sobald qualifying < 2 -- ein bare
    # Funktionsaufruf (nicht in einer if/while-Bedingung) mit diesem Status
    # reisst unter "set -e" den ganzen Test ab, OHNE je einen assert_*
    # auszuloesen (leerer Fehlschlag, schwer zu diagnostizieren -- genau so
    # ist die erste Fassung dieses Tests tatsaechlich gescheitert). Ein
    # richtiges if/then/fi ist dagegen unter "set -e" ausdruecklich
    # ausgenommen, auch ohne "else".
    if [ "$qualifying" -ge 2 ]; then subdivided=1; fi
  }

  # -- openai: 13 IDs, alle "gpt" -- eine einzige Gruppe trennt nichts,
  #    bleibt flach. --------------------------------------------------
  mapfile -t openai_ids < <(gen_ids openai gpt 13 0)
  assert_eq "${#openai_ids[@]}" "13"
  provider_grouping_bash "${openai_ids[@]}"
  assert_eq "$subdivided" "0"

  # -- opencode: reale Verteilung (zweisegmentige IDs, Name vor
  #    Bindestrich). gpt/claude/gemini/kimi/muse/minimax je >=2 Mitglieder
  #    (qualifizierend), otherA/otherB stehen fuer die im Auftrag mit "..."
  #    angedeuteten weiteren qualifizierenden Gruppen, solo1..5 sind die
  #    fuenf Einzelgaenger. Summe: 20+12+7+4+3+3+5+5+5*1 = 64. -----------
  mapfile -t oc_ids < <(
    gen_ids opencode gpt 20 0
    gen_ids opencode claude 12 0
    gen_ids opencode gemini 7 0
    gen_ids opencode kimi 4 0
    gen_ids opencode muse 3 0
    gen_ids opencode minimax 3 0
    gen_ids opencode otherA 5 0
    gen_ids opencode otherB 5 0
    gen_ids opencode solo1 1 0
    gen_ids opencode solo2 1 0
    gen_ids opencode solo3 1 0
    gen_ids opencode solo4 1 0
    gen_ids opencode solo5 1 0
  )
  assert_eq "${#oc_ids[@]}" "64"
  provider_grouping_bash "${oc_ids[@]}"
  assert_eq "$subdivided" "1"

  # -- lmstudio: reale Verteilung (dreisegmentige IDs, mittleres Segment).
  #    qwen/google/mistralai/nvidia/zai-org/openai qualifizierend, otherA
  #    steht fuer die weitere angedeutete qualifizierende Gruppe, solo1..7
  #    sind die sieben Einzelgaenger. Summe: 11+10+6+4+2+2+4+7*1 = 46. ---
  mapfile -t lm_ids < <(
    gen_ids lmstudio qwen 11 1
    gen_ids lmstudio google 10 1
    gen_ids lmstudio mistralai 6 1
    gen_ids lmstudio nvidia 4 1
    gen_ids lmstudio zai-org 2 1
    gen_ids lmstudio openai 2 1
    gen_ids lmstudio otherA 4 1
    gen_ids lmstudio solo1 1 1
    gen_ids lmstudio solo2 1 1
    gen_ids lmstudio solo3 1 1
    gen_ids lmstudio solo4 1 1
    gen_ids lmstudio solo5 1 1
    gen_ids lmstudio solo6 1 1
    gen_ids lmstudio solo7 1 1
  )
  assert_eq "${#lm_ids[@]}" "46"
  provider_grouping_bash "${lm_ids[@]}"
  assert_eq "$subdivided" "1"

  # Reihenfolge: alle qualifizierenden Untergruppen (Erstauftreten) muessen
  # VOR dem ersten Einzelgaenger-Praefix stehen -- exakt die im Auftrag
  # verlangte Platzierung "Einzelgaenger NACH allen Untergruppen".
  local last_qualifying_index=-1 first_solo_index=-1 i
  for i in "${!order[@]}"; do
    if [ "${sizes[${order[$i]}]}" -ge 2 ]; then
      last_qualifying_index="$i"
    elif [ "$first_solo_index" -eq -1 ]; then
      first_solo_index="$i"
    fi
  done
  assert_eq "$([ "$first_solo_index" -gt "$last_qualifying_index" ] && echo ja || echo nein)" "ja"
}

test_schwellenwerte_stehen_fest() {
  # Die Schwelle ist die tragende Regel der dritten Ebene: unterteilt wird
  # nur, wenn mindestens ZWEI Untergruppen mit je mindestens ZWEI Modellen
  # entstehen. Der Bash-Test daneben rechnet die Arithmetik nur NACH und
  # merkt deshalb nicht, wenn jemand die Konstante im QML aufweicht
  # (">= 2" -> ">= 1"). Diese Regel schliesst genau diese Luecke: sie liest
  # die beiden Vergleiche im Quelltext.
  block="$(sed -n '/function buildGroupedRows/,/^  }/p' "$ROOT/ModelSheet.qml")"
  assert_contains "$block" "length >= 2"
  assert_contains "$block" "qualifying >= 2"
}

test_modellzeile_zeigt_ueber_kuerzungsfunktion() {
  # G9 (Anzeige-Kuerzung): die Modellzeile darf die ID nicht mehr direkt
  # zeigen -- sie muss durch modelDisplayText() laufen. Zwei Pruefungen,
  # wie bei test_pfad_fallback_wird_gekuerzt (Panel.qml/shortPath) oben:
  #   1) die Funktion muss ueberhaupt (genau einmal) definiert sein -- ein
  #      Loeschen der Funktion, bei dem irgendwo noch "modelDisplayText"
  #      als Text auftaucht, faellt hier durch, weil hier nach der
  #      Funktions-SIGNATUR gesucht wird, nicht nur nach dem Namen.
  #   2) die Text-Bindung der Modellzeile muss sheet.modelDisplayText(...)
  #      aufrufen UND darf "modelData.model.id" nicht mehr direkt enthalten
  #      -- ein Bypass, der die Funktion zwar behaelt, die Bindung aber
  #      wieder auf die rohe ID zurueckstellt, faellt hier durch.
  #      "-m1" nimmt bewusst nur den ERSTEN Treffer von "visible:
  #      !row.isHeader" -- der Stern-Knopf weiter unten traegt dieselbe
  #      Bedingung und referenziert "modelData.model.id" legitim (fuer
  #      "starred"/"starToggled"), das darf diese Regel nicht mit erfassen.
  def_count="$(grep -c 'function modelDisplayText(row)' "$ROOT/ModelSheet.qml")"
  assert_eq "$def_count" "1"

  mdl="$(grep -m1 -A10 'visible: !row.isHeader' "$ROOT/ModelSheet.qml")"
  assert_contains "$mdl" "sheet.modelDisplayText(modelData)"
  assert_not_contains "$mdl" "modelData.model.id"
}

test_kuerzung_verschluckt_niemals_herstellerpraefix_und_erhaelt_einzelgaenger() {
  # G9, die zwei bewussten Entscheidungen aus dem Auftrag -- als
  # Quelltext-Regel, nicht nur als Beobachtung am Ende: eine reine
  # Text-Probe (ein einzelnes gerendertes Beispiel ansehen) koennte durch
  # ein zufaellig passend gewaehltes Testmodell beide Faelle uebersehen,
  # waehrend eine Aufweichung im Code trotzdem drinsteckt und beim naechsten
  # Modell zuschlaegt. Deshalb liest diese Regel die drei betroffenen
  # Fundstellen direkt im Funktionskoerper von buildGroupedRows():
  #
  #   1) Ein Untergruppen-Mitglied bekommt headerSegments NUR dann 2, wenn
  #      SEINE EIGENE ID mindestens drei Segmente hat
  #      ("memberSegs.length >= 3 ? 2 : 1") -- eine Untergruppe aus der
  #      Namensheuristik (zweisegmentige ID, z.B. "opencode/gpt-5-codex")
  #      bekommt headerSegments: 1 und behaelt damit den Herstellerteil
  #      ("gpt-5-codex" statt "5-codex"). Ein Aufweichen auf ein festes "2"
  #      wuerde genau dieses Verschlucken verursachen.
  #   2) Sowohl der Einzelgaenger-Zweig als auch der Nicht-Unterteilt-Zweig
  #      muessen headerSegments FEST auf 1 setzen -- keine der beiden
  #      Zeilenarten hat eine eigene Kopfzeile, die einen Herstellerteil
  #      schon genannt haette.
  block="$(sed -n '/^  function buildGroupedRows(models, expanded) {/,/^  }/p' "$ROOT/ModelSheet.qml")"
  assert_contains "$block" 'memberSegs.length >= 3 ? 2 : 1'
  assert_contains "$block" 'starredFirst[j], indent: 1, headerSegments: 1'
  assert_contains "$block" 'singletons[t], indent: 1, headerSegments: 1'
}

test_modellzeile_kuerzungsarithmetik_ueber_alle_faelle() {
  # ACHTUNG (ehrlich, nicht schoengeredet): dies ist KEIN Aufruf der echten
  # QML-Funktionen modelDisplayText() und buildGroupedRows() aus
  # ModelSheet.qml -- dieselbe Einschraenkung wie bei
  # test_shortpath_segmentarithmetik und test_untergruppen_schwelle_arithmetik
  # oben (ModelSheet.qml importiert qs.Commons/qs.Ui, ausserhalb der
  # laufenden Omarchy-Shell nicht aufloesbar). Was hier steht, ist eine
  # PARALLELE Nachrechnung derselben zwei Rechenregeln in Bash: wie viele
  # fuehrende ID-Segmente eine Kopfzeile schon zeigt (headerSegments, aus
  # buildGroupedRows()) und wie modelDisplayText() genau diese Anzahl vorne
  # abschneidet -- gegen fuenf IDs aus der auf dieser Maschine real
  # gemessenen Verteilung (siehe test_untergruppen_schwelle_arithmetik),
  # je einen Fall aus der Tabelle im Auftrag. Deckt die RECHENREGEL ab --
  # nicht den tatsaechlich in ModelSheet.qml ausgefuehrten Bytecode; die
  # beiden Textregeln oben plus qmllint plus die visuelle Kontrolle im
  # Panel schliessen diese Luecke.
  header_segments_bash() {  # header_segments_bash <situation> <id>
    local situation="$1" id="$2"
    case "$situation" in
      subgroup)
        local segs
        IFS='/' read -ra segs <<< "$id"
        if [ "${#segs[@]}" -ge 3 ]; then printf '2'; else printf '1'; fi
        ;;
      singleton|flat) printf '1' ;;
    esac
  }

  model_display_bash() {  # model_display_bash <id> <headerSegments> <grouped:0|1>
    local id="$1" hs="$2" grouped="$3" segs rest joined
    if [ "$grouped" = "0" ]; then printf '%s' "$id"; return 0; fi
    IFS='/' read -ra segs <<< "$id"
    rest=("${segs[@]:$hs}")
    joined="$(IFS=/; printf '%s' "${rest[*]}")"
    printf '%s' "$joined"
  }

  # Fall 1: Untergruppen-Kopfzeile aus dem mittleren Segment (dreisegmentige
  # ID) -- Anbieter UND Hersteller stehen schon in Kopfzeilen, nur der
  # Modellname bleibt uebrig.
  local id1="lmstudio/google/gemma-3-12b" hs1
  hs1="$(header_segments_bash subgroup "$id1")"
  assert_eq "$hs1" "2"
  assert_eq "$(model_display_bash "$id1" "$hs1" 1)" "gemma-3-12b"

  # Fall 2: Untergruppen-Kopfzeile aus der Namensheuristik (zweisegmentige
  # ID) -- nur der Anbieter steht in einer Kopfzeile, der Herstellerteil
  # ("gpt") ist eine Vermutung der Heuristik, keine Kopfzeile nannte ihn.
  local id2="opencode/gpt-5-codex" hs2
  hs2="$(header_segments_bash subgroup "$id2")"
  assert_eq "$hs2" "1"
  assert_eq "$(model_display_bash "$id2" "$hs2" 1)" "gpt-5-codex"

  # Fall 3: Einzelgaenger (dreisegmentige ID, keine eigene Kopfzeile) --
  # der Herstellerteil ("liquid") bleibt sichtbar, weil ihn keine Kopfzeile
  # schon genannt hat.
  local id3="lmstudio/liquid/lfm-x" hs3
  hs3="$(header_segments_bash singleton "$id3")"
  assert_eq "$hs3" "1"
  assert_eq "$(model_display_bash "$id3" "$hs3" 1)" "liquid/lfm-x"

  # Fall 4: Anbieter bleibt unterteilungsfrei -- nur der Anbieter steht in
  # einer Kopfzeile.
  local id4="openai/gpt-5.4" hs4
  hs4="$(header_segments_bash flat "$id4")"
  assert_eq "$hs4" "1"
  assert_eq "$(model_display_bash "$id4" "$hs4" 1)" "gpt-5.4"

  # Fall 5: Suchmodus (dieselbe ID wie Fall 4) -- keine einzige Kopfzeile
  # ist sichtbar, die volle ID bleibt stehen. "headerSegments" ist hier
  # ohne Bedeutung, model_display_bash ignoriert es im Suchmodus (grouped:0)
  # ebenso wie modelDisplayText() selbst.
  assert_eq "$(model_display_bash "$id4" "$hs4" 0)" "openai/gpt-5.4"
}

run_tests
