#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
COMMON="$DIR/../bin/_common.sh"

test_valid_model_id_akzeptiert_zwei_und_drei_segmente() {
  . "$COMMON"
  valid_model_id "openai/gpt-5-codex" || fail "zwei Segmente abgelehnt"
  valid_model_id "lmstudio/openai/gpt-oss-20b" || fail "drei Segmente abgelehnt"
}

test_valid_model_id_lehnt_kaputte_ids_ab() {
  . "$COMMON"
  ! valid_model_id "gpt-oss-20b"        || fail "ein Segment akzeptiert"
  ! valid_model_id "/openai/gpt"        || fail "fuehrender Schraegstrich akzeptiert"
  ! valid_model_id "openai/gpt 5"       || fail "Leerzeichen akzeptiert"
  ! valid_model_id ""                   || fail "leer akzeptiert"
  ! valid_model_id 'openai/$(id)'       || fail "Substitution akzeptiert"
}

test_app_id_unterscheidet_gleichnamige_ordner() {
  . "$COMMON"
  a="$(app_id_for /home/x/eins/web)"
  b="$(app_id_for /home/x/zwei/web)"
  assert_ne "$a" "$b"
  assert_contains "$a" "org.omarchy.opencode.web-"
}

test_app_id_slug_ist_kleingeschrieben_und_ascii() {
  . "$COMMON"
  assert_contains "$(app_id_for '/home/x/Mein Projekt!')" "org.omarchy.opencode.mein-projekt-"
}

test_expand_und_abbrev_sind_gegenstuecke() {
  . "$COMMON"
  assert_eq "$(expand_path '~/git/x')" "$HOME/git/x"
  assert_eq "$(tilde_abbrev "$HOME/git/x")" '~/git/x'
  assert_eq "$(expand_path '/abs/x')" '/abs/x'
}

test_read_capped_nimmt_max_und_lehnt_max_plus_eins_ab() {
  . "$COMMON"
  f="$SANDBOX/f"
  head -c 100 /dev/zero | tr '\0' 'a' > "$f"
  out="$(read_capped "$f" 100)"; assert_eq "${#out}" 100
  head -c 101 /dev/zero | tr '\0' 'a' > "$f"
  read_capped "$f" 100 >/dev/null; assert_status "$?" 8
}

test_read_capped_zaehlt_bytes_nicht_zeichen() {
  . "$COMMON"
  f="$SANDBOX/f"; printf 'ääää' > "$f"   # 8 Bytes, 4 Zeichen
  read_capped "$f" 7 >/dev/null; assert_status "$?" 8
  out="$(read_capped "$f" 8)"; assert_eq "$?" 0
}

test_read_capped_zaehlt_abschliessende_zeilenumbrueche_mit() {
  . "$COMMON"
  f="$SANDBOX/f"; printf 'ab\n\n' > "$f"  # 4 Bytes
  read_capped "$f" 3 >/dev/null; assert_status "$?" 8
}

test_bin_standards_sind_absolut() {
  # Ohne gesetzte Ueberschreibung muss jeder Programmpfad absolut sein.
  ( unset JQ_BIN HEAD_BIN SQLITE_BIN HYPRCTL_BIN TIMEOUT_BIN MKTEMP_BIN MV_BIN SHA1_BIN \
          DATE_BIN STAT_BIN
    . "$COMMON"
    for v in "$BIN_JQ" "$BIN_HEAD" "$BIN_SQLITE" "$BIN_HYPRCTL" "$BIN_TIMEOUT" \
             "$BIN_MKTEMP" "$BIN_MV" "$BIN_SHA1"; do
      case "$v" in /usr/bin/*) ;; *) fail "nicht absolut: $v" ;; esac
    done )
}

test_read_stream_capped_begrenzt_stdin() {
  . "$COMMON"
  printf 'abcd' | read_stream_capped 3 >/dev/null; assert_status "$?" 8
  out="$(printf 'abc' | read_stream_capped 3)"; assert_eq "$out" "abc"
}

run_tests
