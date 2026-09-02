#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
STORE="$DIR/../bin/omarchy-opencode-store"
statefile() { printf '%s/omarchy/smartalb-opencode/projects.json' "$XDG_STATE_HOME"; }

test_set_dann_get_gibt_das_modell_zurueck() {
  "$STORE" set /p/eins openai/gpt-5-codex || fail "set fehlgeschlagen"
  assert_eq "$("$STORE" get /p/eins)" "openai/gpt-5-codex"
}

test_get_ohne_eintrag_ist_leer_und_erfolgreich() {
  # Vorsicht: "assert_eq \"\$(...)\" \"\"" gefolgt von "assert_status \"\$?\" 0"
  # pruefte in Wahrheit den Exit-Code von assert_eq, nicht den von "store
  # get" -- assert_eq laeuft dazwischen und ueberschreibt $?. Der Aufruf und
  # die Erfassung von $? muessen in derselben Anweisung stehen.
  out="$("$STORE" get /p/nichts)"; rc=$?
  assert_eq "$out" ""
  assert_status "$rc" 0
}

test_set_lehnt_kaputte_modell_id_ab_ohne_zu_schreiben() {
  "$STORE" set /p/eins 'kaputt' >/dev/null 2>&1; assert_status "$?" 4
  [ ! -f "$(statefile)" ] || fail "Zustandsdatei wurde trotz Ablehnung angelegt"
}

test_unset_entfernt_nur_den_einen_eintrag() {
  "$STORE" set /p/eins openai/a >/dev/null
  "$STORE" set /p/zwei openai/b >/dev/null
  "$STORE" unset /p/eins >/dev/null
  assert_eq "$("$STORE" get /p/eins)" ""
  assert_eq "$("$STORE" get /p/zwei)" "openai/b"
}

test_sterne_werden_gehalten_und_entfernt() {
  "$STORE" star openai/a >/dev/null
  "$STORE" star lmstudio/openai/b >/dev/null
  assert_contains "$("$STORE" stars)" "lmstudio/openai/b"
  "$STORE" unstar openai/a >/dev/null
  assert_not_contains "$("$STORE" stars)" "openai/a"
}

test_schreiben_ist_atomar_die_alte_datei_bleibt_bei_abbruch() {
  "$STORE" set /p/eins openai/a >/dev/null
  before="$(cat "$(statefile)")"
  # jq-Doppelgaenger, der scheitert: der Ersatzinhalt darf nie entstehen.
  # Ueber JQ_BIN, nicht ueber den PATH -- das Skript ruft jq absolut auf.
  make_stub jq 'exit 3'
  JQ_BIN="$SANDBOX/stub/jq" "$STORE" set /p/eins openai/b >/dev/null 2>&1 || true
  assert_eq "$(cat "$(statefile)")" "$before"
}

test_temporaerdatei_liegt_im_zielverzeichnis_und_bleibt_nicht_liegen() {
  "$STORE" set /p/eins openai/a >/dev/null
  d="$(dirname "$(statefile)")"
  assert_eq "$(find "$d" -name '*.tmp*' | wc -l | tr -d ' ')" "0"
}

test_symlink_als_zustandsdatei_wird_abgelehnt() {
  d="$(dirname "$(statefile)")"; mkdir -p "$d"
  ln -s /dev/null "$(statefile)"
  "$STORE" set /p/eins openai/a >/dev/null 2>&1; assert_status "$?" 6
  [ -L "$(statefile)" ] || fail "der Symlink wurde ersetzt statt abgelehnt"
}

test_zustandsdatei_ueber_der_grenze_wird_abgelehnt() {
  d="$(dirname "$(statefile)")"; mkdir -p "$d"
  head -c 1048577 /dev/zero | tr '\0' 'a' > "$(statefile)"
  "$STORE" get /p/eins >/dev/null 2>&1; assert_status "$?" 8
}

test_unbekannte_schemaversion_wird_nicht_geraten() {
  d="$(dirname "$(statefile)")"; mkdir -p "$d"
  printf '{"schemaVersion":99,"projects":{}}' > "$(statefile)"
  "$STORE" set /p/eins openai/a >/dev/null 2>&1; assert_status "$?" 7
  assert_contains "$(cat "$(statefile)")" '"schemaVersion":99'
}

test_kaputtes_json_wird_nicht_stillschweigend_ersetzt() {
  d="$(dirname "$(statefile)")"; mkdir -p "$d"
  printf '{ das ist kein json' > "$(statefile)"
  before="$(cat "$(statefile)")"
  # Ruling 10: 9 = "Datei ist kein gueltiges JSON", eigenstaendig neben 7
  # ("unbekannte schemaVersion") dokumentiert -- verschiedene Ursachen,
  # verschiedene Meldungen. Nur "$?" != 0 zu pruefen haette auch bei Exit
  # 127 (Skript fehlt) oder einem Usage-Fehler bestanden und nie belegt,
  # dass die Datei tatsaechlich unangetastet blieb.
  "$STORE" set /p/eins openai/a >/dev/null 2>&1
  assert_status "$?" 9
  assert_eq "$(cat "$(statefile)")" "$before"
}

run_tests
