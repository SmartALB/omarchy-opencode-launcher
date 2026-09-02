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
  for tool in bash jq sed grep head tail cut cat mktemp mv rm mkdir basename dirname \
              readlink env printf sort tr wc sha1sum timeout sleep find stat ln id \
              seq touch date awk sqlite3 diff cp; do
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
  local fn
  for fn in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
    if ( set -e; setup_sandbox; "$fn" ) >/dev/null 2>"$SANDBOX_ERR"; then
      PASS=$((PASS+1)); printf '  ok   %s\n' "$fn"
    else
      FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$fn"; cat "$SANDBOX_ERR" >&2
    fi
  done
}
