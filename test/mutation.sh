#!/usr/bin/env bash
# Mutationsproben. Jede entfernt eine Schutzmassnahme und erwartet, dass
# mindestens ein Test rot wird -- und protokolliert MIT WELCHEM TEST und
# MIT WELCHER MELDUNG.
#
# Grund: in der Marktplatzpruefung von #4346 war ein Test rot, weil ein
# Programm im engen Test-PATH fehlte, nicht wegen der Mutation. Ein Status
# allein sagt nicht, ob der Test das Richtige geprueft hat -- deshalb
# meldet diese Probe fuer jeden roten Lauf den Testnamen UND seine
# Zusicherungsmeldung, nicht nur "irgendetwas ist rot geworden". Findet
# sich keine FAIL-Zeile mit Meldung, sondern nur ein SUITE-FEHLER (eine
# Suite ist VOR run_tests abgestuerzt) oder ein Abbruch ohne erkennbaren
# Grund, zaehlt die Probe NICHT als bewiesen -- genau das war die Falle in
# #4346.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK="$(mktemp -d)"
LOG="$WORK/protokoll.txt"
fails=0

# Die gerade gesicherte Originaldatei der laufenden Probe. Ein Trap auf
# EXIT/INT/TERM statt nur "am Ende der Schleife": ein abgebrochener Lauf
# (Strg-C, ein Fehler in diesem Skript selbst) darf keine mutierte Datei
# im Arbeitsbaum zuruecklassen.
CUR_FILE=""
CUR_ORIG=""
restore_current() {
  if [ -n "$CUR_FILE" ] && [ -n "$CUR_ORIG" ] && [ -f "$CUR_ORIG" ]; then
    cp -a "$CUR_ORIG" "$CUR_FILE"
  fi
  CUR_FILE=""; CUR_ORIG=""
}
cleanup() {
  restore_current
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# test/run.sh faengt den stdout jeder Suite per Kommandosubstitution
# ("out=\$(bash \"\$suite\")") ein und gibt ihn erst NACH deren Ende in
# einem Rutsch aus -- die stderr-Meldung eines FAIL (ueber "cat
# \$SANDBOX_ERR >&2" in harness.sh, dort NICHT eingefangen) erreicht die
# Anzeige dagegen sofort, waehrend die Suite noch laeuft. Im gemeinsam
# mitgeschnittenen Protokoll von test/run.sh landet die Meldung deshalb VOR
# dem kompletten ok/FAIL-Block ihrer eigenen Suite, nicht danach -- ein
# schlichtes "die naechsten eingerueckten Zeilen nach FAIL" faende dort
# nichts. Direkt aufgerufen (ohne den Kommandosubstitutions-Umweg) meldet
# genau dieselbe Suite FAIL und ihre Meldung dagegen in echter Reihenfolge
# unmittelbar hintereinander -- deshalb wird fuer die Meldung die
# betroffene Suite ein zweites Mal, einzeln, waehrend die Mutation NOCH
# aktiv ist, aufgerufen.
find_fail_suite() {  # find_fail_suite <voller-lauf-text> <fail-zeile>
  # Nicht einfach die zuletzt gesehene "== ..."-Kopfzeile nehmen: manche
  # Suiten (harness.test.sh) starten selbst noch einmal test/run.sh gegen
  # eine Wegwerf-Kopie in ihrer eigenen Sandbox, und DEREN Wegwerf-Suiten
  # ("a_plugin_aktivitaet.test.sh" & Co.) drucken ihre eigenen "== "-Kopf-
  # zeilen mitten in den Mitschnitt -- ohne Filter wuerde die Probe fuer
  # "Sandbox-Leck-Kappung" auf eine Datei zeigen, die es unter test/ gar
  # nicht gibt. Deshalb nur Kopfzeilen zaehlen, zu denen tatsaechlich eine
  # echte Datei unter test/ existiert.
  local line suite="" candidate
  while IFS= read -r line; do
    case "$line" in
      "== "*)
        candidate="${line#== }"
        [ -f "test/$candidate" ] && suite="$candidate"
        ;;
      "$2")
        printf '%s\n' "$suite"
        return
        ;;
    esac
  done <<< "$1"
}

extract_fail_message() {  # extract_fail_message <suite-eigener-text> <fail-zeile>
  printf '%s\n' "$1" | awk -v f="$2" '
    BEGIN { found = 0 }
    $0 == f { found = 1; next }
    found && /^     / { print; next }
    found { exit }
  ' | tr '\n' ' ' | sed -E 's/^ +//; s/ +$//; s/ +/ /g'
}

probe() {  # probe <name> <datei> <sed-programm>
  local name="$1" file="$2" prog="$3"
  local orig="$WORK/orig_$$_${name//[^A-Za-z0-9]/_}"
  cp -a "$file" "$orig"
  CUR_FILE="$file"; CUR_ORIG="$orig"

  sed -i "$prog" "$file"
  if diff -q "$orig" "$file" >/dev/null; then
    printf 'PROBE-DEFEKT  %-46s die Mutation hat nichts geaendert\n' "$name" | tee -a "$LOG"
    fails=$((fails+1))
    restore_current
    return
  fi

  local out rc
  out="$(bash test/run.sh 2>&1)"; rc=$?

  if [ "$rc" -eq 0 ]; then
    restore_current
    printf 'UEBERLEBT     %-46s kein Test wurde rot\n' "$name" | tee -a "$LOG"
    fails=$((fails+1))
    return
  fi

  local fail_line suite out2 fail_line2 msg
  fail_line="$(printf '%s\n' "$out" | grep -m1 '^  FAIL ' || true)"
  if [ -n "$fail_line" ]; then
    suite="$(find_fail_suite "$out" "$fail_line")"
    msg=""
    # Die Mutation ist an dieser Stelle noch aktiv -- die Suite muss VOR
    # dem Zurueckspielen der Originaldatei ein zweites Mal laufen, sonst
    # wuerde sie wieder gruen und keine Meldung mehr liefern.
    if [ -n "$suite" ] && [ -f "test/$suite" ]; then
      out2="$(bash "test/$suite" 2>&1)" || true
      fail_line2="$(printf '%s\n' "$out2" | grep -m1 '^  FAIL ' || true)"
      [ -n "$fail_line2" ] && msg="$(extract_fail_message "$out2" "$fail_line2")"
    fi
    restore_current
    printf 'ROT           %-46s %s -- %s\n' "$name" "${fail_line#  FAIL }" "${msg:-<keine Meldung erfasst>}" \
      | tee -a "$LOG"
    return
  fi
  restore_current

  # Kein FAIL, aber trotzdem ein von 0 verschiedener Exit-Status: entweder
  # eine Suite ist ganz abgestuerzt (SUITE-FEHLER) oder run.sh selbst hat
  # ein SANDBOX-LECK gemeldet. Beides ist fuer sich genommen KEIN Beweis,
  # dass EIN TEST die Mutation bemerkt hat -- ein SUITE-FEHLER kann auch
  # bedeuten, dass ein Werkzeug im Test-PATH fehlt, nichts mit der Probe zu
  # tun hat (genau die Falle aus #4346). Das SANDBOX-LECK der Probe
  # "Sandbox-Leck-Kappung zurueckgedreht" ist die einzige Ausnahme: dort
  # gehoert die SANDBOX-LECK-Meldung selbst zur erwarteten Zusicherung
  # einer bestehenden Suite (harness.test.sh), wird dort aber ohnehin schon
  # als "FAIL test_..." erfasst und oben behandelt -- landet der Lauf HIER,
  # kam die Meldung nicht aus einem Test, sondern direkt aus run.sh selbst.
  if printf '%s' "$out" | grep -q 'SUITE-FEHLER'; then
    msg="$(printf '%s\n' "$out" | grep -A4 'SUITE-FEHLER' | tr '\n' ' ' | sed -E 's/ +/ /g')"
    printf 'UNKLAR        %-46s SUITE-FEHLER (Absturz statt Zusicherung) -- %s\n' "$name" "$msg" \
      | tee -a "$LOG"
    fails=$((fails+1))
    return
  fi
  if printf '%s' "$out" | grep -q 'SANDBOX-LECK'; then
    msg="$(printf '%s\n' "$out" | grep -A2 'SANDBOX-LECK' | tr '\n' ' ' | sed -E 's/ +/ /g')"
    printf 'UNKLAR        %-46s SANDBOX-LECK von run.sh selbst, nicht von einem Test -- %s\n' "$name" "$msg" \
      | tee -a "$LOG"
    fails=$((fails+1))
    return
  fi
  printf 'UNKLAR        %-46s Exit %s, keine FAIL-Zeile erkennbar -- Grund ungeklaert\n' "$name" "$rc" \
    | tee -a "$LOG"
  fails=$((fails+1))
}

# --- Die zehn Proben aus dem Task-Brief -------------------------------------

probe "Modell-ID-Pruefung entfernt" bin/_common.sh \
  '/^valid_model_id() {/,/^}/ s/return 1/return 0/g'

probe "printf %q entfernt" bin/omarchy-opencode-launch \
  's/printf %q /printf %s /g'

# Traegt inzwischen "-k 5" zwischen BIN_TIMEOUT und TIMEOUT (Ruling 20) --
# der urspruengliche sed aus dem Brief matcht diese Zeile nicht mehr.
probe "timeout entfernt (jetzt mit -k 5)" bin/omarchy-opencode-models \
  's/"\$BIN_TIMEOUT" -k 5 "\$TIMEOUT" //'

probe "Symlink-Pruefung entfernt" bin/omarchy-opencode-store \
  's/\[ ! -L "\$STATE" \]/true/g'

probe "/dev/null-Abkopplung entfernt" bin/omarchy-opencode-launch \
  's| </dev/null >/dev/null 2>&1||g'

probe "MAX+1 auf MAX verkuerzt" bin/_common.sh \
  's/\$((max + 1))/$max/g'

probe "Kappung hinter den Aufruf" bin/omarchy-opencode-projects \
  '/^add() {/,/^}/ s/-lt "\$MAX_PROJECTS"/-lt 999999/'

# Panel.qml hat keine root.binHead-Eigenschaft (der Pfad steht direkt als
# Literal im runner()/runnerOut()); der urspruengliche sed aus dem Brief
# baute auf einer Eigenschaft, die es nie gab. Stattdessen die Erzeuger-
# seitige Kappung direkt aus runnerOut() entfernen.
probe "head -c aus runnerOut entfernt" Panel.qml \
  's@return root.runner("{ " + cmd + " ; } | /usr/bin/head -c " + root.maxOutBytes)@return root.runner("{ " + cmd + " ; }")@'

probe "onDestruction geleert" Panel.qml \
  '/Component.onDestruction/,/^  }/{/Proc.running = false/d}'

probe "absoluter Pfad zu PATH-Name" Panel.qml \
  's|"/usr/bin/bash"|"bash"|'

# --- Drei weitere Eigenschaften aus spaeteren Ruling-Runden -----------------

# Ruling 35 (1): der zweite Koerzierungsschritt (".model" ist danach IMMER
# String oder null) -- siehe Anmerkung zum Befund unten im Protokoll, falls
# diese Probe UEBERLEBT meldet: der vorgelagerte shape_ok-Filter in
# bin/omarchy-opencode-projects koennte diesen Fall bereits strukturell
# unerreichbar machen.
probe "Modell-Typ-Koerzierung (2. Stufe) entfernt" bin/omarchy-opencode-projects \
  's/| if type == "string" then \. else null end) as \$m/) as \$m/'

# Ruling 30: die App-Id als argv[1] von omarchy-launch-or-focus. Ohne sie
# nimmt der Empfaenger den gesamten Kommandostring als Fenstermuster, matcht
# nie und oeffnet bei jedem Klick ein zweites Fenster statt zu fokussieren.
probe "App-Id aus dem exec-Aufruf entfernt" bin/omarchy-opencode-launch \
  's/exec "\$LOF" "\$app_id" "\$cmd"/exec "\$LOF" "\$cmd"/'

# Ruling 29: die auf drei konkrete Dateien verengte Leck-Pruefung zurueck
# auf einen Sweep von "$HOME/.config/omarchy" gedreht -- harness.test.sh
# haelt genau diesen Fall (test_aktivitaet_unter_plugins_loest_kein_leck_mehr_aus)
# fest und muss dann selbst rot werden.
probe "Sandbox-Leck-Kappung auf vollen Sweep zurueckgedreht" test/run.sh \
  's|"\${REAL_CFG_FILES\[@\]}"|"\$HOME/.config/omarchy"|'

printf '\n----- Protokoll -----\n'; cat "$LOG"

if grep -q '^UEBERLEBT.*Modell-Typ-Koerzierung' "$LOG"; then
  cat <<'NOTE'

Bekannter, dokumentierter Befund zu "Modell-Typ-Koerzierung (2. Stufe)
entfernt": der vorgelagerte shape_ok-Filter in
bin/omarchy-opencode-projects (Ruling 28/35 (3), abgesichert durch
test_kombinationen_aus_projekt_und_modell_form_liefern_immer_gueltiges_json)
lehnt JEDEN Zustand mit einem nicht-String-".model" bereits vorher mit
state-invalid ab. Der zweite Koerzierungsschritt in der abschliessenden
jq-Formatierung ist unter der aktuellen Architektur deshalb unerreichbar --
eine zweite, per Konstruktion redundante Verteidigungslinie. Seine
Entfernung aendert kein beobachtbares Verhalten, deshalb kann kein Test sie
bemerken. Das ist eine Feststellung ueber die Architektur, kein uebersehener
Testfall -- Klaerung durch den Controller noetig: Probe fallen lassen, oder
eine gezielte, vom shape_ok-Gate unabhaengige Pruefung ergaenzen.
NOTE
fi

if [ "$fails" -gt 0 ]; then
  printf '\n%s von 13 Probe(n) haben nichts bewiesen. Die Tests pruefen dort nicht, oder der Grund fuer Rot ist unklar.\n' "$fails" >&2
  exit 1
fi
printf '\nAlle 13 Proben rot -- und jede mit einer erkennbaren, benannten Ursache. Die Tests pruefen, was sie behaupten.\n'
