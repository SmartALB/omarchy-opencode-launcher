#!/usr/bin/env bash
# Die Kernzusage des Plugins, verhaltensmaessig geprueft: KEIN Aufruf
# irgendeines der vier Skripte schreibt in "~/.config/opencode/opencode.json".
#
# A2 (Abschluss-Review): abgesichert war das bisher nur durch eine
# Textregel (test_kein_schreibpfad_nach_config_opencode in qml.test.sh),
# die nach der woertlichen Zeichenkette ".config/opencode" sucht. Der
# Reviewer hat sie ausgehebelt, indem er den Pfad in zwei Stuecke zerlegte:
#     OC_DIR="$HOME/.config/open"; printf x > "${OC_DIR}code/opencode.json"
# Alle 107 Tests blieben gruen, und die Leck-Pruefung in test/run.sh sah
# diesen Pfad damals ebenfalls nicht.
#
# Diese Suite prueft stattdessen die Tatsache selbst: eine Sandbox-HOME mit
# einer BEFUELLTEN opencode.json, dann JEDER Unterbefehl aller vier
# Skripte, danach Inhalt UND mtime unveraendert. Eine Textregel kann man
# umschreiben; diese hier muesste man belogen bekommen.
#
# Die Textregel bleibt trotzdem stehen -- sie faengt den ehrlichen Fall
# billig, ohne einen ganzen Lauf.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
BIN="$DIR/../bin"

test_kein_unterbefehl_schreibt_opencodes_eigene_konfiguration() {
  # --- Die Datei, die unangetastet bleiben muss ------------------------------
  local ocdir="$HOME/.config/opencode"
  local occfg="$ocdir/opencode.json"
  mkdir -p "$ocdir"
  printf '%s' '{"$schema":"https://opencode.ai/config.json","model":"vom-benutzer/selbst-gesetzt","theme":"opencode"}' > "$occfg"
  # Ein Zeitstempel weit in der Vergangenheit: jeder Schreibzugriff, auch
  # einer mit identischem Inhalt, verschiebt ihn sichtbar. Sekundengenau
  # waere sonst ein Schreiben innerhalb derselben Sekunde unsichtbar.
  touch -d '2020-01-01 00:00:00' "$occfg"
  local before_content before_mtime
  before_content="$(cat "$occfg")"
  before_mtime="$(stat -c %Y "$occfg")"

  # --- Doppelgaenger fuer alles, was gestartet wuerde ------------------------
  make_stub opencode "printf '%s\n' openai/gpt-5-codex lmstudio/openai/gpt-oss-20b"
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
  make_stub hyprctl 'printf "%s" "[]"'
  export HYPRCTL_BIN="$SANDBOX/stub/hyprctl"
  make_stub omarchy-launch-or-focus 'exit 0'
  export OMARCHY_LAUNCH_OR_FOCUS="$SANDBOX/stub/omarchy-launch-or-focus"
  make_stub xdg-terminal-exec 'exit 0'
  make_stub setsid 'exit 0'
  make_stub uwsm-app 'exit 0'
  mkdir -p "$SANDBOX/proj"
  mkdir -p "$HOME/.config/omarchy"
  printf '{"projects":[{"name":"P","path":"%s/proj"}]}' "$SANDBOX" \
    > "$HOME/.config/omarchy/opencode-launcher.json"

  # --- Jeder Unterbefehl aller vier Skripte ---------------------------------
  # Jeder Aufruf mit "|| true": ein Fehlschlag waere hier kein Befund
  # dieser Suite (dafuer sind die vier anderen da) -- gemessen wird
  # ausschliesslich, ob dabei in opencodes Config geschrieben wurde. Ohne
  # das "|| true" bricht run_tests' set -e beim ersten Nicht-Null-Status ab
  # und die restlichen Unterbefehle liefen nie.
  "$BIN/omarchy-opencode-projects" list --json >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-models" list --json >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-models" list --json --refresh >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-store" get "$SANDBOX/proj" >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-store" set "$SANDBOX/proj" openai/gpt-5-codex >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-store" star openai/gpt-5-codex >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-store" stars >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-store" unstar openai/gpt-5-codex >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-store" unset "$SANDBOX/proj" >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-launch" "$SANDBOX/proj" --model openai/gpt-5-codex >/dev/null 2>&1 || true
  "$BIN/omarchy-opencode-launch" "$SANDBOX/proj" --model openai/gpt-5-codex --new-window >/dev/null 2>&1 || true

  # --- Beweis, dass die Aufrufe wirklich stattgefunden haben ---------------
  # Ohne das erfuellte eine Sandbox, in der ueberhaupt nichts lief, die
  # Zusicherung unten muehelos -- genau der Fehlertyp, den dieses Projekt
  # schon siebzehnmal hatte.
  [ -f "$SANDBOX/log/opencode.log" ] || fail "kein Aufruf von opencode protokolliert"
  assert_eq "$(stub_calls omarchy-launch-or-focus)" "1"

  # --- Die eigentliche Zusicherung -----------------------------------------
  [ -f "$occfg" ] || fail "opencode.json wurde entfernt"
  assert_eq "$(cat "$occfg")" "$before_content"
  assert_eq "$(stat -c %Y "$occfg")" "$before_mtime"
}

run_tests
