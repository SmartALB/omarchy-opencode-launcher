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

test_fehlendes_sqlite3_laesst_gepinnte_projekte_funktionieren() {
  setup_common
  mkdir -p "$SANDBOX/a"
  write_config "{\"projects\":[{\"name\":\"A\",\"path\":\"$SANDBOX/a\"}]}"
  # Ueber SQLITE_BIN auf ein nicht vorhandenes Programm zeigen. Ein
  # Entfernen aus dem PATH waere wirkungslos, weil absolut aufgerufen wird.
  export SQLITE_BIN="$SANDBOX/gibtsnicht"
  export OPENCODE_DB="$SANDBOX/oc.db"; : > "$OPENCODE_DB"
  out="$("$PROJ" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r 'length')" "1"
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

run_tests
