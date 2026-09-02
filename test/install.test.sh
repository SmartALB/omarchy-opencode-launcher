#!/usr/bin/env bash
# C5 (Abschluss-Review): "./install" aus einem Klon kopierte ".git",
# ".superpowers" und "docs/superpowers" mit in die Konfiguration des
# Benutzers -- die ganze Historie und die Arbeitsakte dieses Projekts, in
# einem fremden ~/.config. Das Skript kopiert jetzt eine ausdrueckliche
# Liste.
#
# Der Test baut sich einen Wegwerf-Klon mit genau diesen drei internen
# Ecken UND einer Datei je erlaubtem Eintrag, laesst "install" mit
# Sandbox-HOME darauf laufen und prueft beide Richtungen: nichts Internes
# angekommen, alles Erwartete angekommen. Nur "nichts Internes" zu pruefen
# waere von einem Skript erfuellt, das gar nichts kopiert.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/harness.sh"
ROOT="$(cd "$DIR/.." && pwd)"

test_install_kopiert_nichts_internes_und_alles_erwartete() {
  local src="$SANDBOX/klon"
  mkdir -p "$src"
  # Der echte Inhalt, aber ohne die internen Ecken -- die legt der Test
  # gleich selbst und kontrolliert an.
  cp -a "$ROOT/bin" "$ROOT/test" "$ROOT/Panel.qml" "$ROOT/ModelSheet.qml" \
        "$ROOT/manifest.json" "$ROOT/README.md" "$ROOT/CHANGELOG.md" \
        "$ROOT/LICENSE" "$ROOT/install" "$ROOT/uninstall" "$src"/
  mkdir -p "$src/docs"
  cp -a "$ROOT/docs/design.md" "$ROOT/docs/einreichung.md" "$src/docs"/

  # Die drei internen Ecken, jede mit einer erkennbaren Datei darin.
  mkdir -p "$src/.git/objects" "$src/.superpowers/sdd" "$src/docs/superpowers/plans"
  printf 'ref: refs/heads/x\n' > "$src/.git/HEAD"
  printf 'interne akte\n'      > "$src/.superpowers/sdd/progress.md"
  printf 'interner plan\n'     > "$src/docs/superpowers/plans/plan.md"

  local dest="$HOME/.config/omarchy/plugins/smartalb.opencode"
  bash "$src/install" >/dev/null || fail "install fehlgeschlagen"

  # (a) Nichts Internes ist angekommen.
  [ ! -e "$dest/.git" ]              || fail ".git wurde mitkopiert"
  [ ! -e "$dest/.superpowers" ]      || fail ".superpowers wurde mitkopiert"
  [ ! -e "$dest/docs/superpowers" ]  || fail "docs/superpowers wurde mitkopiert"

  # (b) Alles Erwartete ist angekommen -- sonst bestuende (a) auch ein
  #     Skript, das ueberhaupt nichts kopiert.
  local expected
  for expected in bin/omarchy-opencode-launch bin/omarchy-opencode-projects \
                  bin/omarchy-opencode-models bin/omarchy-opencode-store \
                  bin/_common.sh test/run.sh Panel.qml ModelSheet.qml \
                  manifest.json README.md CHANGELOG.md LICENSE \
                  install uninstall docs/design.md docs/einreichung.md; do
    [ -e "$dest/$expected" ] || fail "fehlt im Ziel: $expected"
  done
  # Und die Skripte sind ausfuehrbar, wie install verspricht.
  [ -x "$dest/bin/omarchy-opencode-launch" ] || fail "bin/* nicht ausfuehrbar"
}

run_tests
