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
for suite in test/*.test.sh; do
  printf '\n== %s\n' "$(basename "$suite")"
  # shellcheck disable=SC1090
  out="$(bash "$suite")" ; printf '%s\n' "$out"
  total_pass=$((total_pass + $(printf '%s' "$out" | grep -c '^  ok  ' || true)))
  total_fail=$((total_fail + $(printf '%s' "$out" | grep -c '^  FAIL' || true)))
done

leaked="$(find "$REAL_STATE" "$REAL_CACHE" "$REAL_CFG" -newer "$marker" 2>/dev/null | sort)"
if [ -n "$leaked" ]; then
  printf '\nSANDBOX-LECK: eine Suite hat echte Dateien angefasst:\n%s\n' "$leaked" >&2
  exit 2
fi

printf '\n%s bestanden, %s fehlgeschlagen\n' "$total_pass" "$total_fail"
[ "$total_fail" -eq 0 ]
