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
  bad="$(grep -nE 'command[[:space:]]*[:=]' "$ROOT"/*.qml | grep -v 'root.runner' || true)"
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
  bad="$(for f in "$ROOT"/*.qml "$ROOT"/bin/*; do
           sed -E 's/^[[:space:]]*#.*$//; s/([[:space:]])#.*$/\1/' "$f" \
             | grep -noP '(?<!/usr/bin/)(?<![[:alnum:]_.-])(bash|timeout|head|jq|sqlite3|hyprctl)\b' \
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
  stopped="$(sed -n '/Component.onDestruction/,/^  }/p' "$ROOT/Panel.qml" \
             | grep -oE '[a-zA-Z]+Proc' | sort -u)"
  assert_eq "$declared" "$stopped"
}

test_zahlenwerte_aus_einstellungen_sind_begrenzt() {
  # Ein Wert aus shell.json wandert in eine Kommandozeile. Er darf nur als
  # eingeschraenkte Zahl dorthin gelangen, nie als Zeichenkette.
  out="$(grep -A2 'readonly property int recentCount' "$ROOT/Panel.qml")"
  assert_contains "$out" "Math.max"
  assert_contains "$out" "Math.min"
  out="$(grep -A2 'readonly property int refreshHours' "$ROOT/Panel.qml")"
  assert_contains "$out" "Math.min"
}

test_mausrad_ist_unbelegt() {
  bad="$(grep -n 'onWheel' "$ROOT"/*.qml || true)"
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

run_tests
