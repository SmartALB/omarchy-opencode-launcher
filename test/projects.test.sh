#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
PROJ="$DIR/../bin/omarchy-opencode-projects"
STORE="$DIR/../bin/omarchy-opencode-store"

setup_common() {
  make_stub opencode 'exit 0'
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
  # HYPRCTL_BIN, nicht der PATH: das Skript ruft hyprctl absolut auf, ein
  # PATH-Doppelgaenger wuerde nie benutzt und der Test pruefte nichts.
  make_stub hyprctl 'printf "%s" "[]"'
  export HYPRCTL_BIN="$SANDBOX/stub/hyprctl"
  export OPENCODE_DB="$SANDBOX/none.db"
}

write_config() {  # write_config <json>
  mkdir -p "$HOME/.config/omarchy"
  printf '%s' "$1" > "$HOME/.config/omarchy/opencode-launcher.json"
}

test_gepinnte_projekte_erscheinen_in_config_reihenfolge() {
  setup_common
  mkdir -p "$SANDBOX/a" "$SANDBOX/b"
  write_config "{\"projects\":[{\"name\":\"B\",\"path\":\"$SANDBOX/b\"},{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].name')" "B"
  assert_eq "$(printf '%s' "$out" | jq -r '.[1].name')" "A"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].pinned')" "true"
}

test_alte_config_datei_wird_als_rueckfall_gelesen() {
  setup_common
  mkdir -p "$SANDBOX/a" "$HOME/.config/omarchy"
  printf '{"projects":[{"name":"Alt","path":"%s"}]}' "$SANDBOX/a" \
    > "$HOME/.config/omarchy/opencode-projects.json"
  assert_eq "$("$PROJ" list --json | jq -r '.[0].name')" "Alt"
}

test_neue_config_gewinnt_gegen_alte() {
  setup_common
  mkdir -p "$SANDBOX/a" "$HOME/.config/omarchy"
  printf '{"projects":[{"name":"Alt","path":"%s"}]}' "$SANDBOX/a" \
    > "$HOME/.config/omarchy/opencode-projects.json"
  write_config "{\"projects\":[{\"name\":\"Neu\",\"path\":\"$SANDBOX/a\"}]}"
  assert_eq "$("$PROJ" list --json | jq -r '.[0].name')" "Neu"
}

test_modell_aus_dem_zustand_wird_angehaengt() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  "$STORE" set "$SANDBOX/a" lmstudio/openai/gpt-oss-20b >/dev/null
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].model')" "lmstudio/openai/gpt-oss-20b"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].modelLabel')" "gpt-oss-20b"
}

test_ohne_modell_ist_das_feld_null_nicht_leer() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  assert_eq "$("$PROJ" list --json | jq -r '.[0].model')" "null"
}

test_unbekanntes_modell_wird_markiert_aber_behalten() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  "$STORE" set "$SANDBOX/a" lmstudio/entladen/x >/dev/null
  # Modell-Cache enthaelt nur ein anderes Modell
  mkdir -p "$XDG_CACHE_HOME/omarchy/smartalb.opencode"
  printf '{"models":[{"id":"openai/gpt-5-codex"}]}' \
    > "$XDG_CACHE_HOME/omarchy/smartalb.opencode/models.json"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].modelKnown')" "false"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].model')" "lmstudio/entladen/x"
}

test_geloeschtes_verzeichnis_wird_als_nicht_vorhanden_gemeldet() {
  setup_common
  write_config "{\"projects\":[{\"name\":\"Weg\",\"path\":\"$SANDBOX/gibtsnicht\"}]}"
  assert_eq "$("$PROJ" list --json | jq -r '.[0].exists')" "false"
}

test_laufendes_fenster_wird_erkannt() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  . "$DIR/../bin/_common.sh"
  id="$(app_id_for "$SANDBOX/a")"
  make_stub hyprctl "printf '%s' '[{\"class\":\"$id\"}]'"
  export HYPRCTL_BIN="$SANDBOX/stub/hyprctl"
  assert_eq "$("$PROJ" list --json | jq -r '.[0].running')" "true"
}

test_kappung_wird_gemeldet_nicht_stillschweigend_vorgenommen() {
  setup_common
  {
    printf '{"projects":['
    for i in $(seq 1 205); do
      [ "$i" -gt 1 ] && printf ','
      printf '{"name":"P%s","path":"%s/p%s"}' "$i" "$SANDBOX" "$i"
    done
    printf ']}'
  } > "$HOME/.config/omarchy/opencode-launcher.json"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].capped')" "true"
}

test_ohne_kappung_ist_capped_falsch() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  assert_eq "$("$PROJ" list --json | jq -r '.[0].capped')" "false"
}

test_kappung_liegt_vor_dem_ersten_hyprctl_aufruf() {
  setup_common
  {
    printf '{"projects":['
    for i in $(seq 1 250); do
      [ "$i" -gt 1 ] && printf ','
      printf '{"name":"P%s","path":"%s/p%s"}' "$i" "$SANDBOX" "$i"
    done
    printf ']}'
  } > "$HOME/.config/omarchy/opencode-launcher.json"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "200"
  assert_eq "$(stub_calls hyprctl)" "1"
}

test_recents_kommen_aus_der_datenbank_und_folgen_den_gepinnten() {
  setup_common
  mkdir -p "$SANDBOX/a" "$SANDBOX/r1"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  export OPENCODE_DB="$SANDBOX/oc.db"
  sqlite3 "$OPENCODE_DB" \
    "CREATE TABLE session(directory TEXT, time_updated INTEGER);
     INSERT INTO session VALUES('$SANDBOX/r1', 200), ('$SANDBOX/a', 100);"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "2"
  assert_eq "$(printf '%s' "$out" | jq -r '.[1].path')" "$SANDBOX/r1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[1].pinned')" "false"
}

test_fehlendes_opencode_meldet_sich_im_json_und_im_exit() {
  make_stub hyprctl 'printf "%s" "[]"'
  export OPENCODE_BIN="$SANDBOX/gibtsnicht"
  # "out=$(...); rc=$?" wuerde unter dem echten set -e dieser Harness
  # (run_tests fuehrt jeden Test in "(set -e; ...)" aus) die Funktion schon
  # bei der Zuweisung beenden, sobald PROJ ungleich 0 liefert -- "rc=$?"
  # wuerde nie erreicht. rc=0 vorbelegen und ueber "||" abfangen haelt den
  # Test am Leben und faengt trotzdem den echten Exit-Code.
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "opencode-missing"
  assert_status "$rc" 3
}

test_kaputte_config_liefert_gueltiges_json_und_meldet_es() {
  setup_common
  write_config '{ kein json'
  # Aus demselben Grund wie oben: PROJ verlaesst sich hier auf Exit 9
  # (Ruling 10), eine blosse Zuweisung wuerde die Funktion unter set -e
  # vorzeitig beenden, bevor assert_eq ueberhaupt laeuft.
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "config-unreadable"
  assert_status "$rc" 9
}

test_fehlendes_sqlite3_ueberspringt_den_unterprozess_ganz() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  # Ueber SQLITE_BIN auf ein nicht vorhandenes Programm zeigen. Ein
  # Entfernen aus dem PATH waere wirkungslos, weil absolut aufgerufen wird.
  export SQLITE_BIN="$SANDBOX/gibtsnicht"
  export OPENCODE_DB="$SANDBOX/oc.db"; : > "$OPENCODE_DB"
  # Ruling 24: "die Zeile bleibt sichtbar, weil der Prozess fehlschlaegt"
  # beweist nicht, dass der command-v-Wachposten je gegriffen hat -- ein
  # fehlgeschlagener Unterprozess UND ein uebersprungener Unterprozess sehen
  # im Ergebnis gleich aus. timeout wird als protokollierender Doppelgaenger
  # eingesetzt (auch der hyprctl-Aufruf laeuft ueber ihn), damit sich
  # zaehlen laesst, ob der sqlite3-Pfad ueberhaupt je bei ihm ankam.
  make_stub timeout 'exit 0'
  export TIMEOUT_BIN="$SANDBOX/stub/timeout"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].name')" "A"
  # Nicht stub_calls (zaehlt JEDEN timeout-Aufruf, auch den fuer hyprctl) --
  # nur die Zeilen zaehlen, die den sqlite3-Pfad nennen. Das ist genau die
  # Bedingung, die der command-v-Wachposten verhindern soll.
  sqlite_calls="$(stub_log timeout | grep -c -- "$SQLITE_BIN" || true)"
  assert_eq "$sqlite_calls" "0"
}

test_config_ueber_der_grenze_wird_abgelehnt() {
  setup_common
  mkdir -p "$HOME/.config/omarchy"
  head -c 1048577 /dev/zero | tr '\0' 'a' > "$HOME/.config/omarchy/opencode-launcher.json"
  assert_eq "$("$PROJ" list --json | jq -r '.error')" "config-too-large"
}

# Ruling 19 (im Brief noch nicht als Test vorhanden): ein Symlink am
# Zustands- oder Cache-Pfad darf nicht stillschweigend verfolgt werden --
# "nicht vorhanden" und "hier liegt ein Symlink" sind verschiedene
# Tatsachen, siehe Kommentar in bin/omarchy-opencode-projects.
test_symlink_am_zustandspfad_wird_abgelehnt() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  mkdir -p "$XDG_STATE_HOME/omarchy/smartalb-opencode"
  ln -s /etc/passwd "$XDG_STATE_HOME/omarchy/smartalb-opencode/projects.json"
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "state-not-a-file"
  assert_status "$rc" 6
}

test_symlink_am_cache_pfad_wird_abgelehnt() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  mkdir -p "$XDG_CACHE_HOME/omarchy/smartalb.opencode"
  ln -s /etc/passwd "$XDG_CACHE_HOME/omarchy/smartalb.opencode/models.json"
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "cache-not-a-file"
  assert_status "$rc" 6
}

# Beim Schreiben des sqlite3-Tests fuer Ruling 24 fiel auf: ein Doppelgaenger
# fuer hyprctl/timeout, der gar nichts ausgibt, liess "classes" als leeren
# String statt "[]" stehen und riss den letzten jq-Aufruf mit "invalid JSON
# text passed to --argjson" mit runter -- keine Fehlermeldung im JSON, nur
# ein Absturz. Zwei Regressionstests dagegen: eine leere hyprctl-Antwort und
# eine 0-Byte-Cache-Datei duerfen das Ergebnis nicht sprengen.
test_leere_hyprctl_antwort_stuerzt_das_jq_nicht_ab() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  make_stub hyprctl 'exit 0'
  export HYPRCTL_BIN="$SANDBOX/stub/hyprctl"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].running')" "false"
}

test_leere_cache_datei_stuerzt_das_jq_nicht_ab() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  "$STORE" set "$SANDBOX/a" lmstudio/openai/gpt-oss-20b >/dev/null
  mkdir -p "$XDG_CACHE_HOME/omarchy/smartalb.opencode"
  : > "$XDG_CACHE_HOME/omarchy/smartalb.opencode/models.json"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "1"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].modelKnown')" "true"
}

# Ruling 25 (Review Runde 2): gueltiges JSON reicht am Zustandspfad nicht --
# "{"projects":[]}" oder eine fremde schemaVersion bestehen die reine
# "-e ."-Pruefung, stuerzen aber im abschliessenden jq ab ("Cannot index
# array with string"), mit leerem stdout. Form und Version muessen vorher
# geprueft werden, mit eigenen Fehlercodes wie beim Schreiber selbst.
test_zustand_mit_projects_als_array_meldet_state_invalid() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  mkdir -p "$XDG_STATE_HOME/omarchy/smartalb-opencode"
  printf '{"schemaVersion":1,"projects":[]}' > "$XDG_STATE_HOME/omarchy/smartalb-opencode/projects.json"
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "state-invalid"
  assert_status "$rc" 9
}

test_zustand_mit_unbekannter_schemaversion_meldet_sich() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  mkdir -p "$XDG_STATE_HOME/omarchy/smartalb-opencode"
  printf '{"schemaVersion":2,"projects":{}}' > "$XDG_STATE_HOME/omarchy/smartalb-opencode/projects.json"
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "state-schema-unknown"
  assert_status "$rc" 7
}

# Ruling 26: "zu gross" darf nicht wie "nichts gemerkt" aussehen -- weder
# fuer die Zustandsdatei noch fuer den Modell-Cache.
test_zu_grosse_zustandsdatei_wird_gemeldet() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  mkdir -p "$XDG_STATE_HOME/omarchy/smartalb-opencode"
  head -c 1048577 /dev/zero | tr '\0' 'a' > "$XDG_STATE_HOME/omarchy/smartalb-opencode/projects.json"
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "state-too-large"
  assert_status "$rc" 8
}

test_zu_grosse_cache_datei_wird_gemeldet() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  mkdir -p "$XDG_CACHE_HOME/omarchy/smartalb.opencode"
  head -c 1048577 /dev/zero | tr '\0' 'a' > "$XDG_CACHE_HOME/omarchy/smartalb.opencode/models.json"
  rc=0
  out="$("$PROJ" list --json)" || rc=$?
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "cache-too-large"
  assert_status "$rc" 8
}

# Ruling 27: der Reviewer zeigte, dass "running: ($classes | length) > 0"
# (irgendein Fenster offen => JEDE Zeile "laeuft") jeden bisherigen Test
# bestehen wuerde. Zwei Tests, die genau das ausschliessen.
test_running_bleibt_false_bei_fremder_app_id() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  make_stub hyprctl 'printf "%s" "[{\"class\":\"org.omarchy.opencode.fremd-0000\"}]"'
  export HYPRCTL_BIN="$SANDBOX/stub/hyprctl"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].running')" "false"
}

test_running_trifft_nur_die_passende_zeile_unter_mehreren() {
  setup_common
  mkdir -p "$SANDBOX/a" "$SANDBOX/b" "$SANDBOX/c"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"},{\"name\":\"B\",\"path\":\"$SANDBOX/b\"},{\"name\":\"C\",\"path\":\"$SANDBOX/c\"}]}"
  . "$DIR/../bin/_common.sh"
  idB="$(app_id_for "$SANDBOX/b")"
  make_stub hyprctl "printf '%s' '[{\"class\":\"$idB\"}]'"
  export HYPRCTL_BIN="$SANDBOX/stub/hyprctl"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.[0].running')" "false"
  assert_eq "$(printf '%s' "$out" | jq -r '.[1].running')" "true"
  assert_eq "$(printf '%s' "$out" | jq -r '.[2].running')" "false"
}

# Minor: bei bereits erreichter Kappung durch gepinnte Projekte allein darf
# der sqlite3-Unterprozess gar nicht erst gestartet werden -- eine 200-fach
# gepinnte Liste braucht keine Recents mehr, und "keiner angefordert" heisst
# hier "keiner gestartet", nicht nur "keiner uebernommen".
test_sqlite_wird_uebersprungen_wenn_bereits_gekappt() {
  setup_common
  {
    printf '{"projects":['
    for i in $(seq 1 200); do
      [ "$i" -gt 1 ] && printf ','
      printf '{"name":"P%s","path":"%s/p%s"}' "$i" "$SANDBOX" "$i"
    done
    printf ']}'
  } > "$HOME/.config/omarchy/opencode-launcher.json"
  export OPENCODE_DB="$SANDBOX/oc.db"
  sqlite3 "$OPENCODE_DB" \
    "CREATE TABLE session(directory TEXT, time_updated INTEGER);
     INSERT INTO session VALUES('$SANDBOX/extra', 999);"
  make_stub timeout 'exit 0'
  export TIMEOUT_BIN="$SANDBOX/stub/timeout"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "200"
  # Nur die hyprctl-Zeile darf im Log stehen -- keine, die den DB-Pfad nennt.
  db_calls="$(stub_log timeout | grep -c -- "$OPENCODE_DB" || true)"
  assert_eq "$db_calls" "0"
}

# Ruling 28 (c): die Invariante, auf die sich das Panel verlaesst, einmal
# ausgesprochen -- stdout ist IMMER gueltiges JSON -- und tabellengetrieben
# geprueft, statt fuer jede neu gefundene kaputte Form eine weitere
# Review-Runde zu brauchen. Eine neue kaputte Form ist ab jetzt eine neue
# Zeile in "cases", kein neuer Testname. Je Zeile (durch Tabs getrennt):
# Ziel(state|config), Inhalt, erwarteter .error-Wert, erwarteter Exit-Code.
test_kaputte_formen_liefern_immer_gueltiges_json_mit_fehler() {
  setup_common
  mkdir -p "$SANDBOX/a"
  state_dir="$XDG_STATE_HOME/omarchy/smartalb-opencode"
  state_file="$state_dir/projects.json"
  mkdir -p "$state_dir"
  local cases=(
    $'state\t{"schemaVersion":1,"projects":{"/p":"openai/x"}}\tstate-invalid\t9'
    $'state\t{"schemaVersion":1,"projects":{"/p":[]}}\tstate-invalid\t9'
    $'state\t{"schemaVersion":1,"projects":{"/p":42}}\tstate-invalid\t9'
    $'state\t{"schemaVersion":1,"projects":{"/p":null}}\tstate-invalid\t9'
    $'state\t[]\tstate-schema-unknown\t7'
    $'state\t{"projects":{}}\tstate-schema-unknown\t7'
    $'state\t{ kein json\tstate-invalid\t9'
    $'config\t{ kein json\tconfig-unreadable\t9'
  )
  local case_line target content expected_error expected_exit out rc
  for case_line in "${cases[@]}"; do
    IFS=$'\t' read -r target content expected_error expected_exit <<< "$case_line"
    # Jeden Fall aus einer sauberen Grundlage heraus starten, statt
    # setup_sandbox je Iteration neu aufzurufen: das wuerde SANDBOX und die
    # EXIT-Falle mehrfach ueberschreiben und fruehere Sandbox-Verzeichnisse
    # als Leichen zuruecklassen.
    rm -f "$state_file"
    write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
    case "$target" in
      state) printf '%s' "$content" > "$state_file" ;;
      config) write_config "$content" ;;
    esac
    rc=0
    out="$("$PROJ" list --json)" || rc=$?
    printf '%s' "$out" | jq -e . >/dev/null 2>&1 \
      || fail "Zeile [$target -> $expected_error]: stdout ist kein gueltiges JSON: $out"
    assert_eq "$(printf '%s' "$out" | jq -r '.error // "FEHLT"')" "$expected_error"
    assert_status "$rc" "$expected_exit"
  done
}

run_tests
