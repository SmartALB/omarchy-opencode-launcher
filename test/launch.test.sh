#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
LAUNCH="$DIR/../bin/omarchy-opencode-launch"

setup_launch() {
  make_stub opencode 'exit 0'
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
  make_stub omarchy-launch-or-focus 'exit 0'
  export OMARCHY_LAUNCH_OR_FOCUS="$SANDBOX/stub/omarchy-launch-or-focus"
  make_stub xdg-terminal-exec 'exit 0'
  make_stub setsid 'exit 0'
  make_stub uwsm-app 'exit 0'
  mkdir -p "$SANDBOX/proj"
}

test_start_ohne_modell_enthaelt_kein_m_flag() {
  setup_launch
  "$LAUNCH" "$SANDBOX/proj" || fail "Start fehlgeschlagen"
  # Minor aus der Review: eine leere Log-Datei erfuellt "-m fehlt" auch dann,
  # wenn ueberhaupt nichts gestartet wurde -- deshalb zusaetzlich pruefen,
  # dass der Aufruf tatsaechlich stattfand.
  assert_eq "$(stub_calls omarchy-launch-or-focus)" "1"
  assert_not_contains "$(stub_log omarchy-launch-or-focus)" " -m "
}

test_e_flag_traegt_den_aufgeloesten_opencode_pfad_nicht_bare_opencode() {
  setup_launch
  # Ruling 31: die Zeile 29/30 prueft und aufloest $OPENCODE, aber ohne diesen
  # Test wuerde ein "-e opencode" (bare, PATH-aufgeloest) unbemerkt bleiben --
  # in der frischen uwsm-app/systemd-Unit muss der PATH nicht denselben
  # Eintrag (z.B. ~/.local/bin) enthalten wie die Shell dieses Skripts, und
  # OPENCODE_BIN waere dann nur fuer die Existenzpruefung wirksam, nie fuer
  # den tatsaechlichen Start. Verifiziert per Mutationsprobe: "-e opencode"
  # bare eingesetzt liess vorher alle Tests gruen.
  "$LAUNCH" "$SANDBOX/proj" || fail "Start fehlgeschlagen"
  assert_contains "$(stub_log omarchy-launch-or-focus)" "-e $SANDBOX/stub/opencode"
}

test_start_mit_modell_enthaelt_das_m_flag() {
  setup_launch
  "$LAUNCH" "$SANDBOX/proj" --model lmstudio/openai/gpt-oss-20b || fail "Start fehlgeschlagen"
  assert_contains "$(stub_log omarchy-launch-or-focus)" "-m lmstudio/openai/gpt-oss-20b"
}

test_app_id_ist_das_erste_argument() {
  setup_launch
  . "$DIR/../bin/_common.sh"
  "$LAUNCH" "$SANDBOX/proj" >/dev/null
  # Ruling 30: die App-Id taucht im geloggten Aufruf zweimal auf -- als
  # argv[1] UND als Teil von "--app-id=..." im Kommandostring (argv[2]).
  # "assert_contains" auf dem gesamten Log bliebe daher gruen, selbst wenn
  # argv[1] geloescht oder vertauscht wuerde: das ist genau der Fehler, der
  # omarchy-launch-or-focus ohne sein Positionsargument dazu bringt, den
  # ganzen Kommandostring als Fenstermuster zu nehmen, nie zu matchen und bei
  # jedem Klick ein neues Fenster zu oeffnen. Deshalb auf die Position
  # pruefen: die App-Id enthaelt keine Leerzeichen, also ist das erste Feld
  # des Logs exakt argv[1].
  log="$(stub_log omarchy-launch-or-focus)"
  assert_eq "${log%% *}" "$(app_id_for "$(cd "$SANDBOX/proj" && pwd -P)")"
}

test_relativer_und_absoluter_pfad_ergeben_dieselbe_app_id() {
  setup_launch
  # Ruling 33: app_id_for haengt am Pfad-Text, nicht an seiner kanonischen
  # Form. Ohne Kanonisierung ergeben "proj" (relativ) und "$SANDBOX/proj"
  # (absolut) verschiedene Hashes und damit verschiedene App-Ids fuer
  # dasselbe Projekt -- Fokussieren wuerde dann still ein zweites Fenster
  # oeffnen, statt das erste zu finden.
  ( cd "$SANDBOX" && "$LAUNCH" "proj" >/dev/null ) || fail "Start (relativ) fehlgeschlagen"
  local log rel_id abs_id
  log="$(stub_log omarchy-launch-or-focus)"
  rel_id="${log%% *}"
  : > "$SANDBOX/log/omarchy-launch-or-focus.log"
  "$LAUNCH" "$SANDBOX/proj" >/dev/null || fail "Start (absolut) fehlgeschlagen"
  log="$(stub_log omarchy-launch-or-focus)"
  abs_id="${log%% *}"
  assert_eq "$rel_id" "$abs_id"
}

test_pfad_mit_leerzeichen_bleibt_ein_argument() {
  setup_launch
  mkdir -p "$SANDBOX/mein projekt"
  "$LAUNCH" "$SANDBOX/mein projekt" || fail "Start fehlgeschlagen"
  assert_contains "$(stub_log omarchy-launch-or-focus)" "mein\\ projekt"
}

test_pfad_mit_anfuehrungszeichen_wird_gequotet() {
  setup_launch
  mkdir -p "$SANDBOX/pro\"jekt"
  "$LAUNCH" "$SANDBOX/pro\"jekt" || fail "Start fehlgeschlagen"
  assert_contains "$(stub_log omarchy-launch-or-focus)" '\"'
}

test_verzeichnisname_mit_dollar_klammern_leerzeichen_und_anfuehrungszeichen() {
  setup_launch
  # Das Verzeichnis ist der einzige interpolierte Wert, der nie durch einen
  # Validator laeuft (anders als Modell-ID und Agentenname) -- er verdient
  # daher einen eigenen Test statt nur den manuellen Replay des Reviewers.
  # Einfach gequotet in der Testdatei, damit die Testshell selbst nichts
  # substituiert; das Verzeichnis heisst dann woertlich pro$(id) mein"jekt.
  local weird_name='pro$(id) mein"jekt'
  local weird="$SANDBOX/$weird_name"
  mkdir -p -- "$weird"
  "$LAUNCH" "$weird" || fail "Start fehlgeschlagen"
  local expected
  expected="$(printf %q "$weird")"
  assert_contains "$(stub_log omarchy-launch-or-focus)" "--dir=$expected"
}

test_kaputte_modell_id_verweigert_den_start() {
  setup_launch
  # Ruling: unter echtem set -e in run_tests wuerde "cmd; rc=$?" den Test
  # sofort abbrechen, bevor assert_status ueberhaupt laeuft, weil der
  # fehlschlagende Aufruf selbst als Fehler der Testfunktion zaehlt.
  # "cmd || rc=$?" haelt errexit davon ab, zuzuschlagen.
  local rc=0
  "$LAUNCH" "$SANDBOX/proj" --model 'boes; id' >/dev/null 2>&1 || rc=$?
  assert_status "$rc" 4
  assert_eq "$(stub_calls omarchy-launch-or-focus)" "0"
}

test_modell_id_mit_klammeraffe_doppelpunkt_tilde_plus_wird_akzeptiert() {
  setup_launch
  # Ruling 7: 367 von 7502 echten models.dev-IDs brauchen @, :, ~ oder + in
  # einem Folgesegment -- diese ID ist so ein Fall und muss durchgehen.
  "$LAUNCH" "$SANDBOX/proj" --model 'cloudflare-workers-ai/@cf/nvidia/nemotron-3-120b-a12b' \
    || fail "Start mit gueltiger, aber ungewoehnlicher Modell-ID fehlgeschlagen"
  assert_contains "$(stub_log omarchy-launch-or-focus)" \
    '-m cloudflare-workers-ai/@cf/nvidia/nemotron-3-120b-a12b'
}

test_modell_id_mit_kommandosubstitution_wird_vor_dem_bauen_abgelehnt() {
  setup_launch
  local rc=0
  "$LAUNCH" "$SANDBOX/proj" --model 'openai/$(id)' >/dev/null 2>&1 || rc=$?
  assert_status "$rc" 4
  assert_eq "$(stub_calls omarchy-launch-or-focus)" "0"
}

test_kaputter_agentenname_verweigert_den_start() {
  setup_launch
  local rc=0
  "$LAUNCH" "$SANDBOX/proj" --agent 'a b' >/dev/null 2>&1 || rc=$?
  assert_status "$rc" 5
  assert_eq "$(stub_calls omarchy-launch-or-focus)" "0"
}

test_fehlendes_verzeichnis_gibt_zwei() {
  setup_launch
  local rc=0
  "$LAUNCH" "$SANDBOX/gibtsnicht" >/dev/null 2>&1 || rc=$?
  assert_status "$rc" 2
}

test_fehlendes_opencode_gibt_drei() {
  setup_launch
  export OPENCODE_BIN="$SANDBOX/gibtsnicht"
  local rc=0
  "$LAUNCH" "$SANDBOX/proj" >/dev/null 2>&1 || rc=$?
  assert_status "$rc" 3
}

test_ohne_argument_gibt_eins() {
  setup_launch
  local rc=0
  "$LAUNCH" >/dev/null 2>&1 || rc=$?
  assert_status "$rc" 1
}

test_continue_und_agent_erscheinen_als_flags() {
  setup_launch
  "$LAUNCH" "$SANDBOX/proj" --agent Allgemein --continue || fail "Start fehlgeschlagen"
  log="$(stub_log omarchy-launch-or-focus)"
  assert_contains "$log" "--agent Allgemein"
  # Minor aus der Review: "-c" allein ist auch Teilkette von "--continue"
  # selbst ("--continue"[1:3] == "-c") -- ein Test, der "--continue" statt
  # des kurzen "-c"-Flags loggen wuerde, bestuende trotzdem. Das Skript haengt
  # "-c" aber immer als letztes Token an, deshalb hier auf den exakten
  # Schwanz der Zeile pruefen.
  assert_eq "${log##* }" "-c"
}

test_new_window_umgeht_launch_or_focus() {
  setup_launch
  "$LAUNCH" "$SANDBOX/proj" --new-window || fail "Start fehlgeschlagen"
  assert_eq "$(stub_calls omarchy-launch-or-focus)" "0"
  assert_eq "$(stub_calls setsid)" "1"
}

test_start_koppelt_die_pipes_ab() {
  # Strukturtest statt Verhaltenstest: das Symptom laesst sich in einer
  # Bash-Suite nicht nachstellen -- es gibt hier keinen Quickshell-Prozess,
  # der beim Beenden der Process-Kette die Pipes abraeumt und damit das
  # Terminal mitreisst, waehrend systemd trotzdem "gestartet" meldet und das
  # Skript mit 0 endet. Stattdessen wird erzwungen, dass jede exec-Zeile die
  # Abkopplung traegt: wer sie entfernt, bekommt sofort einen roten Test.
  local script="$DIR/../bin/omarchy-opencode-launch"
  local exec_lines n
  exec_lines="$(grep -E '^[[:space:]]*exec ' "$script")"
  [ -n "$exec_lines" ] || fail "keine exec-Zeile in $script gefunden"
  # Ruling 34: die reine Existenzpruefung war blind fuer ein verschobenes
  # exec (z.B. auf eine "then"-Zeile) -- die Liste bliebe nicht-leer, auch
  # wenn die verschobene Zeile selbst nicht mehr matcht. Die Anzahl ist die
  # schaerfere Zusicherung: genau zwei exec-Aufrufe (--new-window-Pfad und
  # Standardpfad), beide am Zeilenanfang.
  n="$(printf '%s\n' "$exec_lines" | grep -c '.')"
  assert_eq "$n" "2"
  while IFS= read -r line; do
    assert_contains "$line" '</dev/null >/dev/null 2>&1'
  done <<< "$exec_lines"
  # Ruling 34, zweiter Teil: Ruling 2 (kein PATH-aufgeloester Interpreter)
  # war bislang durch nichts als die Review erzwungen -- ein Zurueckdrehen
  # auf "/usr/bin/env bash -c" liesse alle Tests weiterhin gruen, weil die
  # Sandbox selbst einen bash-Symlink im PATH bereitstellt.
  assert_contains "$exec_lines" '/usr/bin/bash -c'
}

run_tests
