#!/usr/bin/env bash
# Mutationsproben. Jede entfernt eine Schutzmassnahme und erwartet ein
# bestimmtes Ergebnis -- und protokolliert MIT WELCHEM TEST und MIT WELCHER
# MELDUNG, nicht nur, dass irgendetwas passiert ist.
#
# Grund: in der Marktplatzpruefung von #4346 war ein Test rot, weil ein
# Programm im engen Test-PATH fehlte, nicht wegen der Mutation. Ein Status
# allein sagt nicht, ob der Test das Richtige geprueft hat.
#
# Drei moegliche Ergebnisse je Probe:
#   ROT             Die Mutation entfernt eine Schutzmassnahme, die
#                    erwartungsgemaess mindestens einen Test rot macht --
#                    protokolliert mit Testname und Zusicherungsmeldung. Das
#                    ist der Normalfall und der Beweis, dass ein Test die
#                    Eigenschaft tatsaechlich prueft.
#   ERWARTET-GRUEN   Die Mutation entfernt NUR eine von ZWEI unabhaengigen
#                    Verteidigungsschichten, und die verbleibende Schicht
#                    traegt allein -- kein Test darf hier rot werden, GRUEN
#                    ist das erwartete, positive Ergebnis (Ruling 40: macht
#                    den manuellen Beweis aus dem Task-4-Review dauerhaft).
#                    Eine solche Probe deklariert ihre Erwartung selbst.
#   UEBERLEBT / UNERWARTET-ROT / PROBE-DEFEKT / UNKLAR
#                    Etwas ist NICHT wie erwartet: eine rot erwartete Probe
#                    blieb gruen (UEBERLEBT); eine gruen erwartete Probe
#                    wurde unerwartet rot (UNERWARTET-ROT, das waere ein
#                    echter Architekturbefund -- eine der beiden Schichten
#                    traegt entgegen der Annahme doch nicht allein); die
#                    Mutation hat nichts geaendert (PROBE-DEFEKT); oder der
#                    Lauf ist aus einem nicht zuordenbaren Grund rot
#                    geworden (UNKLAR, z.B. ein Werkzeug fehlt im
#                    Test-PATH -- genau die Falle aus #4346). Jedes dieser
#                    vier Ergebnisse zaehlt als NICHT bewiesen und macht den
#                    Exit-Status dieses Skripts von 0 verschieden.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WORK="$(mktemp -d)"
LOG="$WORK/protokoll.txt"
fails=0
count_total=0
count_rot=0
count_gruen=0

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

# test/run.sh faengt den stdout jeder Suite per Kommandosubstitution ein
# ("out=\$(bash \"\$suite\")") und gibt ihn erst NACH deren Ende in einem
# Rutsch aus -- die stderr-Meldung eines FAIL (ueber "cat \$SANDBOX_ERR >&2"
# in harness.sh, dort NICHT eingefangen) erreicht die Anzeige dagegen sofort,
# waehrend die Suite noch laeuft. Im gemeinsam mitgeschnittenen Protokoll von
# test/run.sh landet die Meldung deshalb VOR dem kompletten ok/FAIL-Block
# ihrer eigenen Suite, nicht danach -- ein schlichtes "die naechsten
# eingerueckten Zeilen nach FAIL" faende dort nichts. Direkt aufgerufen (ohne
# den Kommandosubstitutions-Umweg) meldet genau dieselbe Suite FAIL und ihre
# Meldung dagegen in echter Reihenfolge unmittelbar hintereinander -- deshalb
# wird fuer die Meldung die betroffene Suite ein zweites Mal, einzeln,
# waehrend die Mutation NOCH aktiv ist, aufgerufen.
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
  # Zwischen der FAIL-Zeile und ihrer eingerueckten Zusicherungsmeldung
  # koennen unindentierte Fremdzeilen stehen -- z.B. "jq: error ..." von
  # einem Befehl, den der Test selbst aufruft, bevor er ueber assert_eq
  # scheitert. Deshalb nicht bei der ERSTEN nicht-eingerueckten Zeile
  # abbrechen, sondern nur bei der naechsten "  ok "/"  FAIL "-Zeile (dem
  # naechsten Testergebnis) oder am Ende -- alles dazwischen, das nicht
  # eingerueckt ist, wird uebersprungen statt die Suche zu beenden.
  printf '%s\n' "$1" | awk -v f="$2" '
    BEGIN { found = 0 }
    $0 == f { found = 1; next }
    found && /^  (ok|FAIL) / { exit }
    found && /^     / { print; next }
    found { next }
  ' | tr '\n' ' ' | sed -E 's/^ +//; s/ +$//; s/ +/ /g'
}

# probe <name> <datei> <sed-programm> [erwartung]
#   erwartung: "rot" (Standard) oder "gruen". Mutiert <datei>, laesst die
#   volle Suite (test/run.sh) laufen, stellt <datei> in JEDEM Codepfad
#   wieder her, und bewertet das Ergebnis gegen die Erwartung.
probe() {
  local name="$1" file="$2" prog="$3" expect="${4:-rot}"
  local orig="$WORK/orig_$$_${name//[^A-Za-z0-9]/_}"
  cp -a "$file" "$orig"
  CUR_FILE="$file"; CUR_ORIG="$orig"
  count_total=$((count_total+1))

  sed -i "$prog" "$file"
  if diff -q "$orig" "$file" >/dev/null; then
    printf 'PROBE-DEFEKT   %-46s die Mutation hat nichts geaendert\n' "$name" | tee -a "$LOG"
    fails=$((fails+1))
    restore_current
    return
  fi

  local out rc
  out="$(bash test/run.sh 2>&1)"; rc=$?

  if [ "$rc" -eq 0 ]; then
    restore_current
    if [ "$expect" = "gruen" ]; then
      printf 'ERWARTET-GRUEN %-46s die volle Suite blieb gruen, wie erwartet\n' "$name" | tee -a "$LOG"
      count_gruen=$((count_gruen+1))
    else
      printf 'UEBERLEBT      %-46s kein Test wurde rot\n' "$name" | tee -a "$LOG"
      fails=$((fails+1))
    fi
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
    if [ "$expect" = "gruen" ]; then
      printf 'UNERWARTET-ROT %-46s %s -- %s\n' "$name" "${fail_line#  FAIL }" "${msg:-<keine Meldung erfasst>}" \
        | tee -a "$LOG"
      fails=$((fails+1))
    else
      printf 'ROT            %-46s %s -- %s\n' "$name" "${fail_line#  FAIL }" "${msg:-<keine Meldung erfasst>}" \
        | tee -a "$LOG"
      count_rot=$((count_rot+1))
    fi
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
    printf 'UNKLAR         %-46s SUITE-FEHLER (Absturz statt Zusicherung) -- %s\n' "$name" "$msg" \
      | tee -a "$LOG"
    fails=$((fails+1))
    return
  fi
  if printf '%s' "$out" | grep -q 'SANDBOX-LECK'; then
    msg="$(printf '%s\n' "$out" | grep -A2 'SANDBOX-LECK' | tr '\n' ' ' | sed -E 's/ +/ /g')"
    printf 'UNKLAR         %-46s SANDBOX-LECK von run.sh selbst, nicht von einem Test -- %s\n' "$name" "$msg" \
      | tee -a "$LOG"
    fails=$((fails+1))
    return
  fi
  printf 'UNKLAR         %-46s Exit %s, keine FAIL-Zeile erkennbar -- Grund ungeklaert\n' "$name" "$rc" \
    | tee -a "$LOG"
  fails=$((fails+1))
}

# probe_gruen_manuell <name> <datei> <sed-programm> <verify-funktion>
#   Fuer eine Probe, deren Erwartung ("gruen") sich NICHT ueber die normale
#   Testsuite pruefen laesst, weil die Suite noch eine ZWEITE, staerkere
#   Eigenschaft mitprueft (siehe Ruling 40 unten bei der Komplementprobe).
#   <verify-funktion> wird waehrend die Mutation noch aktiv ist aufgerufen
#   und muss "OK" ausgeben, wenn die geprobte Eigenschaft haelt, sonst eine
#   Fehlerbeschreibung.
probe_gruen_manuell() {
  local name="$1" file="$2" prog="$3" verify_fn="$4"
  local orig="$WORK/orig_$$_${name//[^A-Za-z0-9]/_}"
  cp -a "$file" "$orig"
  CUR_FILE="$file"; CUR_ORIG="$orig"
  count_total=$((count_total+1))

  sed -i "$prog" "$file"
  if diff -q "$orig" "$file" >/dev/null; then
    printf 'PROBE-DEFEKT   %-46s die Mutation hat nichts geaendert\n' "$name" | tee -a "$LOG"
    fails=$((fails+1))
    restore_current
    return
  fi

  local result
  result="$("$verify_fn" 2>&1)"
  restore_current

  if [ "$result" = "OK" ]; then
    printf 'ERWARTET-GRUEN %-46s alle geprueften Faelle blieben gueltiges JSON, wie erwartet\n' "$name" \
      | tee -a "$LOG"
    count_gruen=$((count_gruen+1))
  else
    printf 'UNERWARTET-ROT %-46s %s\n' "$name" "$result" | tee -a "$LOG"
    fails=$((fails+1))
  fi
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

# --- Modell-Typ-Koerzierung: zwei Proben statt einer (Ruling 40) -----------
#
# bin/omarchy-opencode-projects schuetzt "$m" (das spaeter formatierte
# .model) durch ZWEI unabhaengige Schichten: den vorgelagerten shape_ok-
# Filter (meldet dem Benutzer state-invalid, wenn irgendein .model im
# Zustand kein String ist) und die abschliessende Koerzierung in der
# Formatierungs-Pipeline (garantiert strukturell, dass $m danach IMMER
# String oder null ist, unabhaengig von shape_ok). Eine einzelne Probe, die
# nur die Koerzierung entfernt, UEBERLEBT nachweislich (siehe Task-7-Report,
# Befund zu Ruling 35): shape_ok allein haelt die Formatierung bereits
# crash-sicher. Das beweist aber nicht, dass die Koerzierung ueberfluessig
# waere -- nur, dass sie unter shape_ok unbeobachtbar ist. Ruling 40 dreht
# das in zwei Proben:

# 1) Kombiniert: BEIDE Schichten gleichzeitig entfernen. Erwartung: rot --
#    das ist die Aussage "beide Schichten zusammen sind alles, was zwischen
#    einer kaputten Zustandsdatei und kaputter/leerer Ausgabe steht".
probe "shape_ok UND Koerzierung gemeinsam entfernt" bin/omarchy-opencode-projects \
  's/\[ "\$shape_ok" != "true" \]/false/; s/| if type == "string" then \. else null end) as \$m/) as \$m/'

# 2) Komplement: NUR shape_ok entfernen, Koerzierung unangetastet lassen.
#    Erwartung: gruen -- das ist die Aussage "die Koerzierung allein
#    reicht". Ruling 40 / Task 4 Ruling 35(4) belegte das manuell fuer alle
#    zehn Form-Kombinationen des Kreuzprodukttests direkt gegen das
#    Skript; diese Probe macht genau diesen Beweis dauerhaft. NICHT ueber
#    "bash test/run.sh" pruefbar: der bestehende
#    test_kombinationen_aus_projekt_und_modell_form_liefern_immer_gueltiges_json
#    (und zwei weitere) pruefen zusaetzlich shape_ok's EIGENEN, staerkeren
#    Vertrag -- eine explizite state-invalid-Meldung fuer JEDE kaputte Form,
#    auch fuer nicht angefragte Projekte. Das ist folgerichtig rot, sobald
#    shape_ok entfernt wird, und eine andere (staerkere) Eigenschaft als
#    "die Koerzierung allein verhindert kaputtes JSON". Deshalb prueft
#    diese Probe die schwaechere, hier gemeinte Eigenschaft direkt und
#    unabhaengig von der bestehenden Suite nach.
verify_zehn_form_kombinationen_bleiben_gueltiges_json() {
  ROOT_DIR="$PWD" bash <<'INNER'
set -uo pipefail
. "$ROOT_DIR/test/lib/harness.sh"
setup_sandbox
make_stub opencode "printf '%s\n' openai/gpt-x"
export OPENCODE_BIN="$SANDBOX/stub/opencode"
PROJ="$ROOT_DIR/bin/omarchy-opencode-projects"
mkdir -p "$HOME/.config/omarchy" "$SANDBOX/p"
printf '{"projects":[{"name":"P","path":"%s/p"}]}' "$SANDBOX" \
  > "$HOME/.config/omarchy/opencode-launcher.json"
state_dir="$XDG_STATE_HOME/omarchy/smartalb-opencode"
mkdir -p "$state_dir"

fails=""
check() {  # check <label> <projects[$p]-JSON-Wert>
  printf '{"schemaVersion":1,"projects":{"%s/p":%s}}' "$SANDBOX" "$2" \
    > "$state_dir/projects.json"
  out="$("$PROJ" list --json)"
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || fails="$fails $1"
}

# Dieselben zehn Faelle wie in
# test_kombinationen_aus_projekt_und_modell_form_liefern_immer_gueltiges_json
# (Ruling 35 (3)): sechs Modell-Formen unter einem objektfoermigen Eintrag,
# plus vier Faelle, in denen der Eintrag selbst kein Objekt ist.
check object/string  '{"model":"openai/gpt-x"}'
check object/absent  '{}'
check object/array   '{"model":["x"]}'
check object/object  '{"model":{"a":1}}'
check object/number  '{"model":42}'
check object/null    '{"model":null}'
check string         '"just-a-string"'
check array          '[]'
check number         '42'
check null           'null'

if [ -n "$fails" ]; then
  printf 'kein gueltiges JSON bei:%s\n' "$fails"
else
  printf 'OK\n'
fi
INNER
}
probe_gruen_manuell "shape_ok allein entfernt (Komplementprobe)" bin/omarchy-opencode-projects \
  's/\[ "\$shape_ok" != "true" \]/false/' \
  verify_zehn_form_kombinationen_bleiben_gueltiges_json

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

printf '\n----- Bilanz -----\n'
printf '%s Proben gesamt: %s rot (wie erwartet), %s gruen (wie erwartet), %s nicht bewiesen (ueberlebt/unerwartet-rot/defekt/unklar)\n' \
  "$count_total" "$count_rot" "$count_gruen" "$fails"

if [ "$fails" -gt 0 ]; then
  printf '\n%s Probe(n) haben nichts bewiesen. Die Tests pruefen dort nicht, oder der Grund fuer das Ergebnis ist unklar.\n' "$fails" >&2
  exit 1
fi
printf '\nAlle Proben trafen ihre Erwartung -- die Tests pruefen, was sie behaupten.\n'
