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

run_tests
