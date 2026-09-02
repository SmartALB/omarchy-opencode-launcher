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
  ! valid_model_id "openai/a;id"        || fail "Semikolon akzeptiert"
  ! valid_model_id "openai/a|id"        || fail "Pipe akzeptiert"
  ! valid_model_id "openai/a&&id"       || fail "Und-Verknuepfung akzeptiert"
  ! valid_model_id 'openai/`id`'        || fail "Backtick-Substitution akzeptiert"
}

# Ruling 7: die models.dev-Katalogpruefung zeigte reale Modell-IDs mit @, :
# und ~ im Folgesegment -- diese Zeichen muessen durchgelassen werden, ohne
# dass sich die Ablehnung von Shell-Metazeichen (siehe Test oben) aufweicht.
test_valid_model_id_akzeptiert_katalog_sonderzeichen() {
  . "$COMMON"
  valid_model_id "cloudflare-workers-ai/@cf/nvidia/nemotron-3-120b-a12b" \
    || fail "@ im Folgesegment abgelehnt"
  valid_model_id "nano-gpt/gemini-2.5-flash-preview-04-17:thinking" \
    || fail ": im Folgesegment abgelehnt"
  valid_model_id "openrouter/~anthropic/claude-opus-latest" \
    || fail "~ im Folgesegment abgelehnt"
  valid_model_id "lmstudio/openai/gpt-oss-20b" \
    || fail "drei Segmente ohne Sonderzeichen abgelehnt"
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

# Minor aus der Review: die ASCII-Zusicherung war bisher nur an einem
# Beispiel mit reinem ASCII-Rauschen ("!") belegt, nie an echten
# Mehrbyte-Zeichen. Deutsche Umlaute sind UTF-8-kodiert zwei Bytes je
# Zeichen; unter LC_ALL=C landen beide Bytes ausserhalb von [a-z0-9] und
# muessten als je ein Bindestrich zusammenfallen -- nicht als rohe Bytes im
# Ergebnis auftauchen.
test_app_id_slug_bleibt_ascii_bei_umlauten() {
  . "$COMMON"
  a="$(app_id_for '/home/x/Prüfstände')"
  b="$(app_id_for '/home/x/Größe')"
  assert_ne "$a" "$b"
  [[ "$a" =~ ^org\.omarchy\.opencode\.[a-z0-9-]+$ ]] || fail "Slug enthaelt Nicht-ASCII: $a"
  [[ "$b" =~ ^org\.omarchy\.opencode\.[a-z0-9-]+$ ]] || fail "Slug enthaelt Nicht-ASCII: $b"
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
  # Ruling 15, Nachbeben: "cmd; assert_status \"\$?\" N" ist unter echtem
  # set -e nicht sicher, wenn N != 0 ist -- ein fehlschlagender Befehl, der
  # kein Teil eines if/&&/||/! ist, bricht die Funktion sofort ab, BEVOR
  # assert_status je laeuft. Solange run_tests dieses set -e selbst per
  # if-Bedingung ausser Kraft setzte, fiel das nie auf; seit dem Fix von
  # Ruling 15 wirkt set -e wieder echt, und dieser Test brach hier ab,
  # bevor der Exit-Code je geprueft wurde. Fix: "cmd || rc=\$?" nutzt die
  # ||-Ausnahme von set -e, um den erwarteten Fehlschlag einzufangen, ohne
  # ihn zum Abbruch zu machen.
  rc=0; read_capped "$f" 100 >/dev/null || rc=$?
  assert_status "$rc" 8
}

test_read_capped_zaehlt_bytes_nicht_zeichen() {
  . "$COMMON"
  f="$SANDBOX/f"; printf 'ääää' > "$f"   # 8 Bytes, 4 Zeichen
  rc=0; read_capped "$f" 7 >/dev/null || rc=$?
  assert_status "$rc" 8
  out="$(read_capped "$f" 8)"; assert_eq "$?" 0
}

test_read_capped_zaehlt_abschliessende_zeilenumbrueche_mit() {
  . "$COMMON"
  f="$SANDBOX/f"; printf 'ab\n\n' > "$f"  # 4 Bytes
  rc=0; read_capped "$f" 3 >/dev/null || rc=$?
  assert_status "$rc" 8
}

test_bin_standards_sind_absolut() {
  # Ohne gesetzte Ueberschreibung muss jeder Programmpfad absolut sein.
  # Minor aus der Review: die Variablen wurden entpackt, aber nur acht von
  # zehn tatsaechlich geprueft -- BIN_DATE und BIN_STAT fehlten in der
  # Schleife. Ausserdem BIN_WC/BIN_CAT (Ruling 8) gleich mit aufgenommen,
  # sonst haette die neue Variable denselben blinden Fleck von Anfang an.
  ( unset JQ_BIN HEAD_BIN SQLITE_BIN HYPRCTL_BIN TIMEOUT_BIN MKTEMP_BIN MV_BIN SHA1_BIN \
          DATE_BIN STAT_BIN WC_BIN CAT_BIN
    . "$COMMON"
    for v in "$BIN_JQ" "$BIN_HEAD" "$BIN_SQLITE" "$BIN_HYPRCTL" "$BIN_TIMEOUT" \
             "$BIN_MKTEMP" "$BIN_MV" "$BIN_SHA1" "$BIN_DATE" "$BIN_STAT" \
             "$BIN_WC" "$BIN_CAT"; do
      case "$v" in /usr/bin/*) ;; *) fail "nicht absolut: $v" ;; esac
    done )
}

test_read_stream_capped_begrenzt_stdin() {
  . "$COMMON"
  rc=0; printf 'abcd' | read_stream_capped 3 >/dev/null || rc=$?
  assert_status "$rc" 8
  out="$(printf 'abc' | read_stream_capped 3)"; assert_eq "$out" "abc"
}

# Ruling 8: die alte Zaehlung ueber ${#data} lief durch eine Bash-Variable,
# und Kommandosubstitution ignoriert NUL-Bytes -- eine Datei aus lauter
# NUL-Bytes waere also immer als "0 Bytes lang" durchgegangen, egal wie
# gross sie wirklich war. Diese beiden Tests haetten mit der alten Fassung
# nicht bestanden (max+1 NUL-Bytes waeren als leer akzeptiert worden statt
# mit 8 abgelehnt).
#
# Wichtig: die Ausgabe von read_capped wird hier nie mit "$(...)" in eine
# Bash-Variable eingefangen, sondern direkt in eine Datei umgeleitet und
# erst von dort mit "wc -c" gezaehlt -- genau das vermeidet die Warnung
# "command substitution: ignored null byte in input", die bash sonst beim
# Einfangen von NUL-haltigen Daten in eine Variable ausgibt. Damit bleibt
# die Runner-Ausgabe sauber, ohne dass irgendwo eine Warnung weggeleitet
# werden muesste.
test_read_capped_zaehlt_nul_bytes_korrekt() {
  . "$COMMON"
  f="$SANDBOX/f.nul"
  head -c 9 /dev/zero > "$f"                 # 9 NUL-Bytes, max=8
  rc=0; read_capped "$f" 8 >/dev/null || rc=$?
  assert_status "$rc" 8

  head -c 8 /dev/zero > "$f"                 # genau 8 NUL-Bytes, max=8
  out_f="$SANDBOX/out.nul"
  read_capped "$f" 8 > "$out_f"; assert_status "$?" 0
  n="$(wc -c < "$out_f" | tr -d ' ')"
  assert_eq "$n" 8
}

test_read_stream_capped_zaehlt_nul_bytes_korrekt() {
  . "$COMMON"
  in_f="$SANDBOX/in.nul"
  head -c 9 /dev/zero > "$in_f"              # 9 NUL-Bytes, max=8
  rc=0; read_stream_capped 8 < "$in_f" >/dev/null || rc=$?
  assert_status "$rc" 8

  head -c 8 /dev/zero > "$in_f"              # genau 8 NUL-Bytes, max=8
  out_f="$SANDBOX/out2.nul"
  read_stream_capped 8 < "$in_f" > "$out_f"; assert_status "$?" 0
  n="$(wc -c < "$out_f" | tr -d ' ')"
  assert_eq "$n" 8
}

run_tests
