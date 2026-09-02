# Design

## The problem

Starting [opencode](https://opencode.ai) with a particular model normally
means editing `~/.config/opencode/opencode.json` before every session, or
living with whatever model that file last named. Neither is great from a
bar widget: editing shared config from a background process is a race the
moment two projects want different models, or two opencode sessions run at
once. This plugin instead treats "which model" as a per-project, per-launch
choice, and never touches that file at all.

## The four scripts

The plugin logic lives entirely in `bin/`, called from `Panel.qml` and
`ModelSheet.qml`. QML owns layout and interaction; the scripts own
everything that reads or writes a file, or starts a process.

- **`omarchy-opencode-projects`** builds the project list the panel shows:
  pinned projects from `~/.config/omarchy/opencode-launcher.json` (or the
  older `opencode-projects.json`), followed by recent projects read
  straight out of opencode's own session database. It also folds in the
  remembered model per project and whether a project's window is currently
  open, so the panel does a single call for everything it needs to render.
- **`omarchy-opencode-models`** produces the model catalogue: what the
  installed opencode can currently reach. It caches the result and falls
  back to the cache -- stale rather than absent -- if the live call fails or
  hangs, so an unreachable model provider never blocks the bar.
- **`omarchy-opencode-store`** is the single writer of the plugin's own
  state: the model remembered per project, and starred models. Every write
  goes to a temporary file in the same directory and is renamed into place,
  so a state file is never read half-written.
- **`omarchy-opencode-launch`** starts opencode for a chosen project and
  model. For a project that is already open, it hands its app-id to
  Omarchy's own `omarchy-launch-or-focus`, which focuses the existing
  window rather than starting a second process -- the actual focusing is
  that tool's job, not this plugin's. This is the only script that starts
  an external process, and the only place the model actually reaches
  opencode.

`_common.sh` holds what all four share: path handling, ID validation, and
absolute paths to every external program they call.

## The model as a flag, not a config write

`omarchy-opencode-launch` starts opencode as `opencode -m provider/model`.
The alternative -- writing the chosen model into `opencode.json` before
each start -- was rejected for three reasons that all point the same way:

- It is **not this plugin's file**. Overwriting a setting the user (or
  another tool) may have set deliberately, then having to restore it
  afterwards, adds a second responsibility this plugin has no business
  taking on.
- It does not survive **concurrency**. Two projects, two models, one
  shared file: whichever launch writes second wins, and the first
  session may already be reading the file again by the time that happens.
- It is **not necessary**. opencode already accepts the model as a
  command-line flag, which is exactly the per-invocation knob this widget
  needs -- no shared state, no write, no restore step.

The flag also makes the plugin's central promise checkable by inspection:
grep the four scripts for a write to `opencode.json` and find none, rather
than having to trust a restore path to run correctly on every exit.

## Producer-side limits, and why they exist

Every script that reads something whose size or shape it does not control
-- a config file, opencode's model output, its session database -- caps
what it accepts before acting on it: a byte limit on file reads, a count
limit on the project and model lists, a timeout on the external call to
opencode. None of these are about defending against malice; they are about
a bar widget that must stay responsive and bounded no matter what a
misbehaving `opencode.json`, a huge session history, or a hung model
provider does upstream. A widget that can block the bar because a JSON
file grew unexpectedly large has failed at its one job of staying out of
the way.

## Testing approach

`./test/run.sh` runs the full suite across the four scripts and the panel,
against a sandboxed `PATH`, state directory and cache directory built for
the test run -- no test touches a real opencode installation or the real
plugin state. It prints its own pass/fail tally at the end; that count is
not repeated here, since it changes with every added test and a
hard-coded number in prose would just as reliably go stale.

A green suite is not proof on its own. This project's own history counts a
whole series of tests -- found one at a time, over many review rounds --
that passed while proving nothing about the behaviour they were meant to
guard: checking for the wrong thing, or for something that happened to be
true regardless of whether the actual protection was in place. Each looked
like coverage on a report while catching nothing, and each was found only
by closer review, not by the suite failing. The count is deliberately not
written down here; it has grown with every round and a number in prose
would go stale the way the test count would.

`./test/mutation.sh` exists to catch that class of failure mechanically
rather than by review. Each probe removes exactly one safeguard from the
code -- a validation check, a timeout, a symlink guard -- and records what
happened, naming the test that failed and its assertion message rather
than just reporting that something failed: a failure from an unrelated
cause (a missing tool in a narrow test `PATH`, say) would otherwise look
identical to a real catch.

Most probes then run the full suite and expect at least one test to turn
red *because of that specific change*. Not all of them: where two
independent layers guard the same property, removing one leaves the other
carrying alone, and the honest expectation is that the suite stays
**green**. Such a probe declares that expectation itself and verifies the
weaker property it actually means directly, without the suite -- because
the suite also asserts the stronger contract of the layer that was
removed, and would go red for the right reason but the wrong claim. A
probe that misses its own expectation, in either direction, is a finding:
either the tests do not check what they claim, or one of two layers does
not carry alone after all.

The runner prints how many probes ran, how many met each expectation, and
how many proved nothing, and exits non-zero unless every probe met its
expectation -- for the same reason `./test/run.sh` prints its own tally
rather than being quoted here.

Because the probes rewrite the plugin's own files in place, they must be
run from a copy: Omarchy's plugin registry watches an installed plugin
directory with `inotifywait` and reloads the shell on every change, so a
run in place means dozens of live bar reloads, some of them running
deliberately weakened code. `README.md` says so at the invocation.
