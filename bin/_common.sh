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
BIN_WC="${WC_BIN:-/usr/bin/wc}"
BIN_CAT="${CAT_BIN:-/usr/bin/cat}"

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

# Kanonische Form eines Projektverzeichnisses -- die EINZIGE Stelle, an der
# das passiert.
#
# A1: die App-Id haengt am Pfad-TEXT (siehe app_id_for unten). "." und
# "/abs/proj", "/abs/proj" und "/abs/proj/", ein Pfad durch einen Symlink
# und sein Ziel sind derselbe Ordner, aber verschiedene Texte -- und damit
# verschiedene App-Ids. omarchy-opencode-launch kanonisierte deshalb schon
# immer, omarchy-opencode-projects nicht: die Laufanzeige des Panels und
# das Bar-Label "Running count" lagen fuer jedes so angeheftete Projekt
# dauerhaft falsch, weil die beiden Skripte zwei verschiedene App-Ids fuer
# dasselbe Fenster errechneten. Zwei Kopien derselben Formel laufen
# auseinander; eine Funktion kann das nicht.
#
# Rueckfall auf den rohen Pfad, wenn "cd" scheitert (Verzeichnis geloescht,
# keine Rechte): dann ist die App-Id zwar nicht kanonisch, aber in beiden
# Skripten gleich -- und genau darauf kommt es an.
canon_dir() {
  local d
  d="$(cd "$1" && pwd -P)" || d="$1"
  printf '%s\n' "$d"
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
# Leerraum sind. Ruling 7: die models.dev-Katalogpruefung zeigte, dass echte
# IDs @, : und ~ im Folgesegment brauchen (z.B. "cloudflare-workers-ai/@cf/
# nvidia/nemotron-3-120b-a12b", "nano-gpt/gemini-2.5-flash-preview-04-17:
# thinking", "openrouter/~anthropic/claude-opus-latest") -- daher die
# erweiterte, aber weiterhin abzaehlende Positivliste je Folgesegment.
valid_model_id() {
  [ -n "${1:-}" ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9~._-]+(/[A-Za-z0-9._:@~+-]+)+$ ]] || return 1
  return 0
}

valid_agent_name() {
  [ -n "${1:-}" ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  return 0
}

# Liest MAX+1 Bytes und lehnt ab, wenn das zusaetzliche Byte ankam.
#
# Ruling 8: die fruehere Fassung fuehrte die gelesenen Bytes durch eine
# Bash-Variable und zaehlte mit ${#data} -- Kommandosubstitution ignoriert
# NUL-Bytes ("bash: warning: command substitution: ignored null byte in
# input"), wodurch ${#data} zu klein ausfaellt und eine Datei ueber der
# Grenze durchrutschen konnte. Jetzt zaehlt "wc -c" auf dem rohen Bytestrom
# (Pipe, keine Bash-Variable), und der Status von head selbst kommt ueber
# PIPESTATUS[0] -- das alte "; printf X" pruefte in Wahrheit nur den Erfolg
# von printf, nie den von head. Die PIPESTATUS-Abfrage muss im selben
# Prozess wie die Pipe stattfinden: Kommandosubstitution laeuft in einer
# Subshell, und PIPESTATUS einer Pipe darin ist nach aussen nicht sichtbar
# -- deshalb wird das Ergebnis von PIPESTATUS[0] hier direkt in derselben
# Subshell an die Zaehlausgabe angehaengt und danach wieder zerlegt.
#
# Die Ausgabe erfolgt durch einen zweiten, eigenstaendigen head-Aufruf mit
# "-c $max": das ist absichtlich ein zweites Oeffnen der Datei, aber sicher,
# weil diese Ausgabe strukturell auf $max Bytes begrenzt ist -- selbst wenn
# die Datei zwischen den beiden Lesevorgaengen waechst, kann nicht mehr als
# $max herauskommen. Das unterscheidet sich vom privilegierten
# Veroeffentlichungspfad in smartalb.vpn, wo ein zweites Oeffnen eine TOCTOU-
# Luecke auf einen privilegierten Ziel-Pfad war; hier ist es ein
# unprivilegierter Lesezugriff mit eingebauter Obergrenze.
#
# Wer das Ergebnis trotzdem in eine Bash-Variable einfaengt
# (raw="$(read_capped ...)"), verliert dort erneut enthaltene NUL-Bytes --
# das ist harmlos, weil die Grenzentscheidung bereits anhand echter
# Byte-Zahlen gefallen ist und jeder Aufrufer anschliessend JSON parst, in
# dem ein NUL ohnehin ungueltig waere.
read_capped() {
  local f="$1" max="$2" out n hstat
  [ -r "$f" ] || return 1
  out="$("$BIN_HEAD" -c "$((max + 1))" -- "$f" | "$BIN_WC" -c; printf '|%s' "${PIPESTATUS[0]}")"
  hstat="${out##*|}"
  n="${out%%|*}"
  n="${n%$'\n'}"
  [ "$hstat" -eq 0 ] || return 1
  [ "$n" -le "$max" ] || return 8
  "$BIN_HEAD" -c "$max" -- "$f"
}

# stdin laesst sich nicht zweimal lesen, daher der Umweg ueber eine
# Temp-Datei (0600 per mktemp-Standard): einmal MAX+1 Bytes hineinschreiben,
# mit "wc -c" auf der Datei zaehlen (kein ${#var}, aus demselben Grund wie
# bei read_capped), bei Ueberschreitung mit 8 ablehnen, sonst ausgeben.
#
# Aufraeumen mit explizitem "rm -f" vor jedem return statt "trap ... RETURN":
# ein RETURN-Trap, der auf die lokale Variable $tmp zugreift, feuert unter
# der Kombination set -u/-e/pipefail (genau die Umgebung von test/run.sh)
# gelegentlich erst, nachdem der lokale Gueltigkeitsbereich schon
# abgebaut ist -- "tmp: unbound variable" trotz "local tmp" weiter oben.
# Reproduzierbar z.B. mit "set -uo pipefail" im aufrufenden Skript plus
# einem vorausgehenden Aufruf derselben Funktion in einer Pipe. Der
# explizite Weg ist unabhaengig von dieser Falle.
read_stream_capped() {
  local max="$1" tmp n rc
  tmp="$("$BIN_MKTEMP")" || return 1
  "$BIN_HEAD" -c "$((max + 1))" > "$tmp" || { rm -f "$tmp"; return 1; }
  n="$("$BIN_WC" -c < "$tmp")"
  if [ "$n" -gt "$max" ]; then
    rm -f "$tmp"
    return 8
  fi
  "$BIN_CAT" -- "$tmp"
  rc=$?
  rm -f "$tmp"
  return "$rc"
}
