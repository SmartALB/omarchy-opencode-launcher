# opencode Launcher

An Omarchy bar widget that opens [opencode](https://opencode.ai) in a
project directory, with the model chosen before opencode starts.

The model travels as a command-line flag: opencode is started as
`opencode -m provider/model`. **Your `~/.config/opencode/opencode.json` is
never written to.** That is the whole point of this widget -- picking a
model changes nothing on disk except this plugin's own state, so opencode's
own configuration stays exactly as you left it, and running another opencode
session at the same time is never a race over a shared file.

## Screenshots

![The panel: pinned and recent projects, each with its remembered model](images/panel.png)
![The model picker: search, starred models on top, refresh on demand](images/picker.png)

## Install

```
omarchy plugin add https://github.com/SmartALB/omarchy-opencode-launcher.git --enable
```

The directory is named after the plugin id from the manifest, not after the
repository: it lands in `~/.config/omarchy/plugins/smartalb.opencode/`.

Leaving off `--enable` installs the plugin disabled, so the code can be read
first. Enable it afterwards with:

```
omarchy plugin enable smartalb.opencode
```

Either way, restart the shell once so the QML is picked up:

```
omarchy-restart-shell
```

## Removal

```
omarchy plugin remove smartalb.opencode
```

That takes the plugin directory and its entry in `shell.json`. The
remembered model for each project and the cached model list are **not**
part of the plugin directory and survive both a removal and a later
reinstall -- a fresh install of the same plugin id picks up exactly what was
remembered before.

To clear them on purpose:

```
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/smartalb-opencode/"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/smartalb.opencode/"
```

The first line forgets every project's chosen model; the second discards the
cached model list, which is rebuilt from opencode's own output the next time
the panel needs it.

## Requirements

- `omarchy-shell` -- this is a bar widget for it.
- `opencode` itself, reachable on `PATH` (or via `OPENCODE_BIN`).
- `jq` -- every script that produces or reads JSON uses it.
- `sqlite3`, optional. Without it, the "recent projects" list is simply
  empty; pinned projects, the model picker and launching all keep working.
  `sqlite3` is only needed to read opencode's own session database for
  recent-project discovery.

## Settings

| Key | Default | What it does |
|---|---|---|
| `barLabel` | `Icon` | What sits next to the bar icon. The model belongs to the project row, not to a single pill, so this only controls whether the number of currently open opencode windows is shown alongside the icon. |
| `recentCount` | `5` | How many directories from past opencode sessions are listed below the pinned projects. `0` turns the recent list off. |
| `catalogRefreshHours` | `24` | Hours before the cached model list is fetched from opencode again. The refresh button in the panel does this on demand regardless of age. |
| `confirmNewWindow` | `false` | Whether opening a project that is already running asks for confirmation before starting a second window. Off is the fast path the bar exists for. |

## Files

- `~/.config/omarchy/opencode-launcher.json` -- your pinned projects.
  `~/.config/omarchy/opencode-projects.json` is read as a fallback if the
  first file does not exist, for anyone who set up pinned projects under
  the older name.
- `${XDG_STATE_HOME:-~/.local/state}/omarchy/smartalb-opencode/` -- the
  plugin's own state: the model remembered per project.
- `${XDG_CACHE_HOME:-~/.cache}/omarchy/smartalb.opencode/` -- the cached
  model list fetched from opencode.
- `~/.config/omarchy/shell.json` -- gets the widget's entry under
  `bar.layout`, added by `omarchy plugin enable` / `--enable` and removed
  again by `omarchy plugin remove`.

## How it works

Each project row remembers the model chosen for it the last time it was
started. Pressing the row starts opencode as `opencode -m provider/model`
in that project's directory -- the model is a flag on the process, nothing
is written into opencode's own configuration.

If a project's window is already open, pressing the row focuses that window
instead of starting a second opencode process. `Shift+Enter` forces a
second window regardless; with `confirmNewWindow` on, that has to be
confirmed once before it opens.

## Tests

```
./test/run.sh
```

105 checks across the four scripts and the panel, run against a sandboxed
`PATH`, state directory and cache directory -- no test touches the real
configuration or a real opencode installation.

```
./test/mutation.sh
```

Ten mutation probes. Each one removes a single safeguard from the code and
checks that at least one test in `./test/run.sh` actually turns red because
of it -- a green suite proves nothing on its own if nothing in it would
notice the safeguard's absence.

## License

MIT -- see [LICENSE](LICENSE).
