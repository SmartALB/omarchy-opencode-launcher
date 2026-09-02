#!/usr/bin/env bash
# Sandbox und Zusicherungen. Wird gesourct, nie ausgefuehrt.
# Muster uebernommen aus smartalb.vpn: ein exklusiver PATH statt eines
# vorangestellten Stub-Verzeichnisses -- sonst findet ein Test, der einen
# Doppelgaenger entfernt, das echte Programm und prueft nichts.
PASS=0
FAIL=0
# Eine Suite laeuft auch einzeln (bash test/store.test.sh). Ohne Standard
# waere $SANDBOX_ERR unter `set -u` ungebunden und jede Suite braeche ab.
: "${SANDBOX_ERR:=$(mktemp)}"

fail() { printf '     %s\n' "$@" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "erwartet: $2" "erhalten: $1"; }
assert_ne() { [ "$1" != "$2" ] || fail "haette sich unterscheiden muessen: $1"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "erwartete Teilkette: $2" "in: $1";; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "unerwartete Teilkette: $2" "in: $1";; esac; }
assert_status() { [ "$1" = "$2" ] || fail "erwarteter Exit: $2" "erhalten: $1"; }

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  trap 'rm -rf "$SANDBOX"' EXIT
  export HOME="$SANDBOX/home"
  export XDG_STATE_HOME="$SANDBOX/state"
  export XDG_CACHE_HOME="$SANDBOX/cache"
  mkdir -p "$HOME/.config/omarchy" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
           "$SANDBOX/stub" "$SANDBOX/sysbin" "$SANDBOX/log"
  local tool toolpath
  # chmod ergaenzt (Task 2, Fix Runde 2): fehlte bisher, wodurch sowohl
  # make_stubs eigenes "chmod +x" als auch das Skript-eigene "chmod 600"
  # in publish() innerhalb jedes Testlaufs still ins Leere liefen -- ein
  # per Doppelgaenger erzeugter Ersatzbefehl blieb dadurch nicht ausfuehrbar
  # und ein Aufruf schlug mit "Permission denied" fehl, statt das
  # verabredete Doppelgaenger-Verhalten zu zeigen. Reine Erweiterung, keine
  # Einschraenkung -- passend zum bereits breiteren Werkzeugkatalog dieser
  # Harness.
  for tool in bash jq sed grep head tail cut cat mktemp mv rm mkdir basename dirname \
              readlink env printf sort tr wc sha1sum timeout sleep find stat ln id \
              seq touch date awk sqlite3 diff cp chmod; do
    toolpath="$(command -v "$tool" 2>/dev/null)" || true
    [ -n "$toolpath" ] && ln -sf "$toolpath" "$SANDBOX/sysbin/$tool"
  done
  export PATH="$SANDBOX/stub:$SANDBOX/sysbin"
}

# Doppelgaenger, der seinen Aufruf protokolliert und optional etwas ausgibt.
# $SANDBOX/log/<name>.log erhaelt eine Zeile je Aufruf.
make_stub() {
  local name="$1" body="${2:-}"
  cat > "$SANDBOX/stub/$name" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SANDBOX/log/$name.log"
$body
STUB
  chmod +x "$SANDBOX/stub/$name"
}

stub_calls() { local n="$1"; [ -f "$SANDBOX/log/$n.log" ] && wc -l < "$SANDBOX/log/$n.log" | tr -d ' ' || echo 0; }
stub_log()   { cat "$SANDBOX/log/$1.log" 2>/dev/null || true; }

run_tests() {
  local fn rc
  for fn in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    # Ruling 15: NICHT als "if ( ... ); then ... fi" -- Bash setzt die
    # errexit-Wirkung fuer alles ausser Kraft, was Teil einer if/while/until-
    # Bedingung ist, und zwar auch innerhalb einer Subshell, die selbst
    # erneut "set -e" setzt. Ein blosser fehlschlagender Befehl in einem
    # Test (kein assert_*, kein explizites exit) wurde dadurch als "ok"
    # gemeldet: "if ( set -e; false; echo NACH ); then echo OK; else echo
    # FAIL; fi" gibt NACH und OK aus, nie FAIL. Deshalb die Subshell erst
    # ausserhalb jeder Bedingung ausfuehren und ihren Status danach in einer
    # eigenen Anweisung einfangen.
    ( set -e; setup_sandbox; "$fn" ) >/dev/null 2>"$SANDBOX_ERR"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      PASS=$((PASS+1)); printf '  ok   %s\n' "$fn"
    else
      FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$fn"; cat "$SANDBOX_ERR" >&2
    fi
  done
  # Eigener Rueckgabewert statt implizit dem letzten Befehl der Schleife
  # ueberlassen ("cat" im FAIL-Zweig gelingt fast immer und wuerde run_tests
  # selbst wieder auf 0 zurueckfallen lassen, egal wie viele Tests scheiterten).
  # Damit gibt "bash irgendeine.test.sh" (run_tests ist deren letzte Anweisung)
  # jetzt zuverlaessig einen von 0 verschiedenen Exit-Status zurueck, sobald
  # mindestens ein Test FAIL gemeldet hat.
  [ "$FAIL" -eq 0 ]
}
