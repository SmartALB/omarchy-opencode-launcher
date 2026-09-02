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
  assert_not_contains "$(stub_log omarchy-launch-or-focus)" " -m "
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
  assert_contains "$(stub_log omarchy-launch-or-focus)" "$(app_id_for "$SANDBOX/proj")"
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
  assert_contains "$log" "-c"
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
  local exec_lines
  exec_lines="$(grep -E '^[[:space:]]*exec ' "$script")"
  [ -n "$exec_lines" ] || fail "keine exec-Zeile in $script gefunden"
  while IFS= read -r line; do
    assert_contains "$line" '</dev/null >/dev/null 2>&1'
  done <<< "$exec_lines"
}

run_tests
