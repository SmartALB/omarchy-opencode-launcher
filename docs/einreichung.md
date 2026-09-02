# Marketplace submission -- draft, not yet submitted

This file is preparation only. It will be filed as a GitHub issue in the
marketplace repository only after explicit approval. A later
re-validation is triggered by **editing the issue body** (the automation
reacts to `opened`/`edited`/`labeled`, not to a comment) -- an external
pull request is not picked up by the marketplace repository.

## Repository

https://github.com/SmartALB/omarchy-opencode-launcher.git

The submission itself is made from a fresh `git clone` (or `git archive`)
of this repository, never from the author's own working directory --
untracked material such as `docs/superpowers/` (see `.gitignore`) is
therefore never part of the submitted tree.

## Category

Developer Tools

## Tags

Bar, AI, Developer Tools

## Maintainer notes

No privilege escalation of any kind: `install` and `uninstall` touch
nothing outside `$HOME`, require no elevated rights, and refuse to run as
root -- there is no `--system` mode. `~/.config/opencode/opencode.json` is
never written to by this plugin; the chosen model is passed on as a
`-m provider/model` flag when `opencode` starts.

**Dependencies:** `omarchy-shell`, `opencode`, `jq`. `sqlite3` is optional
-- without it only the list of recently opened projects is missing,
everything else stays usable.

**License:** MIT.

**Tests:** `./test/run.sh` (prints its own pass/fail tally) plus
`./test/mutation.sh`, a set of mutation probes (also prints its own
tally) that demonstrate the tests actually fail when a safeguard is
removed.
