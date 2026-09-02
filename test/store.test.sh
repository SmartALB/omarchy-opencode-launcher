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

# Ruling 12: die alte, einzelne Atomaritaets-Testfunktion setzte den
# jq-Doppelgaenger auch fuer den lesenden schemaVersion-Aufruf in load()
# ein. Dieser scheiterte dort zuerst, load() gab 9 zurueck, und weder der
# Transform-jq in edit() (Zeile 57) noch publish() (Zeile 58) -- also weder
# mktemp noch mv -- wurden je erreicht. Der Test war damit ein Duplikat von
# test_kaputtes_json_wird_nicht_stillschweigend_ersetzt unter anderem Namen
# und deckte keinen der drei Fehlerpfade ab, die diese Aufgabe eigentlich
# absichern soll. Ersetzt durch drei Tests, je einer pro Fehlerpfad.

test_set_transform_jq_schlaegt_fehl_nachdem_das_lesen_gelang() {
  "$STORE" set /p/eins openai/a >/dev/null
  before="$(cat "$(statefile)")"
  # Doppelgaenger mit Zaehler in $SANDBOX: der erste jq-Aufruf (das lesende
  # schemaVersion-jq in load(), Zeile 30) geht unveraendert an den echten
  # jq durch -- load() muss also gelingen. Erst der zweite Aufruf (die
  # Transformation in edit(), Zeile 57) scheitert, und zwar nicht still:
  # er gibt vor dem Scheitern noch etwas auf stdout aus, damit die Pruefung
  # wirklich das "|| return 1" nach dem Transform-jq trifft und nicht
  # zufaellig durch publish()s Leerinhalts-Waechter (Zeile 48) abgefangen
  # wird, der nur bei WIRKLICH leerer Ausgabe greift. Ueber JQ_BIN, nicht
  # ueber den PATH -- das Skript ruft jq absolut auf.
  cat > "$SANDBOX/stub/jq" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/log/jq.log"
n_file="$SANDBOX/jq-calls.count"
n=\$(( \$(cat "\$n_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" > "\$n_file"
if [ "\$n" -eq 1 ]; then
  exec /usr/bin/jq "\$@"
else
  printf 'sollte-nie-geschrieben-werden'
  exit 3
fi
STUB
  chmod +x "$SANDBOX/stub/jq"

  JQ_BIN="$SANDBOX/stub/jq" "$STORE" set /p/eins openai/b >/dev/null 2>&1
  assert_ne "$?" "0"
  assert_eq "$(cat "$(statefile)")" "$before"
  d="$(dirname "$(statefile)")"
  assert_eq "$(find "$d" -name '*.tmp*' | wc -l | tr -d ' ')" "0"
  # Beleg aus dem Log des Doppelgaengers, dass der zweite jq-Aufruf
  # tatsaechlich stattfand -- sonst koennte der Test unbemerkt zurueck in
  # den reinen Lesepfad abdriften, den load() schon allein abdeckt.
  assert_eq "$(stub_calls jq)" "2"
}

test_set_transform_jq_liefert_leere_ausgabe() {
  "$STORE" set /p/eins openai/a >/dev/null
  before="$(cat "$(statefile)")"
  # Doppelgaenger: der erste Aufruf (Lesen) geht durch, der zweite
  # (Transformation) meldet Erfolg (Exit 0), liefert aber nichts auf
  # stdout. publish()s eigener Leerinhalts-Waechter (Zeile 48) muss das
  # auffangen, sonst wuerde die alte Datei durch eine leere ersetzt.
  cat > "$SANDBOX/stub/jq" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/log/jq.log"
n_file="$SANDBOX/jq-calls.count"
n=\$(( \$(cat "\$n_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\$n" > "\$n_file"
if [ "\$n" -eq 1 ]; then exec /usr/bin/jq "\$@"; fi
# zweiter und jeder weitere Aufruf: Erfolg (Exit 0), aber keine Ausgabe.
STUB
  chmod +x "$SANDBOX/stub/jq"

  JQ_BIN="$SANDBOX/stub/jq" "$STORE" set /p/eins openai/b >/dev/null 2>&1
  assert_ne "$?" "0"
  assert_eq "$(cat "$(statefile)")" "$before"
  d="$(dirname "$(statefile)")"
  assert_eq "$(find "$d" -name '*.tmp*' | wc -l | tr -d ' ')" "0"
  assert_eq "$(stub_calls jq)" "2"
}

test_set_mv_schlaegt_fehl_alte_datei_bleibt_ohne_rest() {
  "$STORE" set /p/eins openai/a >/dev/null
  before="$(cat "$(statefile)")"
  # mv scheitert erst NACH einer erfolgreichen Transformation: mktemp und
  # der schreibende cat laufen echt, nur der abschliessende Rename schlaegt
  # fehl. Ueber MV_BIN, nicht ueber den PATH -- das Skript ruft mv absolut auf.
  make_stub mv 'exit 1'
  MV_BIN="$SANDBOX/stub/mv" "$STORE" set /p/eins openai/b >/dev/null 2>&1
  assert_ne "$?" "0"
  assert_eq "$(cat "$(statefile)")" "$before"
  d="$(dirname "$(statefile)")"
  assert_eq "$(find "$d" -name '*.tmp*' | wc -l | tr -d ' ')" "0"
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
