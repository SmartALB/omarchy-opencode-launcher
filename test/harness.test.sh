#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
HARNESS="$DIR/lib/harness.sh"

# Ruling 15: staendiger Waechter gegen den if-Bedingungs-Fallstrick in
# run_tests. "if ( set -e; ...; \"\$fn\" ); then ok; else FAIL; fi" setzte
# die errexit-Wirkung fuer alles ausser Kraft, was Teil einer if-Bedingung
# ist -- auch innerhalb einer Subshell, die selbst erneut "set -e" setzt.
# Ein blosser fehlschlagender Befehl in einem Test (kein assert_*, kein
# explizites exit) wurde dadurch faelschlich als "ok" gemeldet. Diese
# Suite erzeugt eine echte Wegwerf-Suite in der eigenen Sandbox und fuehrt
# sie mit einem eigenen "bash"-Prozess aus, statt run_tests hier nur zu
# lesen -- nur so laesst sich das reale Verhalten der Schleife pruefen,
# nicht nur ihr Quelltext.
#
# Die Ausgabe jeder inneren Wegwerf-Suite wird immer per
# Kommandosubstitution eingefangen (stdout UND stderr), nie direkt
# durchgereicht: sonst wuerden deren eigene "ok"/"FAIL"-Zeilen die Zaehlung
# von test/run.sh fuer DIESE Suite hier verfaelschen.
#
# Und: "out=\$(cmd)"; rc=\$?" ist selbst wieder nicht -e-sicher, wenn cmd
# absichtlich fehlschlaegt (hier: der Wegwerf-Aufruf mit Exit != 0) --
# dieselbe Falle, die diese ganze Suite ueberhaupt erst noetig gemacht hat,
# ist beim ersten Entwurf hier selbst wieder aufgetreten (Exit ohne jede
# DEBUG-Ausgabe, siehe Fix-Report). Deshalb "rc=0; out=\$(cmd) || rc=\$?".

write_probe() {  # write_probe <datei> <testkoerper>
  cat > "$1" <<PROBE
#!/usr/bin/env bash
set -uo pipefail
. "$HARNESS"

$2

run_tests
PROBE
}

test_blanker_fehlschlag_wird_als_fail_gemeldet_und_bricht_die_suite_nicht_leise_durch() {
  probe="$SANDBOX/probe_blank.test.sh"
  write_probe "$probe" 'test_x() {
  /usr/bin/false
  echo NACH
}'
  rc=0; out="$(bash "$probe" 2>&1)" || rc=$?
  assert_contains "$out" "FAIL test_x"
  assert_not_contains "$out" "ok   test_x"
  assert_not_contains "$out" "NACH"
  [ "$rc" -ne 0 ] || fail "erwartet: von 0 verschiedener Exit-Status" "erhalten: 0"
}

test_erfolgreicher_test_wird_als_ok_gemeldet_und_die_suite_geht_glatt_durch() {
  probe="$SANDBOX/probe_ok.test.sh"
  write_probe "$probe" 'test_y() {
  true
}'
  rc=0; out="$(bash "$probe" 2>&1)" || rc=$?
  assert_contains "$out" "ok   test_y"
  assert_status "$rc" 0
}

test_fail_aufruf_wird_weiterhin_als_fail_gemeldet() {
  # Beleg, dass die Reparatur den normalen Zusicherungsweg nicht mitbricht:
  # ein Test, der "fail" ueber ein fehlgeschlagenes assert_eq erreicht,
  # muss weiterhin FAIL melden.
  probe="$SANDBOX/probe_fail.test.sh"
  write_probe "$probe" 'test_z() {
  assert_eq "x" "y"
}'
  rc=0; out="$(bash "$probe" 2>&1)" || rc=$?
  assert_contains "$out" "FAIL test_z"
  [ "$rc" -ne 0 ] || fail "erwartet: von 0 verschiedener Exit-Status" "erhalten: 0"
}

run_tests
