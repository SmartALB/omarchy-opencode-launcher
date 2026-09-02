# Changelog

## 1.0.0 -- 2026-09-02

First release. Projects come from a pinned config file and from opencode's
own session database; each project remembers one model. Starting a project
passes the model as `-m provider/model` -- `opencode.json` is never
written to. A project that is already running is focused instead of
started twice; `Shift+Enter` forces a second window.
