# Hot Cell

This repository holds the core gems that isolate untrusted code and untrusted input (`hotcell-core`,
`hotcell-server`, and `hotcell-client`), the Active Storage gems built on them
(`activestorage-hotcell-client` and `activestorage-hotcell-server`), and `yabeda-hotcell`.

## Find your way around

Start at [`docs/index.md`](docs/index.md). It lists every reference page with a one-line description, so
you can pick the page you need without opening the others. Each page's frontmatter names the code it
describes, under `sources`.

The numbered invariants in [`docs/design/invariants.md`](docs/design/invariants.md) and the numbered
experiments in [`docs/development/experiments.md`](docs/development/experiments.md) are cited by number from code,
tests, and docs. Never renumber them.

## Keep the docs current

@docs/development/docs.md

## Write the docs

- The README is the introduction for people: what Hot Cell is, and a quick start. Keep it short, and link
  to a reference page for details instead of repeating them.
- The pages in `docs/` are a reference manual, written for agents first and readable by people. Write them
  in [Google developer documentation style](https://developers.google.com/style): second person, present
  tense, active voice, sentence-case headings, numbered lists for steps, and tables for settings.
- Keep one topic on each page, and keep each fact on one page. Link to it from everywhere else.
- The pages in `docs/design/` record rationale, not behavior. Change them when a decision changes. Record a
  decision that was argued in [`adr/`](docs/development/decisions.md).

## How to develop this project

@docs/development/contributing.md
