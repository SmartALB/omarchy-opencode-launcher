# Marketplace submission

Filed 2026-09-03 as
[omacom/omarchy-plugin-marketplace#4606](https://github.com/omacom/omarchy-plugin-marketplace/issues/4606),
title `[Plugin]: opencode Launcher`, at commit `3693f6f`.

A re-validation is triggered by **editing the issue body**; the
automation reacts to `opened`/`edited`/`reopened`/`labeled`, not to a
comment, and an external pull request is not picked up at all.

The `submission` label is applied by the issue form only when the form is
used in a browser. Filing through the API leaves it unset, which does not
matter: both `route-issue-automation.yml` and `validate-submission.yml`
accept a title starting with `[Plugin]:` as an alternative to the label.
The automation added `submission`, `validated` and
`security-review-required` itself.

## Repository

https://github.com/SmartALB/omarchy-opencode-launcher.git

The submission itself is made from a fresh `git clone` (or `git archive`)
of this repository, never from the author's own working directory --
untracked material such as `docs/superpowers/` (see `.gitignore`) is
therefore never part of the submitted tree.

## Category

Developer Tools

## Tags

Bar, AI, Launcher

`Developer Tools` exists only as a category. The tag list in
`.github/ISSUE_TEMPLATE/submit-plugin.yml` is closed -- AI, Bar,
Education, Games, Hyprland, Kids, Launcher, Media, Power management,
Quickshell, Security, System, Workspaces -- and a submission carrying
more than three tags is rejected outright.

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

## Outcome of the automated checks

Validation passed on every point: repository public and reachable, one
valid and uniquely identified manifest, README and license found at the
root, Quattro compatibility confirmed, root preview detected. Verdict:
*ready for listing review*.

The security baseline asks for a manual review with an empty finding
list and a single derived capability, `installer` -- attached to the mere
existence of the `install` and `uninstall` files, and its own report
notes that no change is necessarily required. Neither `privilege` nor
`package-manager` was derived, which is what the keyword discipline
throughout this repository was for. Any plugin shipping an installation
script earns this label, and the submission checklist cannot be
satisfied without one.
