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
  # G8 (vorher G6, ueberholt durch den Screenshot-Fund "…nfig/opencode"):
  # der Pfad-Fallback in der Namenszeile (der Zweig OHNE echten Namen) lief
  # bis zu diesem Fix durch root.shortPath() direkt und verliess sich fuer
  # eine zu schmale Zeile allein auf ElideLeft, das mitten in einem Segment
  # abschneiden konnte. Jetzt laeuft er durch root.fitPath(), das aus
  # root.pathCandidates() (drei/zwei/ein Segment, siehe
  # test_pfadleiter_kandidaten unten) die breiteste noch passende
  # Kandidatin waehlt. shortPath(p) selbst bleibt trotzdem als eigene,
  # oeffentliche Funktion bestehen -- pathCandidates() ruft fuer die
  # Rechenregel intern segmentsAtMost(p, n) auf, nicht mehr shortPath()
  # selbst, aber die Funktionssignatur ist Teil des in G6 dokumentierten
  # Vertrags und bleibt Pruefgegenstand. Drei Pruefungen, damit ein
  # Umgehen an keiner der moeglichen Stellen unbemerkt bleibt:
  #   1) die Bindung selbst muss root.fitPath(modelData.displayPath, ...)
  #      aufrufen (ein Bypass, der wieder direkt root.shortPath(...) oder
  #      das nackte modelData.displayPath einsetzt, faellt hier durch)
  #   2) die Funktion fitPath(p, availableWidth, metrics) muss ueberhaupt
  #      definiert sein (nach Funktions-SIGNATUR gesucht, nicht nur nach
  #      dem Namen)
  #   3) die Funktion shortPath(p) muss weiterhin definiert sein
  out="$(grep -A6 'modelData.name !== modelData.displayPath' "$ROOT/Panel.qml")"
  assert_contains "$out" "root.fitPath(modelData.displayPath, rowLine.width - rowMarker.width, pathMetrics)"

  fit_count="$(grep -c 'function fitPath(p, availableWidth, metrics)' "$ROOT/Panel.qml")"
  assert_eq "$fit_count" "1"

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

test_pfadleiter_kandidaten() {
  # pathCandidates() in Panel.qml ist reine String-Arithmetik ohne
  # Datei-IO -- dieselbe Einschraenkung wie bei
  # test_shortpath_segmentarithmetik oben, aus demselben Grund (siehe
  # dort): Panel.qml importiert Quickshell.Io und qs.Commons/qs.Ui, die
  # ausserhalb der laufenden Omarchy-Shell nicht aufloesbar sind.
  #
  # ACHTUNG (ehrlich, nicht schoengeredet): dies ist KEIN Aufruf der
  # echten QML-Funktion. Was hier steht, ist eine PARALLELE Nachrechnung
  # derselben Leiter-Arithmetik in Bash: drei Stufen (drei/zwei/ein
  # Segment), jede Stufe dieselbe Rechenregel wie shortPath() mit einer
  # variablen Segmentzahl statt der festen 3, mit aufeinanderfolgenden
  # Duplikaten (der Pfad hat gar nicht so viele Segmente, dass bei dieser
  # Stufe etwas wegfiele) herausgefiltert. Sie deckt die Rechenregel ab --
  # nicht den tatsaechlich in Panel.qml ausgefuehrten Bytecode. Eine
  # Aenderung an pathCandidates(), die diese Rechenregel nicht mitaendert,
  # bleibt fuer DIESEN Test unsichtbar; test_pfad_fallback_wird_gekuerzt
  # (Funktionssignaturen und Aufrufstelle) plus
  # test_textmetrics_traegt_labelschrift plus qmllint plus die visuelle
  # Kontrolle im Panel schliessen diese Luecke.
  ellipsis="$(printf '…')"

  segments_at_most_bash() {
    local p="$1" n="$2" s
    if [ "${#p}" -gt 1 ] && [ "${p: -1}" = "/" ]; then s="${p%/}"; else s="$p"; fi
    local segs=()
    IFS='/' read -ra segs <<< "$s"
    local total="${#segs[@]}"
    if [ "$total" -le "$n" ]; then printf '%s' "$p"; return 0; fi
    local start=$((total - n))
    local lastn=("${segs[@]:$start:$n}")
    local joined
    joined="$(IFS=/; printf '%s' "${lastn[*]}")"
    printf '%s/%s' "$ellipsis" "$joined"
  }

  path_candidates_bash() {
    local p="$1" n cur prev=""
    for n in 3 2 1; do
      cur="$(segments_at_most_bash "$p" "$n")"
      if [ "$n" -eq 3 ] || [ "$cur" != "$prev" ]; then printf '%s\n' "$cur"; fi
      prev="$cur"
    done
  }

  # Fuenf Segmente (dasselbe Beispiel wie in test_shortpath_segmentarithmetik):
  # alle drei Stufen sind voneinander verschieden und tragen alle das
  # "…/"-Praefix -- genau die drei-, zwei- und einsegmentigen Formen.
  mapfile -t got5 < <(path_candidates_bash '~/Development/Sources/Extern/shannon')
  assert_eq "${#got5[@]}" "3"
  assert_eq "${got5[0]}" "${ellipsis}/Sources/Extern/shannon"
  assert_eq "${got5[1]}" "${ellipsis}/Extern/shannon"
  assert_eq "${got5[2]}" "${ellipsis}/shannon"

  # Zwei Segmente: die Drei-Segment-Stufe ist identisch mit der
  # Zwei-Segment-Stufe (beide der unveraenderte Pfad) -- also KEINE eigene
  # Drei-Segment-Kandidatin, nur zwei Eintraege insgesamt.
  mapfile -t got2 < <(path_candidates_bash '~/foo')
  assert_eq "${#got2[@]}" "2"
  assert_eq "${got2[0]}" "~/foo"
  assert_eq "${got2[1]}" "${ellipsis}/foo"

  # Ein einzelnes Segment: nichts zum Wegwerfen, ein einziger Eintrag.
  mapfile -t got1 < <(path_candidates_bash '~')
  assert_eq "${#got1[@]}" "1"
  assert_eq "${got1[0]}" "~"
}

test_textmetrics_traegt_labelschrift() {
  # G8: fitPath() misst jede Kandidatin mit dem TextMetrics-Element, das
  # die Aufrufstelle uebergibt -- eine TextMetrics mit einer anderen
  # Schriftfamilie oder -groesse als das Label misst eine Breite, die mit
  # der tatsaechlich gerenderten nichts zu tun hat, und die Messung waere
  # bedeutungslos. Das TextMetrics-Element in rowLine muss deshalb
  # woertlich dieselbe Familie und Groesse tragen wie das Label
  # (root.fontFam / Style.font.body).
  block="$(sed -n '/id: rowLine/,/^                }/p' "$ROOT/Panel.qml")"
  tm_count="$(printf '%s' "$block" | grep -c 'TextMetrics {')"
  assert_eq "$tm_count" "1"

  tm="$(printf '%s' "$block" | grep -A3 'TextMetrics {')"
  assert_contains "$tm" "font.family: root.fontFam"
  assert_contains "$tm" "font.pixelSize: Style.font.body"
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

test_favoriten_arithmetik_ueber_alle_regeln() {
  # ACHTUNG (ehrlich, nicht schoengeredet): dies ist KEIN Aufruf der echten
  # QML-Funktion buildGroupedRows() aus ModelSheet.qml -- dieselbe
  # Einschraenkung wie bei test_gruppierung_arithmetik_erstauftreten_und_sterne
  # und den anderen "*_arithmetik"-Tests oben (ModelSheet.qml importiert
  # qs.Commons/qs.Ui, ausserhalb der laufenden Omarchy-Shell nicht
  # aufloesbar). Was hier steht, ist eine PARALLELE Nachrechnung derselben
  # Regeln (Change 2, Favoriten-Gruppe) in Bash: keine Kopfzeile ohne
  # mindestens ein markiertes Modell; mit einem bzw. zwei markierten
  # Modellen steht die Kopfzeile an POSITION 0 mit der jeweiligen Anzahl;
  # die Anbieter-Anzahl zaehlt IMMER alle Modelle des Anbieters,
  # unabhaengig von Sternen; ein markiertes Modell landet zweimal in der
  # Zeilenliste (einmal unter Favourites mit headerSegments 0, einmal in
  # seiner Anbietergruppe mit headerSegments 1). Deckt die RECHENREGEL ab
  # -- nicht den tatsaechlich in ModelSheet.qml ausgefuehrten Bytecode; die
  # Textregeln unten plus qmllint plus die visuelle Kontrolle im Panel
  # schliessen diese Luecke.
  declare -A FAV_PROV_COUNT=()
  FAV_PROV_ORDER=()
  FAV_ROWS=()

  # build_favourite_rows_bash <id:provider:starred> ... -- baut eine
  # flache Zeilenliste in FAV_ROWS ("header:favourites:<n>" bzw.
  # "model:<id>:<headerSegments>" fuer die Favoriten-Zeilen,
  # "header:provider:<name>:<n>" fuer jede Anbieter-Kopfzeile, danach ein
  # "model:<id>:1" je Mitglied) sowie die Anbieter-Anzahl in
  # FAV_PROV_COUNT -- genau wie buildGroupedRows() es taete, wenn ALLE
  # Gruppen (Favoriten und jeder Anbieter) aufgeklappt waeren.
  build_favourite_rows_bash() {
    FAV_PROV_COUNT=()
    FAV_PROV_ORDER=()
    FAV_ROWS=()
    local spec id provider starred
    local -A prov_members=()
    local -a favourites=()

    for spec in "$@"; do
      IFS=':' read -r id provider starred <<< "$spec"
      if [ -z "${FAV_PROV_COUNT[$provider]:-}" ]; then
        FAV_PROV_COUNT[$provider]=0
        FAV_PROV_ORDER+=("$provider")
      fi
      FAV_PROV_COUNT[$provider]=$(( ${FAV_PROV_COUNT[$provider]:-0} + 1 ))
      prov_members[$provider]="${prov_members[$provider]:-}$id "
      if [ "$starred" = "1" ]; then favourites+=("$id"); fi
    done

    if [ "${#favourites[@]}" -gt 0 ]; then
      FAV_ROWS+=("header:favourites:${#favourites[@]}")
      local fid
      for fid in "${favourites[@]}"; do
        FAV_ROWS+=("model:$fid:0")
      done
    fi

    local p m
    for p in "${FAV_PROV_ORDER[@]}"; do
      FAV_ROWS+=("header:provider:$p:${FAV_PROV_COUNT[$p]}")
      for m in ${prov_members[$p]}; do
        FAV_ROWS+=("model:$m:1")
      done
    done
  }

  count_favourite_occurrences() {  # count_favourite_occurrences <id>
    local id="$1" n=0 r
    for r in "${FAV_ROWS[@]}"; do
      case "$r" in "model:$id:"*) n=$((n + 1)) ;; esac
    done
    printf '%s' "$n"
  }

  # -- keine Sterne: keine Favoriten-Kopfzeile, Anbieter-Anzahlen wie
  #    gehabt. --------------------------------------------------------
  build_favourite_rows_bash "opencode/a:opencode:0" "lmstudio/x:lmstudio:0"
  assert_eq "${FAV_ROWS[0]}" "header:provider:opencode:1"
  no_fav_header="ja"
  for r in "${FAV_ROWS[@]}"; do
    case "$r" in header:favourites:*) no_fav_header="nein" ;; esac
  done
  assert_eq "$no_fav_header" "ja"
  assert_eq "${FAV_PROV_COUNT[opencode]}" "1"
  assert_eq "${FAV_PROV_COUNT[lmstudio]}" "1"

  # -- ein Stern: Kopfzeile an Position 0 mit Anzahl 1; die Anbieter-
  #    Anzahl bleibt bei 2 (nicht 1 -- das markierte Modell zaehlt
  #    weiterhin mit); es erscheint zweimal (Favoriten + Anbietergruppe),
  #    das unmarkierte Geschwistermodell nur einmal; die Favoriten-Zeile
  #    traegt headerSegments 0. ------------------------------------------
  build_favourite_rows_bash "opencode/a:opencode:1" "opencode/b:opencode:0" "lmstudio/x:lmstudio:0"
  assert_eq "${FAV_ROWS[0]}" "header:favourites:1"
  assert_eq "${FAV_PROV_COUNT[opencode]}" "2"
  assert_eq "${FAV_PROV_COUNT[lmstudio]}" "1"
  assert_eq "$(count_favourite_occurrences 'opencode/a')" "2"
  assert_eq "$(count_favourite_occurrences 'opencode/b')" "1"
  IFS=':' read -r hs_kind hs_id hs_segments <<< "${FAV_ROWS[1]}"
  assert_eq "$hs_kind" "model"
  assert_eq "$hs_id" "opencode/a"
  assert_eq "$hs_segments" "0"

  # -- zwei Sterne (in zwei verschiedenen Anbietern): Anzahl 2, BEIDE
  #    Anbieter-Anzahlen bleiben unveraendert, BEIDE markierten Modelle
  #    erscheinen je zweimal. --------------------------------------------
  build_favourite_rows_bash "opencode/a:opencode:1" "opencode/b:opencode:0" \
    "lmstudio/x:lmstudio:1" "lmstudio/y:lmstudio:0"
  assert_eq "${FAV_ROWS[0]}" "header:favourites:2"
  assert_eq "${FAV_PROV_COUNT[opencode]}" "2"
  assert_eq "${FAV_PROV_COUNT[lmstudio]}" "2"
  assert_eq "$(count_favourite_occurrences 'opencode/a')" "2"
  assert_eq "$(count_favourite_occurrences 'lmstudio/x')" "2"
  assert_eq "$(count_favourite_occurrences 'opencode/b')" "1"
  assert_eq "$(count_favourite_occurrences 'lmstudio/y')" "1"
}

test_change1_anzahl_in_klammern() {
  # Change 1: jede Kopfzeilen-Anzahl steht jetzt in Klammern, z.B.
  # "opencode (64)" statt "opencode 64" -- rein darstellerisch, aendert
  # weder buildGroupedRows() noch irgendeine Zaehlung. Zwei Pruefungen: die
  # neue Klammer-Schreibweise ist vorhanden, UND die alte (Leerzeichen ohne
  # Klammern) ist verschwunden -- ein Refactor, der
  # '+ " (" + modelData.count + ")"' wieder durch '+ " " + modelData.count'
  # ersetzt, faellt hier durch.
  full="$(cat "$ROOT/ModelSheet.qml")"
  assert_contains "$full" '+ " (" + modelData.count + ")"'
  assert_not_contains "$full" '+ " " + modelData.count'
}

test_favoriten_wird_in_gruppierungsfunktion_gebaut_und_zuerst_platziert() {
  # Change 2: die Favoriten-Gruppe muss INNERHALB von buildGroupedRows()
  # entstehen (nicht als eigene Kopie in "visibleRows" daneben, derselbe
  # Grundsatz wie bei der Untergruppen-Schwelle, siehe
  # test_untergruppen_schwelle_lebt_in_gruppierungsfunktion oben) UND als
  # ALLERERSTE Zeile -- vor der Anbieter-Schleife ("for (var g = 0; g <
  # order.length; g++)").
  body="$(sed -n '/^  function buildGroupedRows(models, expanded) {/,/^  }/p' "$ROOT/ModelSheet.qml")"
  assert_contains "$body" 'kind: "header", favourites: true'

  before_loop="$(printf '%s\n' "$body" | sed -n '/var rows = \[\]/,/for (var g = 0; g < order.length; g++) {/p')"
  assert_contains "$before_loop" 'kind: "header", favourites: true'

  vr="$(grep -A4 'readonly property var visibleRows:' "$ROOT/ModelSheet.qml")"
  assert_not_contains "$vr" 'favourites: true'
}

test_favoriten_nur_bei_stern_und_anbieterzahl_bleibt_voll() {
  # Regel "existiert nur bei mindestens einem Stern": das Gate
  # "if (favourites.length > 0)" muss im Funktionskoerper stehen. Regel
  # "Anbieterzahl aendert sich nicht": die Favoriten-Liste muss aus der
  # VOLLEN, ungefilterten "models" gebaut werden ("models.filter(...)"),
  # NICHT aus "buckets"/"order" -- und die Anbieter-Kopfzeile muss weiterhin
  # "bucket.length" zeigen (die unveraenderte, bereits vor dieser Aenderung
  # bestehende Zaehlung ueber ALLE Moditglieder des Anbieters).
  body="$(sed -n '/^  function buildGroupedRows(models, expanded) {/,/^  }/p' "$ROOT/ModelSheet.qml")"
  assert_contains "$body" 'if (favourites.length > 0) {'
  assert_contains "$body" 'var favourites = models.filter(function (x) { return x.starred })'
  assert_contains "$body" 'for (var i = 0; i < models.length; i++) {'
  assert_contains "$body" 'count: bucket.length'
}

test_favoriten_zeilen_zeigen_volle_id_ohne_dritte_ebene() {
  # Regel "volle ID, nichts abgeschnitten": die Favoriten-Modellzeile
  # traegt headerSegments 0 (modelDisplayText() schneidet damit nichts ab,
  # siehe dortiger Kommentar). Regel "keine dritte Ebene": dieselbe Zeile
  # traegt indent 1 (nie 2) und keinen eigenen "subgroup"-Schluessel -- die
  # woertliche Fundstelle deckt alle drei auf einmal ab, ein Aufweichen an
  # irgendeiner der drei Stellen aendert die Zeile und faellt hier durch.
  body="$(sed -n '/^  function buildGroupedRows(models, expanded) {/,/^  }/p' "$ROOT/ModelSheet.qml")"
  assert_contains "$body" 'rows.push({ kind: "model", model: favourites[f], indent: 1, headerSegments: 0, favourites: true })'

  # Die Kopfzeile selbst zeigt den Stern-Glyph (als \u-Escape) plus
  # "Favourites" -- als woertliche Zeichenkette im Delegate, nicht
  # errechnet aus einem Anbieter- oder Untergruppennamen.
  full="$(cat "$ROOT/ModelSheet.qml")"
  assert_contains "$full" '(modelData.favourites ? "\u2605 Favourites"'
}

test_favoriten_klappt_beim_oeffnen_immer_auf() {
  # Regel "beim Oeffnen immer aufgeklappt, wenn sie existiert": ein
  # zugeklapptes Favoriten-Kaestchen waere keine Abkuerzung. Die Zusicherung
  # muss UNABHAENGIG von "currentModel" gelten -- die Zeile
  # "sheet.expandedFavourites = hasStar" darf deshalb NICHT tiefer
  # eingerueckt sein als "sheet.expandedProviders = expanded" (6
  # Leerzeichen, direkt im "if (sheet.visible)"-Block). Eine Verschiebung
  # in den "if (found)"- oder "if (sheet.currentModel !== \"\")"-Block waere
  # 2 bzw. 4 Leerzeichen tiefer -- der ^...$-Anker (nicht nur "contains")
  # ist hier bewusst noetig: eine 8-Leerzeichen-Zeile ENTHAELT als
  # Teilkette auch 6 aufeinanderfolgende Leerzeichen vor dem Text, eine
  # reine assert_contains wuerde die Verschiebung also NICHT bemerken.
  indent_count="$(grep -c '^      sheet.expandedFavourites = hasStar$' "$ROOT/ModelSheet.qml")"
  assert_eq "$indent_count" "1"

  ov="$(sed -n '/^  onVisibleChanged: {/,/^  }/p' "$ROOT/ModelSheet.qml")"
  assert_contains "$ov" 'if (sheet.models[si].starred) { hasStar = true; break }'

  # Regel Cursor/Duplikat: ein gemerktes UND markiertes Modell steht jetzt
  # zweimal in "rows" (Favoriten + Anbietergruppe) -- die Cursor-Suche muss
  # weiterhin in der Anbietergruppe landen (bestehende Zusage bleibt
  # woertlich bestehen), nicht in der fruehereren Favoriten-Kopie.
  # Kommentarzeilen werden vorher ausgeschnitten: der Kommentar direkt
  # darueber NENNT dieselbe Teilkette ("!rows[j].favourites"), um sie zu
  # erklaeren -- eine ungefilterte Pruefung bliebe faelschlich gruen, wenn
  # nur der CODE die Bedingung verliert, der Kommentar aber (der sie ja nur
  # beschreibt) stehen bleibt. Gemessen an einer echten Probe: die
  # Bedingung im Code entfernt, waehrend der erklaerende Kommentar
  # unveraendert blieb, hielt die ungefilterte Fassung dieser Pruefung
  # faelschlich gruen.
  ov_code="$(printf '%s' "$ov" | grep -v '^[[:space:]]*//')"
  assert_contains "$ov_code" '!rows[j].favourites'
}

test_favoriten_tastatur_und_klick_loesen_toggleFavourites_aus() {
  # Regel "Tastaturverhalten wie jede andere Gruppe": Enter auf der
  # Favoriten-Kopfzeile schaltet sie um (toggleFavourites), ebenso ein
  # Klick -- exakt dieselben zwei Stellen, die auch toggleHeader() und
  # toggleSubgroup() aufrufen (siehe test_enter_auf_kopfzeile_schaltet_um_
  # statt_zu_waehlen oben).
  full="$(cat "$ROOT/ModelSheet.qml")"
  assert_contains "$full" 'if (row.favourites) sheet.toggleFavourites()'
  assert_contains "$full" 'if (modelData.favourites) sheet.toggleFavourites()'

  kp="$(grep -A10 'Keys.onReturnPressed' "$ROOT/ModelSheet.qml")"
  assert_contains "$kp" 'sheet.toggleFavourites()'
}

test_modelsheet_frei_von_nicht_ascii_bytes() {
  # Auftrags-Vorgabe: keine Nicht-ASCII-Bytes in QML -- der Stern-Glyph der
  # Favoriten-Kopfzeile muss als \u-Escape stehen, wie jede Glyphe in
  # diesem Projekt zuvor schon. Eine generelle Datei-weite Pruefung statt
  # nur der einen Fundstelle, damit ein versehentlich literal eingefuegtes
  # Sonderzeichen an JEDER Stelle auffliegt.
  bad="$(LC_ALL=C grep -nP '[^\x00-\x7F]' "$ROOT/ModelSheet.qml" || true)"
  assert_eq "$bad" ""
}

run_tests
