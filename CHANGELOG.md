# Changelog

## 1.0.0 -- 2026-09-02

First release. Projects come from a pinned config file and from opencode's
own session database; each project remembers one model. Starting a project
passes the model as `-m provider/model` -- `opencode.json` is never
written to. A project that is already running hands its app-id to
Omarchy's `omarchy-launch-or-focus`, which focuses the existing window
instead of starting a second one; `Shift+Enter` always starts a new
window.

The bar icon is the opencode logomark, drawn from rectangles rather than
a Nerd-Font glyph, so it stays crisp at any bar size and needs no glyph
from the installed font. Each project is a single row -- its name, or the
path shortened to its last three segments with the full path in a hover
tooltip -- with a running marker that sits outside the shortened text so
it is never elided away. The footer shows the four most-used keys; the
full table lives in the README.

The model picker groups models by provider behind a collapsible header
carrying a count, e.g. `opencode (64)`; a provider with enough structure
gets a further split into sub-groups (by the middle path segment for
three-segment ids, or the model name up to its first hyphen for two-segment
ids), applied only where it yields at least two sub-groups of at least two
members each. Row text drops whatever a header above it already states.
Search flattens every level into one list, matched against the full model
id. A `★ Favourites` group, present once a model is starred, sits above
the providers and stays expanded; starring does not remove a model from
its provider group.
