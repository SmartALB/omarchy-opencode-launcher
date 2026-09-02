#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
MODELS="$DIR/../bin/omarchy-opencode-models"
cachefile() { printf '%s/omarchy/smartalb.opencode/models.json' "$XDG_CACHE_HOME"; }

# Ein opencode-Doppelgaenger, der eine feste Liste ausgibt.
stub_opencode() {
  make_stub opencode "printf '%s\n' openai/gpt-5-codex lmstudio/openai/gpt-oss-20b"
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
}

test_liste_kommt_von_opencode_und_ist_gueltiges_json() {
  stub_opencode
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.source')" "opencode"
  assert_eq "$(printf '%s' "$out" | jq -r '.stale')" "false"
  assert_eq "$(printf '%s' "$out" | jq -r '.models | length')" "2"
  assert_eq "$(printf '%s' "$out" | jq -r '.models[1].provider')" "lmstudio"
  assert_eq "$(printf '%s' "$out" | jq -r '.models[1].label')" "gpt-oss-20b"
}

test_frischer_cache_ruft_opencode_nicht_erneut() {
  stub_opencode
  "$MODELS" list --json >/dev/null
  assert_eq "$(stub_calls opencode)" "1"
  "$MODELS" list --json >/dev/null
  assert_eq "$(stub_calls opencode)" "1"
}

test_refresh_erzwingt_den_aufruf() {
  stub_opencode
  "$MODELS" list --json >/dev/null
  "$MODELS" list --json --refresh >/dev/null
  assert_eq "$(stub_calls opencode)" "2"
}

test_abgelaufener_cache_wird_neu_geholt() {
  stub_opencode
  "$MODELS" list --json >/dev/null
  touch -d '48 hours ago' "$(cachefile)"
  "$MODELS" list --json >/dev/null
  assert_eq "$(stub_calls opencode)" "2"
}

test_timeout_liefert_den_cache_mit_stale_markierung() {
  stub_opencode
  "$MODELS" list --json >/dev/null
  make_stub opencode 'sleep 30'
  # "OC_MODELS_TIMEOUT=1 out=$(...)" (wie im Brief woertlich notiert) sind
  # zwei blosse Zuweisungswoerter ohne Kommandowort in derselben simple
  # command -- bash exportiert die erste Zuweisung dann NICHT in die
  # Umgebung des in der Kommandosubstitution aufgerufenen externen
  # Programms. Belegt mit /tmp/showenv.sh: seen=[UNSET] bei "VAR=1
  # out=$(prog)", seen=[1] erst bei "out=$(VAR=1 prog)". Der Test waere mit
  # der Brief-Schreibweise trotzdem gruen -- er haette nur zufaellig den
  # eingebauten Standard von 5s statt der beabsichtigten 1s getroffen.
  # Daher die Praefix-Zuweisung direkt vor das Kommandowort gesetzt.
  out="$(OC_MODELS_TIMEOUT=1 "$MODELS" list --json --refresh)"
  assert_eq "$(printf '%s' "$out" | jq -r '.source')" "cache"
  assert_eq "$(printf '%s' "$out" | jq -r '.stale')" "true"
  assert_eq "$(printf '%s' "$out" | jq -r '.models | length')" "2"
}

# Controller Ruling 4: der Test oben wird auch dann gruen, wenn "timeout"
# aus dem Skript entfernt wird -- der Doppelgaenger schlaeft 30s, das
# Skript wartet die vollen 30s ab, exit 0 mit leerer Ausgabe, und der
# leere-Ausgabe-Pfad liefert ebenfalls den Cache mit stale=true. Der Test
# beweist also nichts ueber die Frist. Diese Messung hier prueft die
# Wanduhrzeit: bei OC_MODELS_TIMEOUT=1 muss der Aufruf weit unter 5s
# zurueckkommen, nicht erst nach 30s.
#
# Status und Ausgabe werden in derselben Anweisung wie der Aufruf
# eingefangen (rc=$? direkt nach der Zuweisung), nicht ueber ein
# ungeprueftes "set -e" in der umgebenden Subshell: run_tests fuehrt jeden
# Test als "( set -e; ...; "$fn" )" innerhalb eines "if"-Bedingungstests
# aus, und Bash setzt die errexit-Wirkung fuer alles, was Teil einer
# if/while/until-Bedingung ist, ausser Kraft -- auch innerhalb einer
# Subshell, die selbst "set -e" setzt. Ein bloss dastehender fehlschlagender
# Befehl (ohne anschliessende Pruefung) wuerde den Test deshalb NICHT rot
# machen, selbst wenn "$MODELS" gar nicht existiert. Beleg:
# "if ( set -e; false; echo NACH ); then echo OK; else echo FAIL; fi"
# gibt "NACH" und "OK" aus, nicht "FAIL". Daher hier explizit rc und Inhalt
# pruefen statt sich auf implizites set -e zu verlassen.
test_haengendes_opencode_wird_nach_der_frist_abgebrochen() {
  stub_opencode
  "$MODELS" list --json >/dev/null
  make_stub opencode 'sleep 30'
  local start end elapsed rc out
  start="$(date +%s)"
  out="$(OC_MODELS_TIMEOUT=1 "$MODELS" list --json --refresh)"; rc=$?
  end="$(date +%s)"
  elapsed="$((end - start))"
  assert_status "$rc" "0"
  assert_eq "$(printf '%s' "$out" | jq -r '.source')" "cache"
  assert_eq "$(printf '%s' "$out" | jq -r '.stale')" "true"
  [ "$elapsed" -lt 5 ] || fail "erwartet: unter 5s" "erhalten: ${elapsed}s"
}

test_ohne_cache_und_ohne_opencode_ist_die_quelle_none() {
  make_stub opencode 'exit 1'
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.source')" "none"
  assert_eq "$(printf '%s' "$out" | jq -r '.models | length')" "0"
}

test_fehlendes_opencode_meldet_sich_im_json() {
  export OPENCODE_BIN="$SANDBOX/gibtsnicht"
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "opencode-missing"
}

test_ausgabe_ueber_der_bytegrenze_wird_abgelehnt() {
  make_stub opencode 'head -c 1048577 /dev/zero | tr "\0" "a"'
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "models-too-large"
}

test_mehr_als_2000_ids_werden_gekappt() {
  make_stub opencode 'for i in $(seq 1 2500); do printf "p/m%s\n" "$i"; done'
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.models | length')" "2000"
  assert_eq "$(printf '%s' "$out" | jq -r '.capped')" "true"
}

test_kaputte_zeilen_werden_verworfen_nicht_uebernommen() {
  make_stub opencode 'printf "%s\n" "openai/gut" "keinschraegstrich" "" "p/$(id)"'
  export OPENCODE_BIN="$SANDBOX/stub/opencode"
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.models | length')" "1"
  assert_eq "$(printf '%s' "$out" | jq -r '.models[0].id')" "openai/gut"
}

test_sterne_stehen_oben_und_sind_markiert() {
  stub_opencode
  "$DIR/../bin/omarchy-opencode-store" star lmstudio/openai/gpt-oss-20b >/dev/null
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.models[0].id')" "lmstudio/openai/gpt-oss-20b"
  assert_eq "$(printf '%s' "$out" | jq -r '.models[0].starred')" "true"
}

# Ruling 19: dieselbe Datei-Art-Pruefung wie bei omarchy-opencode-store fuer
# seine Zustandsdatei -- ein Symlink am Cache-Pfad wuerde "[ -f "$CACHE" ]"
# (das Symlinks folgt) und damit cache_fresh() bestehen, und read_capped
# wuerde lesen, wohin er auch zeigt. Das Ziel enthaelt hier absichtlich ein
# ECHTES, gueltiges Modell ("real/model") -- ein Lesefehler waere sonst
# nicht von einer erfolgreich verweigerten Pruefung zu unterscheiden. Nur
# wenn die Pruefung wirklich vor dem Lesen greift, bleibt "real/model"
# unsichtbar; ein bloss fehlschlagender Lesezugriff haette stattdessen zu
# "models-unavailable" oder aehnlichem gefuehrt, nicht zu "cache-not-a-file".
test_symlink_als_cache_wird_nicht_gefolgt() {
  mkdir -p "$(dirname "$(cachefile)")"
  target="$SANDBOX/echtes_ziel.json"
  printf '%s' '{"generatedAt":"2020-01-01T00:00:00Z","stale":false,"source":"cache","capped":false,"models":[{"id":"real/model","provider":"real","label":"model","starred":false}]}' > "$target"
  ln -s "$target" "$(cachefile)"
  out="$("$MODELS" list --json)"
  assert_eq "$(printf '%s' "$out" | jq -r '.source')" "none"
  assert_eq "$(printf '%s' "$out" | jq -r '.error')" "cache-not-a-file"
  assert_not_contains "$out" "real/model"
}

# Ruling 19, Schreibseite: derselbe Symlink darf auch beim Schreiben nicht
# ersetzt werden -- "mv -f tmp $CACHE" wuerde ihn sonst stillschweigend
# durch eine neue Datei ersetzen. "--refresh" umgeht den Lesepfad oben
# vollstaendig (refresh=true ueberspringt den ersten "if"-Zweig) und ruft
# echt ab, damit dieser Test wirklich den Schreibpfad trifft, nicht den
# Lesepfad von eben.
test_symlink_als_cache_wird_bei_refresh_nicht_ueberschrieben() {
  stub_opencode
  mkdir -p "$(dirname "$(cachefile)")"
  target="$SANDBOX/irgendein_ziel.json"
  printf '%s' 'kein gueltiges json, aber das ist hier egal' > "$target"
  ln -s "$target" "$(cachefile)"
  out="$("$MODELS" list --json --refresh)"
  assert_eq "$(printf '%s' "$out" | jq -r '.source')" "opencode"
  [ -L "$(cachefile)" ] || fail "der Symlink wurde ersetzt statt erhalten zu bleiben"
  assert_eq "$(readlink "$(cachefile)")" "$target"
}

# Ruling 20: "-k 5" fehlte bisher -- ein Kindprozess, der SIGTERM
# ignoriert, liefe trotz "timeout" unbegrenzt weiter, und das Versprechen
# "die Bar blockiert nie" stuende auf seiner Kulanz. Ein Doppelgaenger, der
# SIGTERM ignoriert, waere in einer Testsuite selbst fragil (Timing,
# Signal-Handling je nach System) -- deshalb hier bewusst eine
# Struktur-Pruefung statt einer Zeitmessung: ein Protokoll-Doppelgaenger
# fuer "timeout" (ueber TIMEOUT_BIN, nicht ueber den PATH -- das Skript
# ruft timeout absolut auf) zeichnet seinen Aufruf auf und reicht ihn an
# den echten timeout weiter, damit der eigentliche Aufruf trotzdem
# funktioniert. Ehrlich in dem Sinn, dass sie genau das behauptet, was sie
# zeigt: die Form des Aufrufs, nicht sein Verhalten unter einem
# hartnaeckigen Kindprozess.
test_timeout_aufruf_traegt_minus_k_5() {
  stub_opencode
  make_stub timeout 'exec /usr/bin/timeout "$@"'
  export TIMEOUT_BIN="$SANDBOX/stub/timeout"
  "$MODELS" list --json --refresh >/dev/null
  assert_contains "$(stub_log timeout)" "-k 5"
}

run_tests
