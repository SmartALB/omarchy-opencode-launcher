#!/usr/bin/env bash
# Gemeinsame Helfer der smartalb.opencode-Skripte. Wird gesourct, nie ausgefuehrt.
#
# LC_ALL=C, damit ${#var} Bytes zaehlt und nicht Zeichen: eine Grenze in
# Bytes, die in Zeichen geprueft wird, ist keine Grenze.
export LC_ALL=C

MAX_FILE=1048576

# Der Standard ist absolut; die Umgebungsvariable existiert allein fuer die
# Tests, die einen Doppelgaenger einsetzen muessen. Ein vorangestelltes
# PATH-Verzeichnis reicht dafuer nicht, weil hier nie ueber den PATH gesucht
# wird -- und ohne diese Schalter wuerden die Doppelgaenger stillschweigend
# ignoriert und die Tests bestaenden aus dem falschen Grund.
BIN_HEAD="${HEAD_BIN:-/usr/bin/head}"
BIN_JQ="${JQ_BIN:-/usr/bin/jq}"
BIN_SQLITE="${SQLITE_BIN:-/usr/bin/sqlite3}"
BIN_HYPRCTL="${HYPRCTL_BIN:-/usr/bin/hyprctl}"
BIN_TIMEOUT="${TIMEOUT_BIN:-/usr/bin/timeout}"
BIN_MKTEMP="${MKTEMP_BIN:-/usr/bin/mktemp}"
BIN_MV="${MV_BIN:-/usr/bin/mv}"
BIN_SHA1="${SHA1_BIN:-/usr/bin/sha1sum}"
BIN_DATE="${DATE_BIN:-/usr/bin/date}"
BIN_STAT="${STAT_BIN:-/usr/bin/stat}"

expand_path() {
  case "$1" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

tilde_abbrev() {
  case "$1" in
    "$HOME") printf '~\n' ;;
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Fensterklasse fuer ein Projektverzeichnis. Der Hash ist noetig, weil zwei
# Projekte mit je einem Unterordner "web" sonst dieselbe Klasse erzeugen und
# ein Klick das falsche Fenster fokussiert.
app_id_for() {
  local dir="$1" slug hash4
  slug="$(basename -- "$dir" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//')"
  [ -n "$slug" ] || slug="project"
  hash4="$(printf '%s' "$dir" | "$BIN_SHA1" | cut -c1-4)"
  printf 'org.omarchy.opencode.%s-%s\n' "$slug" "$hash4"
}

# provider/model, mit zwei ODER MEHR Segmenten: lmstudio/openai/gpt-oss-20b
# ist eine gueltige ID. Keine Leerzeichen, kein leeres Segment, keine
# Shell-Metazeichen -- ein Segment als "[^/[:space:]]+" gefasst wuerde
# "openai/$(id)" durchlassen, weil $, ( und ) weder Schraegstrich noch
# Leerraum sind.
valid_model_id() {
  [ -n "${1:-}" ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9~._-]+(/[A-Za-z0-9._-]+)+$ ]] || return 1
  return 0
}

valid_agent_name() {
  [ -n "${1:-}" ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  return 0
}

# Liest MAX+1 Bytes und lehnt ab, wenn das zusaetzliche Byte ankam. Das
# "; printf X" haelt abschliessende Zeilenumbrueche fest, die die
# Kommandosubstitution sonst verschluckt -- sonst waere eine Datei von
# MAX+1 Bytes, deren letztes Byte \n ist, unbemerkt durchgegangen.
read_capped() {
  local f="$1" max="$2" data
  [ -r "$f" ] || return 1
  data="$("$BIN_HEAD" -c "$((max + 1))" -- "$f"; printf X)" || return 1
  data="${data%X}"
  [ "${#data}" -le "$max" ] || return 8
  printf '%s' "$data"
}

read_stream_capped() {
  local max="$1" data
  data="$("$BIN_HEAD" -c "$((max + 1))"; printf X)" || return 1
  data="${data%X}"
  [ "${#data}" -le "$max" ] || return 8
  printf '%s' "$data"
}
