#!/usr/bin/env bash
# Fuehrt alle Suiten. Scheitert, wenn eine Suite die echte Config oder den
# echten Zustand angefasst hat -- ein nicht gesetztes XDG_STATE_HOME hat in
# einem Schwesterwidget genau das getan, und die Tests waren trotzdem gruen.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export SANDBOX_ERR="$(mktemp)"

REAL_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/smartalb-opencode"
REAL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/smartalb.opencode"
REAL_CFG="$HOME/.config/omarchy"

# Eine Markerdatei statt eines Zeitfensters: "-newermt '-1 second'" erwischt
# nur einen Schreibzugriff in der letzten Sekunde vor der Pruefung und wuerde
# genau das Leck verfehlen, das diese Pruefung finden soll. Der Marker muss
# vor der ersten Suite entstehen; $REAL_CFG enthaelt legitim Dateien anderer
# Plugins, daher zaehlt nur, was juenger als der Marker ist.
marker="$(mktemp)"

total_pass=0; total_fail=0
# Minor aus der Review: eine Suite, die vor run_tests abstuerzt (Syntaxfehler,
# fehlende Quelle wie ein noch nicht angelegtes bin/*.sh), traegt weder zu
# "ok" noch zu "FAIL" bei -- der Lauf blieb bislang trotzdem gruen. Deshalb
# zusaetzlich den Exit-Status jeder Suite selbst pruefen.
declare -a suite_errors=()
for suite in test/*.test.sh; do
  printf '\n== %s\n' "$(basename "$suite")"
  # shellcheck disable=SC1090
  out="$(bash "$suite")"; suite_status=$?
  printf '%s\n' "$out"
  suite_fail="$(printf '%s' "$out" | grep -c '^  FAIL' || true)"
  total_pass=$((total_pass + $(printf '%s' "$out" | grep -c '^  ok  ' || true)))
  total_fail=$((total_fail + suite_fail))
  # Ruling 18: eine Suite, die vollstaendig durchlief und dabei echte FAILs
  # meldete, ist kein Absturz -- nur eine Suite, die VOR run_tests abbricht
  # (Syntaxfehler, fehlende Quelle) liefert weder "ok" noch "FAIL" und
  # trotzdem einen von 0 verschiedenen Exit-Status. Deshalb beides pruefen:
  # von 0 verschiedener Exit UND keine einzige gezaehlte FAIL-Zeile. Sonst
  # wuerde jede Suite mit mindestens einem echten Fehlschlag (run_tests gibt
  # seit Ruling 15 selbst [ "$FAIL" -eq 0 ] zurueck) hier zusaetzlich als
  # Absturz gemeldet, obwohl sie sauber durchlief und der Fehlschlag schon
  # ueber total_fail gezaehlt wird.
  if [ "$suite_status" -ne 0 ] && [ "$suite_fail" -eq 0 ]; then
    suite_errors+=("$(basename "$suite") (Exit $suite_status)")
  fi
done

leaked="$(find "$REAL_STATE" "$REAL_CACHE" "$REAL_CFG" -newer "$marker" 2>/dev/null | sort)"
if [ -n "$leaked" ]; then
  printf '\nSANDBOX-LECK: eine Suite hat echte Dateien angefasst:\n%s\n' "$leaked" >&2
  exit 2
fi

if [ "${#suite_errors[@]}" -gt 0 ]; then
  printf '\nSUITE-FEHLER: folgende Suiten sind abgebrochen, statt ihre Tests durchzufuehren:\n' >&2
  printf '  %s\n' "${suite_errors[@]}" >&2
  exit 1
fi

printf '\n%s bestanden, %s fehlgeschlagen\n' "$total_pass" "$total_fail"
[ "$total_fail" -eq 0 ]
