# Changelog

## 1.0.0 -- 2026-09-02

First release. Projects come from a pinned config file and from opencode's
own session database; each project remembers one model. Starting a project
passes the model as `-m provider/model` -- `opencode.json` is never
written to. A project that is already running hands its app-id to
Omarchy's `omarchy-launch-or-focus`, which focuses the existing window
instead of starting a second one; `Shift+Enter` always starts a new
window.
