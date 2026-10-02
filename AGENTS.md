# HotCell

This repository holds the core gems that isolate untrusted code and untrusted input (`hotcell-core`,
`hotcell-server`, and `hotcell-client`), the Active Storage gems built on them
(`activestorage-hotcell-client` and `activestorage-hotcell-server`), and `yabeda-hotcell`.

## Find your way around

Start at [`docs/index.md`](docs/index.md). It lists every reference page with a one-line description, so
you can pick the page you need without opening the others. Each page's frontmatter names the code it
describes, under `sources`.

The numbered invariants in [`docs/design/invariants.md`](docs/design/invariants.md) and the numbered
experiments in [`docs/design/experiments.md`](docs/design/experiments.md) are cited by number from code,
tests, and docs. Never renumber them.

## Keep the docs current

The reference pages describe behavior, so a change to the code can make a page wrong. Treat the docs as
part of the change:

1. Before you open a pull request, run `rake docs:stale`. It lists each page whose `sources` you changed
   while the page didn't change. Read each page it names, and update what your change made wrong. A page
   that's still right needs no edit. CI prints the same list as warnings on the pull request.
2. When a page starts or stops describing a file, add it to or remove it from the page's `sources`. A
   source can be a file or a directory.
3. When you add a page or change a page's `title` or `description`, run `rake docs:index` to regenerate
   the page lists in every `index.md`.
4. Run `rake docs:check`. It fails on a page without `type`, `title`, or `description`, on a source that
   doesn't exist, and on an index that's out of date. CI runs it on every push, and so does `rake`.

Some tables are held to the code by tests, which fail when the two disagree:

| Table | Test |
| --- | --- |
| Codes and kill causes in `docs/codes.md` | `hotcell-core/test/docs_test.rb` |
| Events in `docs/observability.md`, and defaults in `docs/cell-settings.md` | `hotcell-server/test/docs_test.rb` |
| Shipped operation limits in `docs/active-storage.md` | `activestorage-hotcell-server/test/docs_test.rb` |

## Write the docs

- The README is the introduction for people: what HotCell is, and a quick start. Keep it short, and link
  to a reference page for details instead of repeating them.
- The pages in `docs/` are a reference manual, written for agents first and readable by people. Write them
  in [Google developer documentation style](https://developers.google.com/style): second person, present
  tense, active voice, sentence-case headings, numbered lists for steps, and tables for settings.
- Keep one topic on each page, and keep each fact on one page. Link to it from everywhere else.
- The pages in `docs/design/` record rationale, not behavior. Change them when a decision changes. Record a
  decision that was argued in [`adr/`](adr/README.md).

## How to develop this project

@CONTRIBUTING.md
